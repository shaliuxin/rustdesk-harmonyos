//! C ABI 边界：Rust ←→ C++ (libentry.so / libohos_adapter.so)
//!
//! 为什么用 C ABI 而不是 napi-rs：
//!   - 音视频解码/渲染必须走 OH_AVCodec + XComponent Surface，只有 C/C++ 侧拿得到 Surface 句柄；
//!   - NAPI 线程安全函数（napi_create_threadsafe_function）在 C++ 侧更成熟；
//!   - C ABI 同时可被 Rust 静态库调用，双向调用链最短。
//!
//! 命名约定：`ohos_<子系统>_<动作>`，返回 0 成功 / 负数错误码。
//!
//! # 结构
//!
//! `raw` 子模块里是纯 `extern "C"` 声明（全部 unsafe）。**对外只暴露安全封装**：
//! 调用方（`super::*`）不应该看到裸指针，也不该到处写 `unsafe`。
//! 字符串统一转成 `String` / `Option<String>`，C++ 侧分配的内存由这里负责释放。

use std::os::raw::{c_char, c_int, c_uchar};

pub const DEVICE_TYPE_PHONE: c_int = 0;
pub const DEVICE_TYPE_TABLET: c_int = 1;
pub const DEVICE_TYPE_2IN1: c_int = 2;

mod raw {
    use super::*;

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
        pub fn ohos_input_query_authorized() -> c_int; // 0 未授权 / 1 授权中 / 2 已授权
        pub fn ohos_input_cancel_injection();
        pub fn ohos_input_inject_mouse_move(x: c_int, y: c_int) -> c_int;
        pub fn ohos_input_inject_mouse_button(
            button: c_int,
            down: c_int,
            x: c_int,
            y: c_int,
        ) -> c_int;
        pub fn ohos_input_inject_mouse_wheel(x: c_int, y: c_int, vertical: f32) -> c_int;
        pub fn ohos_input_inject_key(keycode: c_int, down: c_int) -> c_int;

        // --- 屏幕采集（被控端）---
        pub fn ohos_capture_can_start() -> c_int;
        pub fn ohos_capture_start(display_id: u32) -> c_int;
        pub fn ohos_capture_stop() -> c_int;

        // --- 编码帧回调：C++ 编码后把 H.264/H.265 packet 交给 Rust host 侧 ---
        // 回调签名：(codec, pts_us, is_key, data, len)，data 生命周期仅限回调内，Rust 侧需立即拷贝。
        pub fn ohos_capture_set_frame_callback(
            cb: Option<
                extern "C" fn(codec: c_int, pts_us: i64, is_key: c_int, data: *const u8, len: usize),
            >,
        );

        // --- 剪贴板 ---
        pub fn ohos_clipboard_get_text() -> *mut c_char;
        pub fn ohos_clipboard_set_text(text: *const c_char);

        // --- 显示器 ---
        // 简化签名：先取数量，再按 index 取字段，避免跨语言传复杂结构。
        pub fn ohos_display_count() -> c_int;
        pub fn ohos_display_info(index: c_int, out: *mut OhosDisplayInfo) -> c_int;

        // --- 指针位置 ---
        pub fn ohos_cursor_pos(out_x: *mut i32, out_y: *mut i32) -> c_int;

        // --- 通用 ---
        pub fn ohos_free_string(s: *mut c_char);
        pub fn ohos_free_bytes(p: *mut c_uchar);
        pub fn ohos_log(level: c_int, tag: *const c_char, msg: *const c_char);

        // --- UI 事件（Rust → ArkTS）---
        // C++ 侧用一个 napi threadsafe function 把 JSON 派发到主线程，
        // ArkTS 侧统一在 `rustdesk.on('event')` 上收。见 ui_handler.rs。
        pub fn ohos_ui_event(json: *const c_char);
    }
}

#[repr(C)]
#[derive(Clone)]
pub struct OhosDisplayInfo {
    pub id: u32,
    pub width: u32,
    pub height: u32,
    pub rotation: u32,
    pub scale: f64,
    pub name: [c_char; 64],
}

impl Default for OhosDisplayInfo {
    fn default() -> Self {
        // 不能 derive(Default)：`[c_char; 64]` 只在长度 ≤ 32 时才有 std 的 Default 实现。
        Self {
            id: 0,
            width: 0,
            height: 0,
            rotation: 0,
            scale: 0.0,
            name: [0; 64],
        }
    }
}

// ---------------------------------------------------------------------------
// 安全封装
// ---------------------------------------------------------------------------

/// 接管 C++ 侧返回的字符串，并释放其内存。
fn take_string(ptr: *mut c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe {
        let s = std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned();
        raw::ohos_free_string(ptr);
        s
    }
}

pub fn ohos_device_type() -> c_int {
    unsafe { raw::ohos_device_type() }
}

