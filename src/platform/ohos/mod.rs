//! OpenHarmony / HarmonyOS NEXT platform backend.
//!
//! 设计约束（见 docs/ohos/ARCHITECTURE.md）：
//!   1. 本文件及其子模块是**新增文件**，不修改上游任何逻辑，降低合并冲突。
//!   2. 所有系统能力通过 `ffi` 子模块的 C ABI 调用 C++ 侧实现
//!      （C++ 侧才能拿到 AVScreenCapture / OH_VideoEncoder / OH_Input / pasteboard 的 NDK 接口）。
//!   3. 控制端（controller）只需本文件的最小集合；被控端（host）能力按 capability 探测结果降级。
//!
//! 与上游 linux 平台层（src/platform/linux.rs，54 个 pub fn）的对应关系：
//!   控制端必需：get_active_username / get_cursor_pos / is_locked / is_prelogin / get_display_*
//!   被控端需要：start_os_service / is_installed / get_pa_sources / block_input / lock_screen ...

use hbb_common::ResultType;

pub mod ffi;

// --- 主控（控制端）：ArkTS UI ↔ 上游 io_loop 之间的适配层 ---
//
// 三个模块的分层（依赖方向自上而下，不反向）：
//   entry      C ABI 导出，ArkTS/C++ 唯一入口
//   session    Session<OhosUiSession> 的创建与生命周期，内部复用上游 io_loop
//   ui_handler InvokeUiSession 的鸿蒙实现：帧槽 + JSON 事件
pub mod entry;
pub mod files;
pub mod keymap;
pub mod session;
pub mod ui_handler;

/// 桌面 linux API 的鸿蒙等价物（X11/Wayland/PulseAudio/systemd → 空或降级）。
///
/// 上游有大量 `#[cfg(target_os = "linux")]` 块在鸿蒙上会生效，块内路径写死
/// `crate::platform::linux::xxx`。本模块提供同名同签名的实现，配合下面的
/// `linux` 别名模块，使这些调用点无需任何改动即可解析。
pub mod linux_compat;

// 提到 `platform::` 顶层：`src/platform/mod.rs` 的 `pub use ohos::*;` 只搬运
// 本模块的**直接**成员，不递归进子模块。少了这行，`platform::quit_gui`、
// `platform::WallPaperRemover`、`platform::install_service` 这些仍然找不到。
pub use linux_compat::*;

/// 把 [`linux_compat`] 暴露为 `crate::platform::linux`。
///
/// `src/platform/mod.rs` 里 `pub use ohos::*;` 会把本模块提到 `platform::linux`，
/// 而 DESKTOP 的 `pub mod linux;` 已被 `not(target_env = "ohos")` 排除，
/// 因此不会重名。
///
/// 内容 = linux_compat 的全部 + 本模块顶层的账号函数。后者是上游
/// `crate::platform::linux::get_active_userid()` 这种写法在鸿蒙上的落点
/// （`src/ipc/auth.rs` 就这样调）。
pub mod linux {
    pub use super::get_active_userid;
    pub use super::linux_compat::*;
}

pub const PA_SAMPLE_RATE: u32 = 48000;

/// HarmonyOS device form factor. 决定被控端能力上限（见 ARCHITECTURE.md §6）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceType {
    Phone,
    Tablet,
    TwoInOne,
    Unknown,
}

pub fn device_type() -> DeviceType {
    match ffi::ohos_device_type() {
        ffi::DEVICE_TYPE_PHONE => DeviceType::Phone,
        ffi::DEVICE_TYPE_TABLET => DeviceType::Tablet,
        ffi::DEVICE_TYPE_2IN1 => DeviceType::TwoInOne,
        _ => DeviceType::Unknown,
    }
}

/// 本机能否注入输入事件。仅有 2in1/PC 形态 + 用户已授权时为 true。
/// 手机/平板恒为 false —— 平台不开放 inject 接口，任何实现都不得绕过。
pub fn can_inject_input() -> bool {
    ffi::ohos_input_can_inject() == 1
}

/// 本机能否采集屏幕（被控端前置条件）。手机需要用户每次授权，2in1 可申请受限权限。
pub fn can_capture_screen() -> bool {
    ffi::ohos_capture_can_start() == 1
}

pub fn get_active_username() -> String {
    ffi::ohos_get_active_user_name()
}

pub fn get_active_userid() -> String {
    ffi::ohos_get_active_user_id()
}

pub fn get_user_home_by_name(_user: &str) -> String {
    // HarmonyOS 无 POSIX home 概念，应用沙箱路径由 ArkTS 侧提供。
    String::new()
}

pub fn is_prelogin() -> bool {
    false
}

pub fn is_locked() -> bool {
    ffi::ohos_is_locked() == 1
}

pub fn is_root() -> bool {
    false
}

pub fn is_installed() -> bool {
    true
}

pub fn start_os_service() -> ResultType<()> {
    // HarmonyOS 不允许普通应用安装常驻服务；被控端使用长时任务（continuousTask）。
    hbb_common::bail!("not supported on HarmonyOS");
}

pub fn get_cursor_pos() -> ResultType<(i32, i32)> {
    let (mut x, mut y) = (0, 0);
    if ffi::ohos_get_cursor_pos(&mut x, &mut y) == 0 {
        Ok((x, y))
    } else {
        hbb_common::bail!("no cursor on HarmonyOS")
    }
}

pub fn block_input(_block: bool) -> ResultType<()> {
    // 仅被控端 2in1 使用；手机形态直接拒绝。
    if can_inject_input() {
        ffi::ohos_input_block(_block as i32);
        Ok(())
    } else {
        hbb_common::bail!("input injection unavailable")
    }
}

pub fn lock_screen() -> ResultType<()> {
    if ffi::ohos_lock_screen() == 0 {
        Ok(())
    } else {
        hbb_common::bail!("lock_screen failed")
    }
}

// --- 剪贴板：控制端与被控端都用到，走 C++ pasteboard ---

pub fn get_clipboard_text() -> Option<String> {
    ffi::ohos_clipboard_get_text()
}

pub fn set_clipboard_text(text: &str) {
    ffi::ohos_clipboard_set_text(text);
}

// --- 屏幕 / 显示器信息：被控端 video_service 需要 ---

/// 返回 (display_id, name, width, height, scale) 列表，由 C++ 侧通过 Display Kit 获取。
pub fn get_displays() -> Vec<(u32, String, u32, u32, f64)> {
    ffi::ohos_get_displays()
}
