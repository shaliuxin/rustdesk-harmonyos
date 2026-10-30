//! ArkTS / C++ → Rust 的 C ABI 入口。
//!
//! 与 `ffi.rs` 的分工：
//!   - `ffi.rs` 是 Rust **调用** C++（import / `extern "C"`）；
//!   - 本文件是 Rust **被** C++ 调用（export / `#[no_mangle]`）。
//!
//! 命名统一为 `rustdesk_ohos_` 前缀，避免和 RustDesk 上游已有的
//! `rustdesk_core_main` / `handle_applicationShouldOpenUntitledFile` 撞名。
//!
//! 线程模型：
//!   - 所有导出函数都可以从 ArkTS 主线程直接调；真正阻塞的活（连接、解码）
//!     都在 `session::start` 起的后台线程里。
//!   - `*_frame_acquire` 返回的指针只在 `*_frame_release` 之前有效，且必须
//!     在同一个线程里成对使用（指向会话内帧槽的 Vec，跨线程调用会被 RwLock 挡住）。
//!
//! 错误约定：返回 `c_int` 的函数，0 = 成功，负数为错误码；需要细节时再调
//! `rustdesk_ohos_last_error()`。

use super::{ffi, session, ui_handler};
use hbb_common::{config, log};
use std::os::raw::{c_char, c_int, c_uint};

/// ABI 版本。ArkTS 侧启动时校验，避免 C++ 与 .a 版本错配导致的诡异崩溃。
pub const ABI_VERSION: c_uint = 1;

const ERR_INVALID_ARG: c_int = -1;
const ERR_NO_SESSION: c_int = -2;
const ERR_START_FAILED: c_int = -3;

/// 最近一次错误信息。用 `Mutex<String>` 而不是 thread_local：
/// ArkTS 在 A 线程触发失败、在 B 线程读错误信息是常见写法。
static LAST_ERROR: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());

fn set_error(msg: impl Into<String>) -> c_int {
    let msg = msg.into();
    log::error!("ohos: {}", msg);
    if let Ok(mut g) = LAST_ERROR.lock() {
        *g = msg;
    }
    ERR_INVALID_ARG
}

fn cstr_arg(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    Some(
        unsafe { std::ffi::CStr::from_ptr(p) }
            .to_string_lossy()
            .into_owned(),
    )
}

/// 把 String 交给调用方，调用方用完必须调 [`rustdesk_ohos_string_free`]。
fn into_c_string(s: String) -> *mut c_char {
    match std::ffi::CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn rustdesk_ohos_abi_version() -> c_uint {
    ABI_VERSION
}

/// 进程内初始化。**必须最先调用**，且只调一次。
///
/// `app_dir` 是应用沙箱路径（ArkTS 侧 `context.filesDir`），配置、日志、
/// 缓存放这里。Rust 侧没有权限自己去问系统的 filesDir。
///
/// 返回 0 成功。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_init(app_dir: *const c_char) -> c_int {
    let dir = match cstr_arg(app_dir) {
        Some(d) if !d.is_empty() => d,
        _ => return set_error("rustdesk_ohos_init: app_dir is null or empty"),
    };

    *config::APP_DIR.write().unwrap() = dir;

    // 定制客户端（换 logo / 换服务器）在编译期嵌进二进制，与桌面端一致。
    crate::load_custom_client();
    // 与 flutter_ffi::initialize 相同的顺序：先 client 定制，再全局初始化。
    if !crate::common::global_init() {
        return set_error("global_init failed");
    }
    // 注意：这里**不能**调 `flutter::async_tasks::start_flutter_async_runner()`。
    // `pub mod flutter` 在上游是 `cfg(any(android, ios, feature = "flutter"))`，
    // 鸿蒙不编译它。它承载的只有「online 状态查询」这一个后台任务，
    // 属于 UI 侧轮询功能，M1 不需要；真需要时用 `crate::common` 自己的线程宿主。
    //
    // 日志落盘。鸿蒙上 flexi_logger 可用（与 Android 不同，那里只有 logcat）。
    hbb_common::init_log(false, "rustdesk");

    log::info!("ohos: core initialized, abi {}", ABI_VERSION);
    0
}

