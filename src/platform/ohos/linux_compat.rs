//! OHOS 的「桌面 linux」兼容层。
//!
//! # 为什么需要这个文件
//!
//! 在 Cargo 语义上 `aarch64-unknown-linux-ohos` 的 `target_os` 就是 `"linux"`，
//! 所以上游大量 `#[cfg(target_os = "linux")]` 代码块在鸿蒙上会**生效**，而这些块内部
//! 的路径写死了 `crate::platform::linux::xxx` —— 背后是 X11 / Wayland / PulseAudio /
//! systemd / xrandr 这一整套桌面假设，鸿蒙上一概不存在。
//!
//! 处理方式有两条路：
//!
//! - (a) 去上游文件里逐点把 `#[cfg(target_os = "linux")]` 改成
//!   `#[cfg(all(target_os = "linux", not(target_env = "ohos")))]`；
//! - (b) 在鸿蒙后端里提供**同名同签名**的 API，语义是「这里没有这套桌面设施」。
//!
//! 选 (b)。原因不是省事，而是可持续性：上游每次 merge 都可能新增 `platform::linux::`
//! 调用点，(a) 会让 Tier-2 补丁表无限膨胀、且漏一条就是一次 E0433；而 (b) 只要求
//! 我们维护**这一个文件**的 API 面，缺口集中、编译期就能发现。
//!
//! 这与 `ohos/third_party/{rdev,socket2,nix}` 的 vendored 空后端是同一个思路：
//! **用签名兼容的空实现换上游零改动**。
//!
//! # 暴露方式
//!
//! `super::linux` 子模块把本文件的内容 re-export 成 `crate::platform::linux::*`，
//! 于是上游的 `crate::platform::linux::is_x11()` 在鸿蒙上解析到这里。

use hbb_common::ResultType;

// `get_display_server()` 与两个常量是纯字符串逻辑（读 XDG_SESSION_TYPE 等环境变量），
// 不依赖 X11 库，直接从 base 复用即可 —— 鸿蒙上它们会退化为 "x11"（默认值），
// 但没有任何调用点会因此走进 X11 分支，因为下面 `is_x11()` 恒为 false。
pub use base::platform::linux::{get_display_server, DISPLAY_SERVER_WAYLAND, DISPLAY_SERVER_X11};

use base::message_proto::Resolution;

// ---------------------------------------------------------------------------
// 显示服务器探测：鸿蒙没有 X11，也没有 Wayland
// ---------------------------------------------------------------------------

/// 鸿蒙的显示服务是 ArkUI/Display Kit，不是 X11。
///
/// 上游此函数会真的去连 X server（`scrap::is_x11()`）；鸿蒙上直接 false，
/// 避免任何 X11 代码路径被激活。
pub fn is_x11() -> bool {
    false
}

/// DRM/KMS 采集路径专用，鸿蒙不走这条路。
pub fn is_x11_for_drm() -> bool {
    false
}

/// 当前是否 Wayland 会话。鸿蒙上恒 false。
pub fn current_is_wayland() -> bool {
    false
}

/// 桌面是否运行在 Wayland 上（未做「当前会话」判定的版本）。
pub fn is_desktop_wayland() -> bool {
    false
}

/// 登录界面是否 Wayland。鸿蒙无此概念。
pub fn is_login_screen_wayland() -> bool {
    false
}

/// `is_login_screen_wayland` 的记忆化版本（上游为省 `loginctl` 调用而存在）。
pub fn is_login_screen_wayland_cached() -> bool {
    false
}

/// 登录界面是否 Wayland（另一处入口，语义同上）。
pub fn is_login_wayland() -> bool {
    false
}

/// 强制指定显示服务器（上游的环境变量覆写）。鸿蒙无意义，返回 `None`。
pub fn display_server_forced() -> Option<String> {
    None
}

/// Wayland 显示探测子进程入口。
///
/// 上游会在 `main` 最开始调用它：如果命令行是 `--wayland-display-probe`，
/// 就在子进程里探测显示器后退出。鸿蒙没有 Wayland，直接返回。
pub fn dispatch_wayland_display_probe() {}

/// 右 Alt 是否为 level3 shift（用于 AltGr 组合键）。
///
/// 上游要连 X server 查 keymap；鸿蒙的键盘映射由 ArkTS 侧 `@ohos.multimodalInput`
/// 给出，Rust 侧不参与这一层，因此恒 false。
pub fn right_alt_is_level3_shift() -> ResultType<bool> {
    Ok(false)
}