pub fn ohos_input_can_inject() -> c_int {
    unsafe { raw::ohos_input_can_inject() }
}

pub fn ohos_input_request_authorization() -> c_int {
    unsafe { raw::ohos_input_request_authorization() }
}

pub fn ohos_input_query_authorized() -> c_int {
    unsafe { raw::ohos_input_query_authorized() }
}

pub fn ohos_input_cancel_injection() {
    unsafe { raw::ohos_input_cancel_injection() }
}

pub fn ohos_input_inject_mouse_move(x: i32, y: i32) -> c_int {
    unsafe { raw::ohos_input_inject_mouse_move(x, y) }
}

pub fn ohos_input_inject_mouse_button(button: i32, down: bool, x: i32, y: i32) -> c_int {
    unsafe { raw::ohos_input_inject_mouse_button(button, down as c_int, x, y) }
}

pub fn ohos_input_inject_mouse_wheel(x: i32, y: i32, vertical: f32) -> c_int {
    unsafe { raw::ohos_input_inject_mouse_wheel(x, y, vertical) }
}

pub fn ohos_input_inject_key(keycode: i32, down: bool) -> c_int {
    unsafe { raw::ohos_input_inject_key(keycode, down as c_int) }
}


pub fn ohos_capture_can_start() -> c_int {
    unsafe { raw::ohos_capture_can_start() }
}

pub fn ohos_capture_start(display_id: u32) -> c_int {
    unsafe { raw::ohos_capture_start(display_id) }
}

pub fn ohos_capture_stop() -> c_int {
    unsafe { raw::ohos_capture_stop() }
}

pub fn ohos_get_active_user_name() -> String {
    unsafe { take_string(raw::ohos_get_active_user_name()) }
}

pub fn ohos_get_active_user_id() -> String {
    unsafe { take_string(raw::ohos_get_active_user_id()) }
}

pub fn ohos_is_locked() -> c_int {
    unsafe { raw::ohos_is_locked() }
}

pub fn ohos_lock_screen() -> c_int {
    unsafe { raw::ohos_lock_screen() }
}

pub fn ohos_input_block(block: c_int) {
    unsafe { raw::ohos_input_block(block) }
}

/// 取剪贴板纯文本。空字符串按「没有文本」处理（返回 `None`）。
pub fn ohos_clipboard_get_text() -> Option<String> {
    let s = unsafe { take_string(raw::ohos_clipboard_get_text()) };
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

pub fn ohos_clipboard_set_text(text: &str) {
    if let Ok(c) = std::ffi::CString::new(text) {
        unsafe { raw::ohos_clipboard_set_text(c.as_ptr()) };
    }
}

pub fn display_info_list() -> Vec<OhosDisplayInfo> {
    let n = unsafe { raw::ohos_display_count() };
    let mut out = Vec::with_capacity(n.max(0) as usize);
    for i in 0..n {
        let mut info = OhosDisplayInfo::default();
        if unsafe { raw::ohos_display_info(i, &mut info) } == 0 {
            out.push(info);
        }
    }
    out
}

/// `super::get_displays()` 需要的形式：`(id, name, width, height, scale)`。
///
/// 与 `OhosDisplayInfo` 的分工：C 结构体跨语言传参，这里做一次 Rust 侧的
/// 形状转换，顺手把 C 字符串的 `[c_char; 64]` 解成 `String`。
pub fn ohos_get_displays() -> Vec<(u32, String, u32, u32, f64)> {
    display_info_list()
        .into_iter()
        .map(|d| {
            let len = d.name.iter().position(|&c| c == 0).unwrap_or(d.name.len());
            let bytes: Vec<u8> = d.name[..len].iter().map(|&c| c as u8).collect();
            let name = String::from_utf8_lossy(&bytes).into_owned();
            (d.id, name, d.width, d.height, d.scale)
        })
        .collect()
}

/// 取本地指针位置。返回 0 表示成功。
pub fn ohos_get_cursor_pos(x: &mut i32, y: &mut i32) -> c_int {
    unsafe { raw::ohos_cursor_pos(x as *mut i32, y as *mut i32) }
}

/// 把一条 JSON 事件交给 C++ 侧派发到 ArkTS 主线程。
///
/// 失败（`json` 里有 NUL 字节）时静默丢弃：这是 UI 通道，不该因为一条
/// 消息让整个会话 panic。
pub fn ohos_ui_event(json: &str) {
    if let Ok(c) = std::ffi::CString::new(json) {
        unsafe { raw::ohos_ui_event(c.as_ptr()) };
    }
}

/// hilog 转发。`level`：0=debug 1=info 2=warn 3=error。
pub fn log(level: c_int, msg: &str) {
    if let Ok(c) = std::ffi::CString::new(msg) {
        unsafe { raw::ohos_log(level, b"rustdesk\0".as_ptr() as *const c_char, c.as_ptr()) };
    }
}