/// 最近一次错误信息（调用方负责 free）。没有错误时返回空串。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_last_error() -> *mut c_char {
    let s = LAST_ERROR.lock().map(|g| g.clone()).unwrap_or_default();
    into_c_string(s)
}

#[no_mangle]
pub extern "C" fn rustdesk_ohos_string_free(p: *mut c_char) {
    if !p.is_null() {
        unsafe { drop(std::ffi::CString::from_raw(p)) };
    }
}

// ---------------------------------------------------------------------------
// 主控会话
// ---------------------------------------------------------------------------

/// 连接一个远端 peer。
///
/// * `peer_id`   —— `123456789` 或 `123456789@server` 形式，可带 `?key=` 参数
/// * `password`  —— 预设密码，空串表示连接后再向用户索要
/// * `force_relay` —— 非 0 表示强制中继
///
/// 立即返回；连接结果通过 `ui_handler` 的 JSON 事件（`connected` / `msgbox`）上报。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_session_start(
    peer_id: *const c_char,
    password: *const c_char,
    force_relay: c_int,
) -> c_int {
    let peer_id = match cstr_arg(peer_id) {
        Some(v) if !v.trim().is_empty() => v,
        _ => return set_error("session_start: empty peer id"),
    };
    let password = cstr_arg(password).unwrap_or_default();
    match session::start(&peer_id, &password, force_relay != 0) {
        Ok(()) => 0,
        Err(e) => {
            set_error(format!("session_start failed: {}", e));
            ERR_START_FAILED
        }
    }
}

#[no_mangle]
pub extern "C" fn rustdesk_ohos_session_close() {
    session::close();
}

/// 请求关键帧。`display` 从 0 开始。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_session_refresh(display: c_int) {
    session::refresh(display.max(0));
}

/// 会话状态快照（JSON）。调用方负责 free。
///
/// 与事件通道互补：ArkTS 页面重建后拿这个恢复 UI，不必重放历史事件。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_state_json() -> *mut c_char {
    let json = match session::current() {
        Some(s) => s.ui_handler.state_json(),
        None => "{}".to_owned(),
    };
    into_c_string(json)
}

// ---------------------------------------------------------------------------
// 帧
// ---------------------------------------------------------------------------

/// 取当前帧。返回像素指针（RGBA8888），尺寸写入 `out_w` / `out_h`。
///
/// 返回空指针表示暂无新帧（正常现象：画面静止时不会产生新帧）。
/// 拿到指针后必须在渲染完成时调 [`rustdesk_ohos_frame_release`]，
/// 否则下一帧会因为背压被丢弃、画面停住。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_frame_acquire(
    display: c_int,
    out_w: *mut c_int,
    out_h: *mut c_int,
) -> *const u8 {
    let (ptr, w, h) = match session::current() {
        Some(s) => s.ui_handler.acquire_frame(display.max(0) as usize),
        None => return std::ptr::null(),
    };
    if !out_w.is_null() {
        unsafe { *out_w = w as c_int };
    }
    if !out_h.is_null() {
        unsafe { *out_h = h as c_int };
    }
    ptr
}

#[no_mangle]
pub extern "C" fn rustdesk_ohos_frame_release(display: c_int) {
    session::with_session(|s| s.ui_handler.release_frame(display.max(0) as usize));
}

// ---------------------------------------------------------------------------
// 输入：ArkTS 事件 → 远端
// ---------------------------------------------------------------------------

