//! C ABI 边界：Rust ←→ C++ (libentry.so / libohos_adapter.so)
//!
//! 为什么用 C ABI 而不是 napi-rs：
//!   - 音视频解码/渲染必须走 OH_AVCodec + XComponent Surface，只有 C/C++ 侧拿得到 Surface 句柄；
//!   - NAPI 线程安全函数（napi_create_threadsafe_function）在 C++ 侧更成熟；
//!   - C ABI 同时可被 Rust 静态库调用，双向调用链最短。
//!
//! 命名约定：ohos_<子系统>_<动作>，返回 0 成功 / 负数错误码，字符串返回 *mut c_char（调用方负责 free）。

use std::os::raw::{c_char, c_int, c_void};

pub const DEVICE_TYPE_PHONE: c_int = 0;
pub const DEVICE_TYPE_TABLET: c_int = 1;
pub const DEVICE_TYPE_2IN1: c_int = 2;

extern "C" {
    // --- 设备与账号 ---
    pub fn ohos_device_type() -> c_int;
    pub fn ohos_get_active_user_name() -> *mut c_char;
    pub fn ohos_get_active_user_id() -> *mut c_char;
    pub fn ohos_is_locked() -> c_int;
    pub fn ohos_lock_screen() -> c_int;

    // --- 输入注入（仅 2in1）---
    pub fn ohos_input_can_inject() -> c_int; // 0/1，内部综合“形态 + 授权状态”
    pub fn ohos_input_request_authorization() -> c_int; // 触发系统授权弹窗，异步
    pub fn ohos_input_block(block: c_int);

    // --- 屏幕采集（被控端）---
    pub fn ohos_capture_can_start() -> c_int;
    pub fn ohos_capture_start(display_id: u32) -> c_int;
    pub fn ohos_capture_stop() -> c_int;

    // --- 编码帧回调：C++ 编码后把 H.264/H.265 packet 交给 Rust host 侧 ---
    // 回调签名：(codec, pts_us, is_key, data, len)，data 生命周期仅限回调内，Rust 侧需立即拷贝。
    pub fn ohos_capture_set_frame_callback(
        cb: Option<extern "C" fn(codec: c_int, pts_us: i64, is_key: c_int, data: *const u8, len: usize)>,
    );

    // --- 剪贴板 ---
    pub fn ohos_clipboard_get_text() -> *mut c_char;
    pub fn ohos_clipboard_set_text(text: *const c_char);

    // --- 显示器 ---
    // 简化签名：先取数量，再按 index 取字段，避免跨语言传复杂结构。
    pub fn ohos_display_count() -> c_int;
    pub fn ohos_display_info(index: c_int, out: *mut OhosDisplayInfo) -> c_int;

    // --- 通用 ---
    pub fn ohos_free_string(s: *mut c_char);
    pub fn ohos_log(level: c_int, tag: *const c_char, msg: *const c_char);
}

#[repr(C)]
#[derive(Default, Clone)]
pub struct OhosDisplayInfo {
    pub id: u32,
    pub width: u32,
    pub height: u32,
    pub rotation: u32,
    pub scale: f64,
    pub name: [c_char; 64],
}

pub fn display_info_list() -> Vec<OhosDisplayInfo> {
    let n = unsafe { ohos_display_count() };
    let mut out = Vec::with_capacity(n.max(0) as usize);
    for i in 0..n {
        let mut info = OhosDisplayInfo::default();
        if unsafe { ohos_display_info(i, &mut info) } == 0 {
            out.push(info);
        }
    }
    out
}
