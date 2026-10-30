#!/usr/bin/env python3
"""
OpenHarmony 移植：幂等重写上游 cfg 谓词。

为什么需要脚本而不是手改：
    上游 src/ 有 330 处 `not(any(target_os = "android", target_os = "ios"))` 与
    615 处 `target_os = "android"`。手改会产生大量 diff，每次同步上游必冲突。
    本脚本把「OHOS 属于第三类移动端」这一判断以**可重复执行**的方式施加：
        - 只放宽「非桌面平台」这一组谓词（加上 target_env = "ohos"）
        - 不动任何 android 专属分支（jni / mediacodec / android_logger）
    因此每次 `git merge upstream/master` 后重跑本脚本即可得到等价工作树，
    冲突面被压到「新增文件 + 本脚本」这一层。

用法：
    python scripts/ohos/apply-mobile-cfg.py           # 施加（幂等）
    python scripts/ohos/apply-mobile-cfg.py --check   # 只检查是否已全部施加（CI 用）
    python scripts/ohos/apply-mobile-cfg.py --dry-run # 只看会改多少处
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

NEG = 'not(any(target_os = "android", target_os = "ios"))'
NEG_OHOS = 'not(any(target_os = "android", target_os = "ios", target_env = "ohos"))'

POS = 'any(target_os = "android", target_os = "ios")'
POS_OHOS = 'any(target_os = "android", target_os = "ios", target_env = "ohos")'

# `ohos/` 是 Tier-1 自研目录：shim 与 vendored crate 的 cfg 已按需要手写，
# 不能再用「android/ios 谓词补 ohos」的通用规则去改，否则会破坏它们对其他平台的行为。
SKIP_DIRS = {".git", "target", "node_modules", "flutter", "docs", "ohos"}


# ---------------------------------------------------------------------------
# 定向补丁表
# ---------------------------------------------------------------------------
# 谓词重写只能处理「模式化」的判断，解决不了这三类问题：
#   1. 裸 `cfg(target_os = "linux")` 引用了 OHOS 上不可用的 crate（users/x11）
#   2. 上游代码引用了当前 feature 集里不存在的枚举变体（Connector::NativeTls）
#   3. 子模块（libs/hbb_common）里的代码
# 这些改动逐条登记、精确匹配、幂等；不做全文替换，避免误伤。
# 匹配串必须与上游当前版本逐字节一致，上游改动后此处会自动「不生效」而不是误改。
PATCHES: list[tuple[str, str, str]] = [
    # ---------------------------------------------------------------------
    # 模块级排除：这些模块在 OHOS 上既无系统接口也无法编译，
    # 上游用 `target_os = "linux"` 或「非 ios」来框定它们，鸿蒙会误入。
    # ---------------------------------------------------------------------
    # server.rs 的 cfg_if 外层：OHOS 走移动端分支（input_service 置空壳），
    # 否则 uinput/rdp_input/dbus/wayland 会全部编进来，并与后面
    # `#[cfg(any(android, ios, ohos))] pub mod input_service` 重名冲突。
    (
        "src/server.rs",
        'if #[cfg(not(target_os = "ios"))] {\nmod clipboard_service;',
        'if #[cfg(not(any(target_os = "ios", target_env = "ohos")))] {\nmod clipboard_service;',
    ),
    # lib.rs: sciter 桌面 UI
    (
        "src/lib.rs",
        """#[cfg(not(any(
    target_os = "android",
    target_os = "ios",
    feature = "flutter"
)))]
pub mod ui;""",
        """#[cfg(not(any(
    target_os = "android",
    target_os = "ios",
    target_env = "ohos",
    feature = "flutter"
)))]
pub mod ui;""",
    ),
    # lib.rs: 命名管道 IPC（Windows/Unix socket 的桌面控制通道）
    # lib.rs: 桌面文件剪贴板（arboard + fs 轮询），OHOS 走 Pasteboard NDK
    (
        "src/lib.rs",
        '#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]\npub mod clipboard_file;',
        '#[cfg(all(\n    any(target_os = "windows", target_os = "linux", target_os = "macos"),\n    not(target_env = "ohos")\n))]\npub mod clipboard_file;',
    ),
    # --- 桌面专属的类型/函数引用 ---
    (
        "src/server/connection.rs",
        '#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]\nuse crate::clipboard_file::*;',
        '#[cfg(all(\n    any(target_os = "windows", target_os = "linux", target_os = "macos"),\n    not(target_env = "ohos")\n))]\nuse crate::clipboard_file::*;',
    ),
    # 注：`use crate::platform::WallPaperRemover;` 的 import 条件此处不再收紧 ——
    # 鸿蒙需要它（ConnInner 旁边的 WALLPAPER_REMOVER 静态量在 `any(windows, linux)` 下
    # 仍然存在），类型由 platform::ohos::linux_compat 的空实现提供。
    # 对应的补丁见下方「WallPaperRemover 的 import」一节。
    (
        "src/server/display_service.rs",
        '#[cfg(target_os = "linux")]\nuse crate::platform::linux::is_x11;',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]\nuse crate::platform::linux::is_x11;',
    ),
    (
        "src/server/video_service.rs",
        '#[cfg(target_os = "linux")]\nuse crate::platform::linux::is_x11;',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]\nuse crate::platform::linux::is_x11;',
    ),
    # --- users / x11：Cargo 侧已按 not(target_env = "ohos") 排除，源码侧同步 ---
    (
        "libs/hbb_common/src/lib.rs",
        '#[cfg(target_os = "linux")]\npub use users;',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]\npub use users;',
    ),
    (
        "libs/hbb_common/src/lib.rs",
        '#[cfg(target_os = "linux")]\npub use x11;',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]\npub use x11;',
    ),
    # --- Connector::NativeTls：该变体只在 tokio-tungstenite 的 native-tls feature 下存在，
    #     而该 feature 会引入 native-tls -> openssl-sys（OHOS 无法交叉编译），
    #     故已在 libs/hbb_common/Cargo.toml 里摘掉该 feature。
    #     变体消失后，NativeTls 分支在任何目标上都无法编译 —— 包括宿主：
    #     hbb_common 同时是根 crate 的 build-dependency（build.rs 调用 gen_version），
    #     会被编到 Windows 宿主，而宿主侧 cfg(target_env = "ohos") 不成立。
    #     因此不能只给 OHOS 加 cfg，必须整体降级为 rustls，与 TlsType::Rustls 合流。
    #     这不改变本仓库桌面端实际行为：tokio-native-tls 已被根 Cargo.toml 的
    #     [patch.crates-io] 全局替换为 rustls 实现。 ---
    (
        "libs/hbb_common/src/websocket.rs",
        """            TlsType::NativeTls => {
                let connector = TlsConnector::builder()
                    .danger_accept_invalid_certs(danger_accept_invalid_certs)
                    .build()?;
                Ok(Some(Connector::NativeTls(connector)))
            }
            TlsType::Rustls => {""",
        """            // native-tls feature 已摘除（openssl-sys 在 OHOS 无后端），两条路径统一走 rustls。
            TlsType::NativeTls | TlsType::Rustls => {""",
    ),
    # --- keyboard.rs：CUR_SESSION 属于 sciter 前端的「当前会话」单例 ---
    # 鸿蒙上 UI 在 ArkTS 侧，Rust 侧没有 SciterHandler，故排除引用；
    # 键盘模式退化为 "legacy"（见下面的 get_keyboard_mode）。
    (
        "src/keyboard.rs",
        '#[cfg(not(feature = "flutter"))]\nuse crate::ui::CUR_SESSION;',
        '#[cfg(all(not(feature = "flutter"), not(target_env = "ohos")))]\nuse crate::ui::CUR_SESSION;',
    ),
    (
        "src/keyboard.rs",
        """    #[cfg(not(feature = "flutter"))]
    if let Some(session) = CUR_SESSION.lock().unwrap().as_ref() {
        session.send_key_event(key_event);
    }""",
        """    #[cfg(all(not(feature = "flutter"), not(target_env = "ohos")))]
    if let Some(session) = CUR_SESSION.lock().unwrap().as_ref() {
        session.send_key_event(key_event);
    }""",
    ),
    # --- keyboard.rs：log / AtomicBool 的 import 被通用规则连桌面一起挡掉了，
    #     但 `#[cfg(target_os = "linux")]` 的 rdev 抓取线程块在鸿蒙上仍会编译。 ---
    (
        "src/keyboard.rs",
        '#[cfg(not(any(target_os = "android", target_os = "ios", target_env = "ohos")))]\nuse hbb_common::log;',
        '#[cfg(not(any(target_os = "android", target_os = "ios", target_env = "ohos")))]\nuse hbb_common::log;\n#[cfg(target_env = "ohos")]\nuse hbb_common::log;',
    ),
    (
        "src/keyboard.rs",
        '#[cfg(not(any(target_os = "android", target_os = "ios", target_env = "ohos")))]\nuse std::sync::atomic::{AtomicBool, Ordering};',
        '#[cfg(not(any(target_os = "android", target_os = "ios", target_env = "ohos")))]\nuse std::sync::atomic::{AtomicBool, Ordering};\n#[cfg(target_env = "ohos")]\nuse std::sync::atomic::{AtomicBool, Ordering};',
    ),
    # --- keyboard.rs：get_keyboard_mode 只在 `#[cfg(target_os="linux")]` 的
    #     rdev 抓取回调里被调用。鸿蒙没有 sciter 会话，恒返回 "legacy"（直通码）。 ---
    (
        "src/keyboard.rs",
        """#[cfg(not(any(target_os = "android", target_os = "ios", target_env = "ohos")))]
fn get_keyboard_mode() -> String {""",
        """/// OHOS：没有 sciter 会话可查，键盘始终按直通码（legacy）解释。
#[cfg(target_env = "ohos")]
fn get_keyboard_mode() -> String {
    "legacy".to_string()
}

#[cfg(not(any(target_os = "android", target_os = "ios", target_env = "ohos")))]
fn get_keyboard_mode() -> String {""",
    ),
    # --- connection.rs：flutter 的 channel 只在 android 上启动 ---
    # 上游这行 import 把 DEVICE_NAME 和 start_channel 写在一起，鸿蒙只需要前者。
    (
        "src/server/connection.rs",
        '#[cfg(any(target_os = "android", target_os = "ios", target_env = "ohos"))]\nuse crate::{common::DEVICE_NAME, flutter::connection_manager::start_channel};',
        '#[cfg(any(target_os = "android", target_os = "ios", target_env = "ohos"))]\nuse crate::common::DEVICE_NAME;\n#[cfg(target_os = "android")]\nuse crate::flutter::connection_manager::start_channel;',
    ),
    # --- ipc.rs：终端会话数走 pty（terminal_service），鸿蒙无终端功能 ---
    (
        "src/ipc.rs",
        '#[cfg(target_os = "linux")]\n        Data::TerminalSessionCount(_) => {',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]\n        Data::TerminalSessionCount(_) => {',
    ),
    # --- ipc.rs：start_pa 是 PulseAudio 转发进程，鸿蒙用 OHAudio（C++ 侧） ---
    (
        "src/ipc.rs",
        '#[cfg(target_os = "linux")]\n#[tokio::main(flavor = "current_thread")]\npub async fn start_pa() {',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]\n#[tokio::main(flavor = "current_thread")]\npub async fn start_pa() {',
    ),
    # --- client.rs：播放走 PulseAudio 的版本排除；鸿蒙暂由 C++ 侧 OHAudio 接管 ---
    (
        "src/client.rs",
        '    #[cfg(target_os = "linux")]\n    fn start_audio(&mut self, format0: AudioFormat) -> ResultType<()> {\n        use psimple::Simple;',
        '    /// OHOS：音频播放由 OHAudio（C++ 侧）接管，Rust 侧暂不参与。\n    #[cfg(target_env = "ohos")]\n    fn start_audio(&mut self, _format0: AudioFormat) -> ResultType<()> {\n        Ok(())\n    }\n\n    #[cfg(all(target_os = "linux", not(target_env = "ohos")))]\n    fn start_audio(&mut self, format0: AudioFormat) -> ResultType<()> {\n        use psimple::Simple;',
    ),
    # --- rendezvous_mediator.rs：LAN 发现开关 ---
    # 上游只给 android 置 true。鸿蒙同样拿不到 mac 地址（见 lan.rs 的注释），
    # 且同一 Wi-Fi 下直连是刚需，故与 android 同列。
    (
        "src/rendezvous_mediator.rs",
        '#[cfg(target_os = "android")]\n        let start_lan_listening = true;',
        '#[cfg(any(target_os = "android", target_env = "ohos"))]\n        let start_lan_listening = true;',
    ),
    # --- io_loop.rs：rx 的定义已被 not(ohos) 挡掉，后面的 if let 也要同步 ---
    (
        "src/client/io_loop.rs",
        '#[cfg(not(target_os = "ios"))]\n                            if let Some(mut rx) = rx {',
        '#[cfg(not(any(target_os = "ios", target_env = "ohos")))]\n                            if let Some(mut rx) = rx {',
    ),
    # --- server.rs：clipboard_service 是桌面剪贴板服务（arboard + 文件剪贴板） ---
    # cfg_if 已把鸿蒙划进空壳分支，这里同步去掉它的注册。
    (
        "src/server.rs",
        '        server.add_service(Box::new(display_service::new()));\n        server.add_service(Box::new(clipboard_service::new(\n            clipboard_service::NAME.to_owned(),\n        )));',
        '        server.add_service(Box::new(display_service::new()));\n        #[cfg(not(target_env = "ohos"))]\n        server.add_service(Box::new(clipboard_service::new(\n            clipboard_service::NAME.to_owned(),\n        )));',
    ),
    # --- ui_interface.rs：get_id 的 cfg 漏了 ohos，函数体里却已有 ohos 分支 ---
    (
        "src/ui_interface.rs",
        '#[cfg(any(target_os = "android", target_os = "ios", feature = "flutter"))]\n#[inline]\npub fn get_id() -> String {',
        '#[cfg(any(\n    target_os = "android",\n    target_os = "ios",\n    target_env = "ohos",\n    feature = "flutter"\n))]\n#[inline]\npub fn get_id() -> String {',
    ),
    # --- keyboard.rs：get_peer_platform 也读 CUR_SESSION（第二处） ---
    (
        "src/keyboard.rs",
        """    #[cfg(not(feature = "flutter"))]
    if let Some(session) = CUR_SESSION.lock().unwrap().as_ref() {
        return session.peer_platform();
    }""",
        """    #[cfg(all(not(feature = "flutter"), not(target_env = "ohos")))]
    if let Some(session) = CUR_SESSION.lock().unwrap().as_ref() {
        return session.peer_platform();
    }""",
    ),
    # --- connection.rs：WallPaperRemover 的 import ---
    # 上游用 `all(any(windows, linux), not(ohos))` 挡掉了鸿蒙，但 244 行的
    # WALLPAPER_REMOVER 静态量仍在 `any(windows, linux)` 条件下需要该类型。
    # linux_compat 已提供空实现，这里把 import 放开。
    (
        "src/server/connection.rs",
        """#[cfg(all(
    any(target_os = "windows", target_os = "linux"),
    not(target_env = "ohos")
))]
use crate::platform::WallPaperRemover;""",
        """#[cfg(any(target_os = "windows", target_os = "linux"))]
use crate::platform::WallPaperRemover;""",
    ),
    # --- ui_session_interface.rs：语音通话的 PulseAudio 转发线程 ---
    (
        "src/ui_session_interface.rs",
        '#[cfg(target_os = "linux")]\n        std::thread::spawn(crate::ipc::start_pa);',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]\n        std::thread::spawn(crate::ipc::start_pa);',
    ),
    # --- lang.rs：translate 依赖 sys_locale，移动端都没有 ---
    (
        "src/lang.rs",
        '#[cfg(not(any(target_os = "android", target_os = "ios", target_env = "ohos")))]\npub fn translate(name: String) -> String {',
        '/// OHOS：没有 sys_locale（语言由 ArkTS 侧决定并写进 Config），退回不翻译。\n/// 与 android/ios 的处理一致 —— 它们也没有这个函数，只是上游没在移动端调用它。\n#[cfg(target_env = "ohos")]\npub fn translate(name: String) -> String {\n    name\n}\n\n#[cfg(not(any(target_os = "android", target_os = "ios", target_env = "ohos")))]\npub fn translate(name: String) -> String {',
    ),
    # --- input_service 空壳：补 setup_rdp_input ---
    # connection.rs 在 `#[cfg(target_os = "linux")]` 里调它（Wayland 下 uinput 不可用时
    # 退到 RDP 输入通道）。鸿蒙的 wayland_use_rdp_input() 恒 false，走不到，但要有符号。
    (
        "src/server.rs",
        '    /// 是否用 uinput 注入。鸿蒙没有 /dev/uinput。\n    #[cfg(target_env = "ohos")]\n    pub fn wayland_use_uinput() -> bool {\n        false\n    }',
        '    /// 是否用 uinput 注入。鸿蒙没有 /dev/uinput。\n    #[cfg(target_env = "ohos")]\n    pub fn wayland_use_uinput() -> bool {\n        false\n    }\n\n    /// 建立 RDP 输入通道。鸿蒙不走 Wayland 门户，不可能被调用；仅为符号完整。\n    #[cfg(target_env = "ohos")]\n    pub async fn setup_rdp_input(\n    ) -> Result<(), Box<dyn std::error::Error>> {\n        Ok(())\n    }',
    ),
    # --- clipboard.rs：三处裸 `cfg(target_os = "linux")` ---
    # 这些位置调用的都是「桌面侧」的符号（arboard / ClipboardContext /
    # read_clipboard_message / append_owner_marker），它们本身的门控是
    # `not(any(android, ohos))`。鸿蒙的 target_os 是 linux，裸谓词会让这几处被编译，
    # 却引用到已被排除的符号。改成与它们依赖的符号同一套谓词即可。
    (
        "src/clipboard.rs",
        '#[cfg(target_os = "linux")]\nuse arboard::{LinuxClipboardKind, SetExtLinux};',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]\nuse arboard::{LinuxClipboardKind, SetExtLinux};',
    ),
    (
        "src/clipboard.rs",
        '#[cfg(target_os = "linux")]\npub fn peek_clipboard(',
        '#[cfg(not(any(target_os = "android", target_env = "ohos")))]\npub fn peek_clipboard(',
    ),
    (
        "src/clipboard.rs",
        '#[cfg(target_os = "linux")]\npub fn set_text_clipboard_with_owner_sync(text: &str, side: ClipboardSide) -> ResultType<()> {',
        '#[cfg(not(any(target_os = "android", target_env = "ohos")))]\npub fn set_text_clipboard_with_owner_sync(text: &str, side: ClipboardSide) -> ResultType<()> {',
    ),
    # --- client.rs：clipboard_listener 只在桌面侧存在 ---
    # `clipboard_listener` 模块本身的门控是 `not(any(android, ohos))`，
    # 这里的 `not(android)` 在鸿蒙上会成立，于是引用到不存在的模块。
    (
        "src/client.rs",
        '        #[cfg(not(target_os = "android"))]\n        clipboard_listener::unsubscribe(Self::CLIENT_CLIPBOARD_NAME);',
        '        #[cfg(not(any(target_os = "android", target_env = "ohos")))]\n        clipboard_listener::unsubscribe(Self::CLIENT_CLIPBOARD_NAME);',
    ),
    # --- client.rs：AudioHandler 的 psimple 字段 ---
    # psimple/pulse 只出现在 `cfg(all(target_os = "linux", not(ohos)))` 的依赖段，
    # 但上游在 `#[cfg(target_os = "linux")]` 的分支里三处读写 `self.simple`
    # （能否复用流、是否就绪、frame 写入）。鸿蒙上 start_audio 已是空实现、
    # frame 也走不到，所以这里不删字段，而是换成一个零尺寸占位类型 —— 既保留
    # 上游 linux 分支的可编译性，又不需要引入 PulseAudio。
    (
        "src/client.rs",
        '    #[cfg(target_os = "linux")]\n    simple: Option<psimple::Simple>,',
        '    #[cfg(all(target_os = "linux", not(target_env = "ohos")))]\n    simple: Option<psimple::Simple>,\n    /// OHOS：PulseAudio 占位。start_audio 是空实现，永远不会被写入。\n    #[cfg(target_env = "ohos")]\n    simple: Option<OhosAudioSink>,',
    ),
    (
        "src/client.rs",
        '/// Audio handler for the [`Client`].\n#[derive(Default)]\npub struct AudioHandler {',
        '/// OHOS：PulseAudio 的占位替身。鸿蒙没有 PulseAudio 服务，`start_audio`\n/// 在鸿蒙上是空实现，因此这个 sink 永远不会被创建或被写入。\n#[cfg(target_env = "ohos")]\n#[derive(Default)]\nstruct OhosAudioSink;\n\n#[cfg(target_env = "ohos")]\nimpl OhosAudioSink {\n    fn write(&mut self, _data: &[u8]) {}\n}\n\n/// Audio handler for the [`Client`].\n#[derive(Default)]\npub struct AudioHandler {',
    ),
    # --- io_loop.rs：初始剪贴板同步的 linux 专用等待逻辑 ---
    # 该函数依赖 clipboard_listener::wait_for_ready / current_generation 与
    # `Data::InitialClipboard` 变体，三者都是桌面侧符号。鸿蒙走 `not(linux)` 一侧的
    # spawn_blocking 路径（与 android 相同）。
    (
        "src/client/io_loop.rs",
        '    #[cfg(target_os = "linux")]\n    fn spawn_initial_clipboard_read_after_ready(&self, read_clipboard: impl FnOnce() + Send + \'static) {',
        '    #[cfg(not(any(target_os = "android", target_env = "ohos")))]\n    fn spawn_initial_clipboard_read_after_ready(&self, read_clipboard: impl FnOnce() + Send + \'static) {',
    ),
    # --- connection.rs：终端用户令牌 ---
    # `ConnInner::terminal_user_token` 字段的门控是 `not(any(android, ios, ohos))`，
    # 但这个 linux/macos 版本的方法在鸿蒙上仍会被编译（target_os = "linux"），
    # 于是往一个不存在的字段里赋值。它的唯一调用方
    # `prepare_terminal_login_for_authorization` 本身已排除鸿蒙，整个方法可以一起排除。
    (
        "src/server/connection.rs",
        '    #[cfg(any(target_os = "linux", target_os = "macos"))]\n    fn fill_terminal_user_token(',
        '    #[cfg(all(\n        any(target_os = "linux", target_os = "macos"),\n        not(target_env = "ohos")\n    ))]\n    fn fill_terminal_user_token(',
    ),
    # --- hbbs_http：reqwest 的 native-tls ---
    # 鸿蒙构建里 reqwest 只启用 rustls（系统没有 OpenSSL），
    # `use_native_tls()` 方法因此不存在。TlsType::NativeTls 在鸿蒙上降级到
    # rustls 的预配置客户端 —— 与 Rustls 分支的移动端行为一致。
    (
        "src/hbbs_http/http_client.rs",
        """            TlsType::NativeTls => {
                builder = builder.use_native_tls();
                if $danger_accept_invalid_cert {
                    builder = builder.danger_accept_invalid_certs(true);
                }
            }""",
        """            TlsType::NativeTls => {
                // OHOS：reqwest 未启用 native-tls feature，统一降级到 rustls。
                #[cfg(target_env = "ohos")]
                match hbb_common::verifier::client_config($danger_accept_invalid_cert) {
                    Ok(client_config) => {
                        builder = builder.use_preconfigured_tls(client_config);
                    }
                    Err(e) => {
                        hbb_common::log::error!("Failed to get client config: {}", e);
                    }
                }
                #[cfg(not(target_env = "ohos"))]
                {
                    builder = builder.use_native_tls();
                    if $danger_accept_invalid_cert {
                        builder = builder.danger_accept_invalid_certs(true);
                    }
                }
            }""",
    ),
]


# ---------------------------------------------------------------------------
# 文件级规则：把某个文件里的「linux」读作「桌面 linux」
# ---------------------------------------------------------------------------
# PATCHES 只能精确匹配单条语句。像 camera.rs 这种「windows|linux 真实现 + 其余平台空实现」
# 成对出现、同一谓词重复十几次的文件，逐条写补丁既啰嗦又容易漏；改成整文件正则。
# 替换后的文本不再包含原谓词，因此同样幂等。
FILE_RULES: list[tuple[str, str, str]] = [
    (
        "libs/scrap/src/common/camera.rs",
        r'not\(any\(target_os = "windows", target_os = "linux"\)\)',
        'not(any(target_os = "windows", all(target_os = "linux", not(target_env = "ohos"))))',
    ),
    (
        "libs/scrap/src/common/camera.rs",
        r'any\(target_os = "windows", target_os = "linux"\)',
        'any(target_os = "windows", all(target_os = "linux", not(target_env = "ohos")))',
    ),
    # 这两个文件里的 `#[cfg(target_os = "linux")]` 全部是 X11/Wayland 专属路径
    # （is_x11、wayland 快照、uinput 坐标换算），OHOS 一概不适用。
    (
        "src/server/display_service.rs",
        r'#\[cfg\(target_os = "linux"\)\]',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]',
    ),
    (
        "src/server/video_service.rs",
        r'#\[cfg\(target_os = "linux"\)\]',
        '#[cfg(all(target_os = "linux", not(target_env = "ohos")))]',
    ),
    # --- sciter 前端专属代码 ---
    # 这两个文件里 `not(any(android, ios, feature = "flutter"))` 包住的全是 sciter
    # 那一侧的东西：ui_interface.rs 是「派生新窗口进程 + 僵尸进程回收」，
    # file_trait.rs 是返回 sciter::Value 的目录浏览方法。
    # 鸿蒙的前端是 ArkTS，没有 sciter，也没有多窗口子进程模型，整段排除。
    (
        "src/ui_interface.rs",
        r'not\(any\(target_os = "android", target_os = "ios", feature = "flutter"\)\)',
        'not(any(target_os = "android", target_os = "ios", target_env = "ohos", feature = "flutter"))',
    ),
    (
        "src/client/file_trait.rs",
        r'not\(any\(\s*target_os = "android",\s*target_os = "ios",\s*feature = "flutter"\s*\)\)',
        'not(any(\n        target_os = "android",\n        target_os = "ios",\n        target_env = "ohos",\n        feature = "flutter"\n    ))',
    ),
    # --- clipboard.rs：把鸿蒙并入「移动端」一侧 ---
    # 上游把这个文件按「android / 桌面」二分：桌面侧走 arboard + clipboard-master，
    # 移动侧走 platform 层的纯文本读写（android 是 ClipboardManager，鸿蒙是
    # OH_Pasteboard —— 已由 src/platform/ohos 的 get/set_clipboard_text 接好）。
    #
    # 鸿蒙本来就是移动端，且 Cargo 层面根本拿不到 arboard / clipboard-master
    # （它们在 `not(any(android, ios, ohos))` 的依赖段里），所以正确的做法不是
    # 造替身 crate，而是把鸿蒙划到移动侧。
    #
    # 两条规则的顺序有意义：先把 `not(target_os = "android")` 消化掉，
    # 再匹配裸的 `#[cfg(target_os = "android")]`，两者不会互相误伤。
    (
        "src/clipboard.rs",
        r'not\(target_os = "android"\)',
        'not(any(target_os = "android", target_env = "ohos"))',
    ),
    (
        "src/clipboard.rs",
        r'#\[cfg\(target_os = "android"\)\]',
        '#[cfg(any(target_os = "android", target_env = "ohos"))]',
    ),
]


def targets():
    for pattern in ("**/*.rs", "**/Cargo.toml"):
        for p in ROOT.glob(pattern):
            if any(part in SKIP_DIRS for part in p.parts):
                continue
            yield p


def rewrite(text: str) -> tuple[str, int]:
    """返回 (新文本, 改动计数)。POS 必须在 NEG 之后处理。"""
    changes = 0
    text, n = re.subn(re.escape(NEG), NEG_OHOS, text)
    changes += n
    # 只替换尚未包含 ohos 的正向谓词
    def pos_sub(m: re.Match) -> str:
        nonlocal changes
        if 'target_env = "ohos"' in m.group(0):
            return m.group(0)
        changes += 1
        return POS_OHOS

    text = re.sub(re.escape(POS), pos_sub, text)
    return text, changes


def apply_targeted(original: str, rel: str) -> tuple[str, list[int]]:
    """施加定向补丁。返回 (新文本, 命中的补丁序号)。已施加的视为命中。"""
    hits: list[int] = []
    text = original
    for path_pat, pat, repl in FILE_RULES:
        if path_pat == rel:
            text = re.sub(pat, repl, text)
    for idx, (path, needle, repl) in enumerate(PATCHES):
        if path != rel:
            continue
        if repl in text:
            hits.append(idx)
            continue
        if needle in text:
            text = text.replace(needle, repl, 1)
            hits.append(idx)
    return text, hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    total_files = 0
    total_changes = 0
    pending: list[tuple[pathlib.Path, str]] = []

    for path in targets():
        try:
            original = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        text, patch_hits = apply_targeted(original, path.relative_to(ROOT).as_posix())
        updated, n = rewrite(text)
        n += len(patch_hits)
        if updated != original:
            total_files += 1
            total_changes += n
            pending.append((path, updated))

    # 定向补丁若一个都没命中，说明上游已改动相关代码，需要人工复核。
    # 以「待写入内容」为准（磁盘上还是旧内容）。
    pending_map = {p.relative_to(ROOT).as_posix(): t for p, t in pending}
    missing: list[str] = []
    for rel, _needle, repl in PATCHES:
        body = pending_map.get(rel)
        if body is None:
            try:
                body = (ROOT / rel).read_text(encoding="utf-8")
            except OSError:
                missing.append(rel + " (文件不存在)")
                continue
        if repl not in body:
            missing.append(rel)

    if args.check:
        if total_changes:
            print(f"[FAIL] {total_changes} 处未施加（{total_files} 个文件）")
            return 1
        print("[OK] 所有补丁已施加")
        return 0

    print(f"{'[dry-run] ' if args.dry_run else ''}{total_files} 个文件 / {total_changes} 处改动")
    if args.dry_run:
        return 0

    for path, updated in pending:
        path.write_text(updated, encoding="utf-8")
    print("已施加。请执行 `cargo check --target aarch64-unknown-linux-ohos` 验证。")
    if missing:
        print(f"[WARN] 以下定向补丁的目标代码已变化，未匹配：{sorted(set(missing))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