/// 鼠标/触摸事件。
///
/// `mask` 用 RustDesk 协议的位标志（`MOUSE_TYPE_DOWN/UP/MOVE/WHEEL` +
/// `MOUSE_BUTTON_LEFT/RIGHT`），与 Flutter 的 `session_send_mouse` 完全一致，
/// 这样手势换算逻辑可以在 ArkTS 侧复用官方 Flutter 实现的结论。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_mouse(
    mask: c_int,
    x: c_int,
    y: c_int,
    alt: c_int,
    ctrl: c_int,
    shift: c_int,
    command: c_int,
) -> c_int {
    match session::with_session(|s| {
        s.send_mouse(mask, x, y, alt != 0, ctrl != 0, shift != 0, command != 0)
    }) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 键盘事件。`name` 是 RustDesk 的键名（`"A"`、`"F1"`、`"Backspace"`…），
/// 单字符键直接传该字符。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_key(
    name: *const c_char,
    down: c_int,
    press: c_int,
    alt: c_int,
    ctrl: c_int,
    shift: c_int,
    command: c_int,
) -> c_int {
    let name = match cstr_arg(name) {
        Some(v) => v,
        None => return set_error("key: name is null"),
    };
    match session::with_session(|s| {
        s.input_key(
            &name,
            down != 0,
            press != 0,
            alt != 0,
            ctrl != 0,
            shift != 0,
            command != 0,
        )
    }) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

#[no_mangle]
pub extern "C" fn rustdesk_ohos_ctrl_alt_del() -> c_int {
    match session::with_session(|s| s.ctrl_alt_del()) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

#[no_mangle]
pub extern "C" fn rustdesk_ohos_switch_display(index: c_int) -> c_int {
    match session::with_session(|s| s.switch_display(index)) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 发送聊天消息（会话内的文字消息，不是剪贴板）。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_send_chat(text: *const c_char) -> c_int {
    let text = match cstr_arg(text) {
        Some(v) => v,
        None => return set_error("send_chat: text is null"),
    };
    match session::with_session(|s| s.send_chat(text)) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

// ---------------------------------------------------------------------------
// 被控端：ArkTS 推入屏幕帧
// ---------------------------------------------------------------------------

/// 推入一帧屏幕内容（RGBA8888）。由 ArkTS 的 `@ohos.screenCapture` 回调调用。
///
/// `stride` 传 0 表示按 `width * 4` 计算。数据会被拷贝，调用返回后
/// ArkTS 可以立刻重用它的 ArrayBuffer。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_capture_push_frame(
    data: *const u8,
    len: usize,
    width: usize,
    height: usize,
    stride: usize,
) -> c_int {
    if data.is_null() || width == 0 || height == 0 {
        return set_error("capture_push_frame: invalid argument");
    }
    let slice = unsafe { std::slice::from_raw_parts(data, len) };
    scrap::push_frame(slice.to_vec(), width, height, stride);
    0
}

/// 采集被系统暂停（切后台、用户撤销授权）时清空帧队列，
/// 避免主控端一直收到过期画面。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_capture_clear() {
    scrap::clear_frame();
}

/// 刷新显示器列表：从系统 FFI 读一遍，灌进 scrap 的帧队列。
///
/// ArkTS 在 `display.on('add'|'remove'|'change')` 时调用即可；
/// 之所以不让 scrap 自己去问系统，是因为 scrap 是独立 crate，
/// 不应该反向依赖主 crate 的 `platform::ohos`。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_displays_sync() -> c_int {
    let infos: Vec<scrap::DisplayInfo> = super::get_displays()
        .into_iter()
        .enumerate()
        .map(|(i, (id, name, w, h, _scale))| scrap::DisplayInfo {
            name: if name.is_empty() {
                format!("display-{}", id)
            } else {
                name
            },
            x: 0,
            y: 0,
            width: w as usize,
            height: h as usize,
            primary: i == 0,
        })
        .collect();
    let n = infos.len() as c_int;
    scrap::set_displays(infos);
    n
}

/// 触发一次 hilog 输出，便于 ArkTS 侧确认 FFI 链路通了。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_log_probe(msg: *const c_char) {
    let msg = cstr_arg(msg).unwrap_or_else(|| "probe".to_owned());
    ffi::log(1, &format!("probe from arkts: {}", msg));
    ui_handler::emit("probe", serde_json::json!(msg));
}