// ---------------------------------------------------------------------------
// PulseAudio / PipeWire：鸿蒙用 OHAudio
// ---------------------------------------------------------------------------

/// 默认录音设备 `(id, 描述)`。鸿蒙的音频设备由 AVRecorder/OHAudio 管理，
/// 不存在 PulseAudio source 概念，返回 `None` 让调用方走默认设备。
pub fn get_default_pa_source() -> Option<(String, String)> {
    None
}

/// 列出所有 PulseAudio source `(name, description)`。鸿蒙返回空。
pub fn get_pa_sources() -> Vec<(String, String)> {
    vec![]
}

/// 按描述查 source 名。鸿蒙无 source，原样返回描述。
pub fn get_pa_source_name(desc: &str) -> String {
    desc.to_owned()
}

/// 默认监听设备（用于回环采集对端声音）。鸿蒙无 monitor source，返回空串。
pub fn get_pa_monitor() -> String {
    String::new()
}

/// 默认监听设备（可选形式）。鸿蒙返回 `None`。
pub fn get_default_pa_monitor() -> Option<String> {
    None
}

// ---------------------------------------------------------------------------
// 账号 / 会话
// ---------------------------------------------------------------------------

/// 当前活跃用户的 uid（记忆化版本）。
///
/// 鸿蒙没有 POSIX 多用户会话，`get_active_userid()` 返回 C++ 侧给出的字符串，
/// 这里按需解析成 u32；解析失败即 `None`。
pub fn get_active_userid_cached() -> Option<u32> {
    super::get_active_userid().parse::<u32>().ok()
}

// ---------------------------------------------------------------------------
// 服务安装（systemd / launchd / Windows SCM 的鸿蒙对应物：不存在）
// ---------------------------------------------------------------------------

/// 安装常驻服务。鸿蒙不允许普通应用安装系统服务，被控端改用长时任务
/// （`continuousTask`）维持后台运行，故恒 false。
pub fn install_service() -> bool {
    false
}

/// 卸载常驻服务。理由同上。
pub fn uninstall_service(_show_new_window: bool, __: bool) -> bool {
    false
}

/// 退出 GUI 主循环（GTK/Sciter 专用）。鸿蒙没有 GUI 主循环，空实现。
pub fn quit_gui() {}

// ---------------------------------------------------------------------------
// 分辨率切换：鸿蒙由 ArkTS 的 display 模块管理，Rust 侧不介入
// ---------------------------------------------------------------------------

/// 列出某个显示器支持的分辨率。鸿蒙返回空列表 —— 调用方据此不会展示「切换分辨率」。
pub fn resolutions(_name: &str) -> Vec<Resolution> {
    vec![]
}

// ---------------------------------------------------------------------------
// 壁纸移除（进入隐私模式时清空桌面壁纸，防泄漏）
// ---------------------------------------------------------------------------

/// 鸿蒙没有「桌面壁纸」这个可被远端看到的概念（手机桌面不会出现在屏幕共享里），
/// 因此这是空实现。保留类型与签名，是因为 `src/server/connection.rs` 里的
/// `WALLPAPER_REMOVER` 静态量在 `cfg(any(windows, target_os = "linux"))` 下必然存在。
#[derive(Default)]
pub struct WallPaperRemover;

impl WallPaperRemover {
    pub fn new() -> ResultType<Self> {
        // 与上游语义对齐：没有壁纸可移除时返回 Err，调用方会静默忽略。
        hbb_common::bail!("wallpaper not applicable on HarmonyOS")
    }

    pub fn support() -> bool {
        false
    }
}

// ---------------------------------------------------------------------------
// WakeLock：鸿蒙用 wantAgent / 长时任务，不用 logind
// ---------------------------------------------------------------------------

/// 防止设备休眠。
///
/// 上游 linux 版持有 `keepawake::AwakeHandle`（走 logind / ScreenSaver 的 D-Bus
/// inhibit）。鸿蒙上这套接口不存在，真正的保活由 ArkTS 侧申请长时任务
/// （`BackgroundTasksKit`）完成 —— 那是应用级授权，不是 Rust 能直接调的。
///
/// 这里保留空类型，使 `platform::get_wakelock()` 的调用链在鸿蒙上依然成立；
/// 保活能力由 `ffi` 侧的 `ohos_keep_screen_on()` 在 C++ 层补齐（见 ARCHITECTURE.md §5）。
#[derive(Default)]
pub struct WakeLock;

impl WakeLock {
    pub fn new(_display: bool, _idle: bool, _sleep: bool) -> Self {
        Self
    }
}
