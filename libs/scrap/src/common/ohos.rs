//! OpenHarmony (HarmonyOS NEXT) 采集后端。
//!
//! 与桌面端不同，OHOS 上没有 X11 / PipeWire / DXGI 之类的"从 Rust 主动抓屏"的接口：
//! 屏幕采集必须由 ArkTS 侧通过 `@ohos.screenCapture`（或被控场景下的
//! `AVScreenCapture`）发起，再由系统回调把 RGBA 帧交回来。
//!
//! 因此这里的做法是：
//!
//!   ArkTS (EntryAbility)                     Rust (本模块)
//!   ---------------------------              ---------------------------
//!   screenCapture.on('capture')  ──FFI──▶   `push_frame(...)`  写入共享槽
//!                                            `Capturer::frame()` 取帧
//!
//! `push_frame` / `set_displays` 是给 `ohos/glue`（Tier-1 新增的 FFI 层）调用的，
//! 不属于 scrap 的公共 API，但为了少一层间接，直接放在这里。
//!
//! 这样做的另一个好处：整个 scrap 的编码/缩放/记录链路（`codec.rs`、`convert.rs`、
//! `record.rs`、`vpx.rs`）与上游完全共用，不需要为 OHOS 写第二套。

use crate::{common::TraitCapturer, Frame, Pixfmt, TraitPixelBuffer};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::{io, time::Duration};

/// 是否为"光标已经画进画面里"的后端。OHOS 的系统截图默认含光标，故为 true。
///
/// 注意与 `x11.rs` 的 false 相对照：那个值决定服务端是否要自行叠加光标位图。
pub const IS_CURSOR_EMBEDDED: bool = true;

// ---------------------------------------------------------------------------
// 共享状态：ArkTS 侧推入的帧 + 显示器列表
// ---------------------------------------------------------------------------

struct FrameSlot {
    /// 单调递增的帧序号，`Capturer` 用它判断是否拿到新帧。
    seq: u64,
    data: Vec<u8>,
    width: usize,
    height: usize,
    pixfmt: Pixfmt,
}

struct Shared {
    frame: Mutex<FrameSlot>,
    frame_ready: Condvar,
    displays: Mutex<Vec<DisplayInfo>>,
}

fn shared() -> &'static Arc<Shared> {
    static SHARED: OnceLock<Arc<Shared>> = OnceLock::new();
    SHARED.get_or_init(|| {
        Arc::new(Shared {
            frame: Mutex::new(FrameSlot {
                seq: 0,
                data: Vec::new(),
                width: 0,
                height: 0,
                pixfmt: Pixfmt::RGBA,
            }),
            frame_ready: Condvar::new(),
            displays: Mutex::new(Vec::new()),
        })
    })
}

/// ArkTS 侧报告的显示器几何信息。
#[derive(Clone, Debug, Default)]
pub struct DisplayInfo {
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: usize,
    pub height: usize,
    pub primary: bool,
}

/// 更新显示器列表。由 ArkTS 在 `display.on('add'/'remove'/'change')` 时调用。
pub fn set_displays(infos: Vec<DisplayInfo>) {
    *shared().displays.lock().unwrap() = infos;
}

/// 由 ArkTS 侧推入一帧 RGBA 数据（`@ohos.screenCapture` 的 `imageBuffer`）。
///
/// `data.len()` 必须 >= `stride * height`；`stride` 传 0 表示按 `width * 4` 计算。
pub fn push_frame(data: Vec<u8>, width: usize, height: usize, stride: usize) {
    let stride = if stride == 0 { width * 4 } else { stride };
    if width == 0 || height == 0 || data.len() < stride * height {
        hbb_common::log::warn!(
            "ohos: drop malformed frame, {}x{} stride {} len {}",
            width,
            height,
            stride,
            data.len()
        );
        return;
    }
    let s = shared();
    let mut slot = s.frame.lock().unwrap();
    slot.seq = slot.seq.wrapping_add(1);
    slot.data = data;
    slot.width = width;
    slot.height = height;
    slot.pixfmt = Pixfmt::RGBA;
    drop(slot);
    s.frame_ready.notify_all();
}

/// 清空当前帧（例如切到后台、采集被系统暂停时）。
pub fn clear_frame() {
    let s = shared();
    let mut slot = s.frame.lock().unwrap();
    slot.data.clear();
    slot.width = 0;
    slot.height = 0;
    drop(slot);
    s.frame_ready.notify_all();
}

// ---------------------------------------------------------------------------
// Display
// ---------------------------------------------------------------------------

pub struct Display(DisplayInfo);

impl Display {
    pub fn primary() -> io::Result<Display> {
        let infos = shared().displays.lock().unwrap();
        infos
            .iter()
            .find(|d| d.primary)
            .or_else(|| infos.first())
            .cloned()
            .map(Display)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no ohos display reported"))
    }

    pub fn all() -> io::Result<Vec<Display>> {
        let infos = shared().displays.lock().unwrap();
        Ok(infos.iter().cloned().map(Display).collect())
    }

    pub fn width(&self) -> usize {
        self.0.width
    }

    pub fn height(&self) -> usize {
        self.0.height
    }

    pub fn origin(&self) -> (i32, i32) {
        (self.0.x, self.0.y)
    }

    pub fn is_online(&self) -> bool {
        true
    }

    pub fn is_primary(&self) -> bool {
        self.0.primary
    }

    pub fn name(&self) -> String {
        self.0.name.clone()
    }

    /// OHOS 的屏幕缩放由系统统一管理（ArkTS 侧已按 `display.densityPixels` 处理），
    /// Rust 侧不再二次缩放。
    pub fn fix_quality() -> u16 {
        1
    }
}

// ---------------------------------------------------------------------------
// Capturer
// ---------------------------------------------------------------------------

pub struct Capturer {
    display: DisplayInfo,
    /// 取帧时把共享槽拷到这里，`Frame<'a>` 的借用期绑定在 `&'a mut self` 上。
    buf: Vec<u8>,
    seen_seq: u64,
}

impl Capturer {
    pub fn new(display: Display) -> io::Result<Capturer> {
        Ok(Capturer {
            display: display.0,
            buf: Vec::new(),
            seen_seq: 0,
        })
    }

    pub fn width(&self) -> usize {
        self.display.width
    }

    pub fn height(&self) -> usize {
        self.display.height
    }
}

impl TraitCapturer for Capturer {
    fn frame<'a>(&'a mut self, timeout: Duration) -> io::Result<Frame<'a>> {
        let s = shared();
        let mut slot = s.frame.lock().unwrap();
        let deadline = std::time::Instant::now() + timeout;
        // 等到「比上次看见的序号更新」的一帧为止；超时则返回 WouldBlock，
        // 与其它后端（x11/dxgi）对 timeout 的语义保持一致。
        while slot.seq == self.seen_seq || slot.data.is_empty() {
            let now = std::time::Instant::now();
            if now >= deadline {
                return Err(io::ErrorKind::WouldBlock.into());
            }
            let (guard, _) = s
                .frame_ready
                .wait_timeout(slot, deadline - now)
                .map_err(|_| io::Error::from(io::ErrorKind::Other))?;
            slot = guard;
        }

        self.seen_seq = slot.seq;
        self.buf.clear();
        self.buf.extend_from_slice(&slot.data[..slot.width * slot.height * 4]);
        let (w, h) = (slot.width, slot.height);
        // 帧尺寸与 Display 上报不一致时以帧为准：系统旋转/折叠屏切换后
        // ArkTS 的 display 事件可能晚于第一帧到达。
        if w != self.display.width || h != self.display.height {
            self.display.width = w;
            self.display.height = h;
        }
        drop(slot);

        Ok(Frame::PixelBuffer(PixelBuffer::new(
            &self.buf,
            Pixfmt::RGBA,
            w,
            h,
        )))
    }
}

// ---------------------------------------------------------------------------
// PixelBuffer
// ---------------------------------------------------------------------------

pub struct PixelBuffer<'a> {
    data: &'a [u8],
    pixfmt: Pixfmt,
    width: usize,
    height: usize,
    stride: Vec<usize>,
}

impl<'a> PixelBuffer<'a> {
    pub fn new(data: &'a [u8], pixfmt: Pixfmt, width: usize, height: usize) -> Self {
        let stride0 = if height == 0 {
            data.len()
        } else {
            data.len() / height
        };
        Self {
            data,
            pixfmt,
            width,
            height,
            stride: vec![stride0],
        }
    }
}

impl<'a> TraitPixelBuffer for PixelBuffer<'a> {
    fn data(&self) -> &[u8] {
        self.data
    }

    fn width(&self) -> usize {
        self.width
    }

    fn height(&self) -> usize {
        self.height
    }

    fn stride(&self) -> Vec<usize> {
        self.stride.clone()
    }

    fn pixfmt(&self) -> crate::Pixfmt {
        self.pixfmt
    }
}
