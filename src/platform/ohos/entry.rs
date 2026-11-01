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
use hbb_common::{
    config,
    config::RENDEZVOUS_PORT,
    log,
};
use serde_json::json;
use std::net::{TcpStream, ToSocketAddrs};
use std::os::raw::{c_char, c_int, c_uint};
use std::sync::atomic::{AtomicI32, Ordering};
use std::thread;
use std::time::Duration;

/// ABI 版本。ArkTS 侧启动时校验，避免 C++ 与 .a 版本错配导致的诡异崩溃。
pub const ABI_VERSION: c_uint = 1;

const ERR_INVALID_ARG: c_int = -1;
const ERR_NO_SESSION: c_int = -2;
const ERR_START_FAILED: c_int = -3;

/// 把 `log` crate 的输出转发到 hilog。
///
/// 为什么不用 `hbb_common::init_log`（flexi_logger 文件日志）：
/// `hdc` 对应用沙箱目录没有读权限（连 `cat` RustDesk2.toml 都被拒），
/// 文件写了也取不出来；而 hilog 用 `hilog | grep` 就能看，
/// 是鸿蒙上唯一可用的日志通道。第三方库（reqwest/hyper/rustls/webrtc）
/// 在桌面端有 flexi_logger 的过滤，这里照抄一份，避免刷屏把关键行顶掉。
struct HilogLogger;

const HILOG_FILTER: &str = "reqwest=warn,hyper_util=warn,hyper=warn,rustls=warn,webrtc=warn,webrtc_ice=warn,webrtc_sctp=warn,webrtc_transport=warn";

impl log::Log for HilogLogger {
    fn enabled(&self, meta: &log::Metadata) -> bool {
        // 与 init_log 的桌面端过滤一致：目标库只放 warn 以上，其余 info 以上。
        let mut target_level = log::LevelFilter::Info;
        for rule in HILOG_FILTER.split(',') {
            let mut parts = rule.splitn(2, '=');
            let target = match parts.next() {
                Some(t) => t,
                None => continue,
            };
            let lvl = match parts.next().and_then(|l| l.parse::<log::LevelFilter>().ok()) {
                Some(l) => l,
                None => continue,
            };
            if meta.target().starts_with(target) {
                target_level = lvl;
            }
        }
        meta.level() <= target_level
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let level = match record.level() {
            log::Level::Error => 3,
            log::Level::Warn => 2,
            log::Level::Info => 1,
            _ => 0,
        };
        // target 缩短：`rustdesk::client::io_loop` → `client::io_loop`，省 hilog 行宽。
        let target = record.target().split("::").skip(1).collect::<Vec<_>>().join("::");
        ffi::log(level, &format!("[{}] {}", target, record.args()));
    }

    fn flush(&self) {}
}

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

/// 核心版本号（"1.5.1"）。「关于」页显示用，调用方负责 free。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_version() -> *mut c_char {
    into_c_string(crate::version::VERSION.to_owned())
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
    // 日志：hilog 转发（见 HilogLogger 的注释，文件日志在鸿蒙上取不出来）。
    // set_boxed_logger 全进程只能调一次；init 由 ArkTS 保证只进一次，
    // 但防御一下重复初始化的场景。
    let _ = log::set_boxed_logger(Box::new(HilogLogger));
    log::set_max_level(log::LevelFilter::Debug);

    // 出厂默认设置：首次运行时把设置页那一套值写进配置（只此一次）。
    // 必须赶在 UI 首次读配置之前，否则设置页会先闪一下上游默认值。
    seed_factory_defaults();

    // 身份：ID 落盘由 `Config::get_id` 保证，这里提前取一次确保**首次就生成
    // 并持久化**（ID 稳定，重连时对端不用改地址）。一次性密码则相反——只在
    // 进程内存里，退出即换；同时清掉老版本留下的密码存档。
    log::info!("ohos: device id = {}", config::Config::get_id());
    remove_legacy_temp_password_file();

    // ID 服务器状态看门狗：进程内唯一一条后台线程，UI 只管读结果。
    // 尽早起，设置页首次出现时状态就已经有意义了。
    start_server_status_watchdog();

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
// 连接配置（自建服务器）
// ---------------------------------------------------------------------------

/// 与「连哪台服务器」相关的配置项。
///
/// 键名必须和上游设置页的字符串**逐字一致**：`Config::get_option` /
/// `Config::set_option` 就是按这些字面量读写的，写成别的名字只会写进
/// config 文件却永远没人读，排查起来极其费时。
///
/// * `custom-rendezvous-server` —— ID（Rendezvous）服务器，`host` 或 `host:port`
/// * `relay-server`             —— 中继服务器；留空表示用 ID 服务器下发的地址
/// * `api-server`               —— API 服务器；留空表示 `http://<ID服务器>:21114`
/// * `key`                      —— 自建服务器的公钥，即 `id_ed25519.pub` 的内容
///
/// 后面五项是「连接默认选项」：上游把它们存在**每个 peer** 的 PeerConfig 里，
/// 鸿蒙版没有 per-peer 设置 UI，就在 `session::start` 时把这些全局值
/// 灌进本次会话的 `LoginConfigHandler`（见 session.rs 的 VIEW_OPTION_KEYS）。
const REMOTE_SERVER_KEYS: [&str; 4] = [
    "custom-rendezvous-server",
    "relay-server",
    "api-server",
    "key",
];

/// 连接时的**开关型**默认选项，以及视图样式 / 图像质量全局默认值的存放键。
///
/// 定义在 session.rs（单一来源），这里只是取过来用 —— 配置入口的白名单与
/// 会话启动时的读取方必须是同一份，分开写两份迟早会漂移：
/// 曾经就因为两处键名不一致，导致「设置里改了但连接没变化」且极难定位。
use super::session::{KEY_DEFAULT_IMAGE_QUALITY, KEY_DEFAULT_VIEW_STYLE, SESSION_TOGGLES};

/// 网络 / 打洞相关，对应 Android 设置页里那几项（Disable UDP、TCP/UDP/IPv6
/// hole punching、WebRTC、WebSocket）。
///
/// 取值是 "Y" / "N"，**空串表示按默认**：连公共服务器时默认开，连自建服务器时
/// 默认关（见 common.rs 的 get_local_option）。所以 UI 上不能简单把空串当 false，
/// 只有明确读到 "N" 才是关。
/// 网络 / 打洞相关。取值 "Y" / "N"。
///
/// **只有 `disable-udp` / `allow-websocket` / `allow-insecure-tls-fallback`
/// 走全局 Config**：`config.rs` 的 `use_ws()` 与 `allow_insecure_tls_fallback()`
/// 就是用 `Config::get_option` 读的（2938 / 2943 行）。
///
/// 剩下四个 punch 开关在 `common.rs:1313` 起是走 `get_local_option` →
/// **LocalConfig** 的，所以它们必须走 [`rustdesk_ohos_local_option_set`]，
/// 写进 Config 等于没人读（曾经就是这么错的）。
const NETWORK_OPTION_KEYS: [&str; 3] = [
    "disable-udp",
    "allow-websocket",
    "allow-insecure-tls-fallback",
];

/// **本地**配置项（LocalConfig）的白名单。
///
/// 与全局 Config 的分工见 `libs/base/src/config/keys.rs` 的
/// `KEYS_LOCAL_SETTINGS / KEYS_SETTINGS` 两个列表 —— 那边怎么分组，这边就怎么
/// 走；放错存储位置的结果是「设置里改了，行为没变」，而且配置里确实存着值，
/// 很难看出来。
const LOCAL_OPTION_KEYS: [&str; 7] = [
    "enable-tcp-punch",
    "enable-udp-punch",
    "enable-ipv6-punch",
    "enable-webrtc",
    "allow-auto-record-outgoing",
    "keep-awake-during-outgoing-sessions",
    "enable-check-update",
];

/// 设置页其余设置项的 option 键白名单。
///
/// 键名**逐字取自 Flutter 的 consts.dart**，因为读写双方都是 hbb_common 的
/// `Config::get_option / set_option`：Flutter 用什么键存，这边就用什么键读，
/// 一旦对不上就是「设置里改了没效果」。改动前请先 grep consts.dart 核对。
///
/// 分组顺序与 Android `settings_page.dart` 一致，方便两边对照着改。
const UI_OPTION_KEYS: [&str; 21] = [
    // --- 显示（Display Settings / Other Default Options）---
    "codec-preference",        // auto / vp8 / vp9 / av1 / h264 / h265
    "show_remote_cursor",
    "follow_remote_cursor",
    "follow_remote_window",
    "show_quality_monitor",
    "disable_clipboard",
    "lock_after_session_end",
    "privacy_mode",
    "i444",                    // 真彩 4:4:4
    "reverse_mouse_wheel",
    "swap-left-right-mouse",
    "view_only",               // 仅查看（禁输入）
    // --- 硬件编解码 ---
    "enable-hwcodec",
    // --- 录制 ---
    "allow-auto-record-incoming",
    "allow-auto-record-outgoing",
    "video-save-directory",
    // --- 共享屏幕（本端作为被控端时的策略）---
    "enable-lan-discovery",  // 存的是「允许」；UI 上按上游叫「拒绝局域网发现」（取反）
    "enable-abr",
    "enable-record-session",
    "whitelist",             // IP 白名单，多行文本，一行一条
    "id-whitelist",          // ID 白名单，同上
];

/// 一个 **本地** option 键是否允许从 UI 侧读写。
fn is_local_option_key(k: &str) -> bool {
    LOCAL_OPTION_KEYS.contains(&k)
}

/// 一个 option 键是否允许从 UI 侧读写。
///
/// 白名单不是洁癖：`Config::set_option` 能改任意 Config 项，全放开等于给 UI
/// 一把万能钥匙（误写 `stop-service` 或认证相关项都拦不住）。UI 需要哪些就
/// 只开哪些，新增设置项时在这里同步登记。
fn is_ui_option_key(k: &str) -> bool {
    REMOTE_SERVER_KEYS.contains(&k)
        // 开关型默认项（全局键名，见 session.rs 的 SESSION_TOGGLES）+
        // `force-always-relay`（唯一走 options map 的那个）。
        || k == "force-always-relay"
        || SESSION_TOGGLES.iter().any(|(global_key, _, _)| *global_key == k)
        || NETWORK_OPTION_KEYS.contains(&k)
        || UI_OPTION_KEYS.contains(&k)
        || k == KEY_DEFAULT_VIEW_STYLE
        || k == KEY_DEFAULT_IMAGE_QUALITY
}

// ---------------------------------------------------------------------------
// 出厂默认设置
// ---------------------------------------------------------------------------

/// 出厂默认的**全局** Config 项。
///
/// 取值 = 2026-11-01 设备上实际生效的那一套（逐项从设置页读出）。启动时
/// **首次运行**写进 `RustDesk2.toml`，之后卸载重装 / 清数据都会回到这套，
/// 不用再手点一遍。
///
/// 刻意**不**放进表的几类，理由各不相同：
///   • `custom-rendezvous-server` / `relay-server` / `api-server` / `key`
///     和代理：属于「这台机器处在哪个网络」的环境信息，每台都不一样；
///     写死会把用户自己填的服务器覆盖掉（用户明确要求排除服务器设置）。
///   • `show-remote-cursor` / `disable-audio` / `force-always-relay`：这三项
///     的「关」在配置里就是**空串**（见 `RustDesk.ets::saveConfig` 的
///     `? 'Y' : ''`），而空串等于删键，写与不写完全等价，列进来只会误导。
///   • 当前就是空的文本项（`whitelist` / `id-whitelist` /
///     `video-save-directory` / `ohos-default-image-quality`）：同理，
///     「空」就是它们现在的状态。
const FACTORY_DEFAULTS: [(&str, &str); 20] = [
    // 显示 / 其他默认选项
    ("codec-preference", "auto"),
    ("ohos-default-view-style", "adaptive"), // 默认视图样式：自适应窗口
    ("follow_remote_cursor", "N"),
    ("follow_remote_window", "N"),
    ("show_quality_monitor", "N"),
    ("view_only", "N"),
    ("i444", "N"),
    ("reverse_mouse_wheel", "N"),
    ("swap-left-right-mouse", "N"),
    ("disable_clipboard", "N"),
    ("lock_after_session_end", "N"),
    ("privacy_mode", "N"),
    // 硬件编解码
    ("enable-hwcodec", "Y"),
    // 录制
    ("allow-auto-record-incoming", "N"),
    // 网络
    ("allow-websocket", "N"),
    ("allow-insecure-tls-fallback", "N"),
    ("disable-udp", "N"),
    // 共享屏幕
    ("enable-lan-discovery", "Y"),
    ("enable-abr", "Y"),
    ("enable-record-session", "N"),
];

/// 出厂默认的**本地** LocalConfig 项（不漫游，故与上面分开写）。
/// 键必须走 `LocalConfig`：打洞开关的读取方是 `common.rs` 的
/// `get_tcp_punch_enabled()` 一类函数，写进全局 Config 没人读。
const FACTORY_LOCAL_DEFAULTS: [(&str, &str); 7] = [
    ("enable-tcp-punch", "Y"),
    ("enable-udp-punch", "Y"),
    ("enable-ipv6-punch", "Y"),
    ("enable-webrtc", "Y"),
    ("allow-auto-record-outgoing", "N"),
    ("keep-awake-during-outgoing-sessions", "Y"),
    ("enable-check-update", "Y"),
];

/// 播种标记文件，与 `RustDesk2.toml` 同目录。
///
/// 为什么用标记文件而不是「键不存在才写」：上面提到的三个开关「关」就是空串，
/// 用户手动关掉后下次启动会被「键为空 → 播种」重新打开，成了关不掉的开关。
/// 标记文件保证**一辈子只播一次**；清空应用数据会一起删掉，正好等价于「首次运行」。
///
/// 名字里带版本号：以后想换一套出厂值，把 v1 改成 v2 即可让老用户也吃上新值。
const FACTORY_MARKER: &str = "ohos_factory_defaults_v1";

/// 一次性密码的**残留**存档文件名。
///
/// 早期实现曾把一次性密码落盘，以便应用重启后口令不变。这违背了「一次性」
/// 的语义（等于把一次性口令变成长期口令），因此已废弃：现在密码只存在于
/// 进程内存里（`password_security::TEMPORARY_PASSWORD`），进程退出即重新随机。
///
/// 常量保留只为一件事：启动时把老版本写下的残留文件删掉，别把它留在用户
/// 设备上。确认没有老版本在线之后可以连同这段清理一起删。
const TEMP_PASSWORD_FILE_LEGACY: &str = "ohos_temporary_password";

fn remove_legacy_temp_password_file() {
    let path = config::Config::path(TEMP_PASSWORD_FILE_LEGACY);
    if path.exists() {
        match std::fs::remove_file(&path) {
            Ok(_) => log::info!("ohos: removed legacy temporary password file"),
            Err(e) => log::warn!("ohos: remove legacy temp password file failed: {e}"),
        }
    }
}

/// 一次性密码被用掉之后的处理：**立刻换成新的**。
///
/// 语义就是字面意思的「一次性」——一个口令只在一个会话里有效，用掉即作废。
/// 已经建立的会话不受影响（鉴权在连接时完成，会话内不再校验口令）；会话
/// 短暂掉线时的重连由 RustDesk 自己的 session resume 覆盖，且用户若需要
/// 「断线后仍能用老口令连回来」，应当改用固定密码（设置页可配）。
///
/// 由连接鉴权成功处调用（见 `server::connection::validate_password`）。
pub fn note_temporary_password_used() {
    crate::ui_interface::update_temporary_password();
    log::info!("ohos: temporary password rotated after use");
}

/// 把出厂默认值写进配置。**只做一次**，见 [`FACTORY_MARKER`]。
///
/// 逐个 `set_option` 而不是 `set_options`：后者是**整表替换**
/// （`config.options = v`，config.rs:1377），会把用户的服务器四项、
/// 代理、以及其它没列进来的键一起抹掉。
fn seed_factory_defaults() {
    let marker = config::Config::path(FACTORY_MARKER);
    if marker.exists() {
        return;
    }
    for (k, v) in FACTORY_DEFAULTS {
        config::Config::set_option((*k).to_owned(), (*v).to_owned());
    }
    for (k, v) in FACTORY_LOCAL_DEFAULTS {
        config::LocalConfig::set_option((*k).to_owned(), (*v).to_owned());
    }
    if let Err(e) = std::fs::write(&marker, b"1") {
        // 标记落盘失败极少见（目录只读 / 配额满）。此时本轮仍然生效，
        // 只是下次启动会再播一次 —— 值本就一样，重复播种没有副作用。
        log::warn!("ohos: write factory-defaults marker failed: {e}");
    }
    log::info!(
        "ohos: factory defaults seeded, {} config + {} local key(s)",
        FACTORY_DEFAULTS.len(),
        FACTORY_LOCAL_DEFAULTS.len()
    );
}

/// 读取连接配置（JSON）。调用方负责 `rustdesk_ohos_string_free`。
///
/// 除了用户填的四项，额外给出 `effective-rendezvous-server`：它是**实际生效**
/// 的地址（可能来自编译期内置的定制服务器，而不是用户填的值）。UI 上把它显示
/// 出来，能省掉「我明明填了却连不上」的一轮排查。
///
#[no_mangle]
pub extern "C" fn rustdesk_ohos_config_json() -> *mut c_char {
    let mut obj = serde_json::Map::new();
    for k in REMOTE_SERVER_KEYS
        .iter()
        .chain(SESSION_TOGGLES.iter().map(|(global_key, _, _)| global_key))
        .chain(["force-always-relay"].iter())
        .chain(NETWORK_OPTION_KEYS.iter())
        .chain(UI_OPTION_KEYS.iter())
        .chain([KEY_DEFAULT_VIEW_STYLE, KEY_DEFAULT_IMAGE_QUALITY].iter())
    {
        obj.insert(
            (*k).to_owned(),
            serde_json::Value::String(config::Config::get_option(k)),
        );
    }
    obj.insert(
        "effective-rendezvous-server".to_owned(),
        serde_json::Value::String(config::Config::get_rendezvous_server()),
    );
    // 首页「我的 ID」卡片要用。这两个不在 REMOTE_SERVER_KEYS 里（不是用户填的
    // 配置项），但和连接强相关，跟着 config_json 一起给出，省一次跨语言调用。
    obj.insert(
        "id".to_owned(),
        serde_json::Value::String(crate::ui_interface::get_id()),
    );
    obj.insert(
        "temporary-password".to_owned(),
        serde_json::Value::String(crate::ui_interface::temporary_password()),
    );
    into_c_string(serde_json::Value::Object(obj).to_string())
}

// --- ID 服务器连接状态 -----------------------------------------------------
//
// 上游在设置页显示「连接状态」走的是 `ui_interface::get_connect_status()`，
// 而它的值由**守护进程**通过 IPC（`ipc::Data::OnlineStatus`）上报；鸿蒙端没有
// 常驻服务，`RendezvousMediator::start_all()` 从未被调用，直接读
// `config::get_online_state()` 只会永远拿到 0。
//
// 所以这里自己起一条后台线程做**可达性探测**，判据沿用上游
// `test_rendezvous_server()` 的同一套：对 ID 服务器端口（默认 21116）做一次
// 带超时的 TCP 连接。只是握手前一步的连通性检查 —— 不注册、不发协议包，
// 对服务器没有副作用，也不需要任何权限。
//
// 数值沿用上游 `ConnectStatus` 的定义，以后若真把守护进程那条路接上，
// UI 侧不用改。

/// 连接失败（红）。
pub const SERVER_STATUS_FAILED: c_int = -1;
/// 正在连接（黄）。
pub const SERVER_STATUS_CONNECTING: c_int = 0;
/// 已正常连接（绿）。
pub const SERVER_STATUS_READY: c_int = 1;

/// 单次 TCP 探测的超时。比上游 `CONNECT_TIMEOUT` 短，UI 上要跟手。
const PROBE_TIMEOUT: Duration = Duration::from_millis(1500);
/// 探测间隔。看门狗线程内串行执行，不会因为单次超时而叠加。
const PROBE_INTERVAL: Duration = Duration::from_secs(3);

/// 最近一次探测结果。看门狗线程写，UI 线程只读，所以是原子的而非 Mutex。
static SERVER_STATUS: AtomicI32 = AtomicI32::new(SERVER_STATUS_CONNECTING);

/// 对当前生效的 ID 服务器做一次带超时的 TCP 连接，判断可达性。
///
/// `to_socket_addrs()` 顺带把 DNS 解析做了；解析失败同样算不可达 ——
/// 对 UI 来说「域名解析不了」和「连不上」是一回事。
fn probe_rendezvous_server() -> bool {
    let host = crate::check_port(&config::Config::get_rendezvous_server(), RENDEZVOUS_PORT);
    let addrs = match host.to_socket_addrs() {
        Ok(a) => a,
        Err(e) => {
            log::debug!("ohos: resolve {host} failed: {e}");
            return false;
        }
    };
    // 一个域名可能解析出多个地址（v4/v6），任一能连上就算可达。
    for addr in addrs {
        if TcpStream::connect_timeout(&addr, PROBE_TIMEOUT).is_ok() {
            return true;
        }
    }
    false
}

/// 启动 ID 服务器状态看门狗。整个进程只调一次（见 [`rustdesk_ohos_init`]）。
///
/// 放在常驻后台线程而不是「UI 要了才探」的原因：
///   • TCP 探测最坏要等满 1.5s，同步做会卡住 ArkTS 主线程；
///   • 每次刷新临时起线程，网络差时会叠出一堆并发探测。
/// 单线程串行探测两头都不占：UI 只做一次廉价读。
fn start_server_status_watchdog() {
    thread::spawn(move || {
        let mut last: c_int = SERVER_STATUS_CONNECTING;
        loop {
            // 探测前先置「正在连接」，UI 立刻变黄，不会停在过期的绿/红上。
            SERVER_STATUS.store(SERVER_STATUS_CONNECTING, Ordering::SeqCst);
            let ok = probe_rendezvous_server();
            let next: c_int = if ok {
                SERVER_STATUS_READY
            } else {
                SERVER_STATUS_FAILED
            };
            SERVER_STATUS.store(next, Ordering::SeqCst);
            // 只在**状态翻转**时打日志：每轮都打会把 hilog 刷满，
            // 而排错时真正关心的恰恰是「什么时候从绿变红」。
            if next != last {
                log::info!("ohos: id server status -> {}", if ok { "ready" } else { "failed" });
                // 网络从「不可达」恢复：如果远程协助开着，立刻让 rendezvous
                // 重新注册，而不是等它自己的重试超时（最坏 18s）。
                // 重启 mediator 不会关掉已有会话（只有 stop-service=Y 才 close_connections），
                // 所以这一步对正在进行的连接是安全的。
                if ok && last == SERVER_STATUS_FAILED && HOST_RUNNING.load(Ordering::SeqCst) {
                    log::info!("ohos host: network recovered, re-registering now");
                    crate::RendezvousMediator::restart();
                }
                last = next;
            }
            thread::sleep(PROBE_INTERVAL);
        }
    });
}

/// 当前生效 ID 服务器的连接状态。
///
/// 返回 1（已连接）/ 0（正在连接）/ -1（连接失败）；UI 侧据此画绿/黄/红圆点。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_server_status() -> c_int {
    SERVER_STATUS.load(Ordering::SeqCst)
}

/// 手动刷新一次性密码。首页卡片上的「刷新」按钮。
///
/// 除了用户主动点刷新，密码在**被用掉之后**也会自动更换，
/// 见 [`note_temporary_password_used`]。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_update_temporary_password() {
    crate::ui_interface::update_temporary_password();
}

/// 设置固定密码。传空串表示清除（回到只用一次性密码）。
/// 返回 0 成功；-1 表示参数为空指针。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_set_permanent_password(pw: *const c_char) -> c_int {
    let pw = match cstr_arg(pw) {
        Some(v) => v,
        None => return set_error("set_permanent_password: null"),
    };
    if crate::ui_interface::set_permanent_password_with_result(pw) {
        0
    } else {
        set_error("set_permanent_password: rejected (probably disallowed by config)")
    }
}

/// 最近连接过的对端列表（首页「最近会话」用）。
///
/// 形如 `[{"id":"123456789","ts":1730000000,"fav":false}, ...]`，按最后连接时间
/// **倒序**（最近的在前）。`ts` 是 Unix 秒。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_peers_json() -> *mut c_char {
    let favs = crate::ui_interface::get_fav();
    let mut arr: Vec<serde_json::Value> = Vec::new();
    for (id, t, _cfg) in config::PeerConfig::peers(None) {
        let ts = t
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        arr.push(json!({
            "id": id,
            "ts": ts,
            "fav": favs.contains(&id),
        }));
    }
    arr.sort_by(|a, b| {
        let ta = a["ts"].as_u64().unwrap_or(0);
        let tb = b["ts"].as_u64().unwrap_or(0);
        tb.cmp(&ta)
    });
    into_c_string(serde_json::Value::Array(arr).to_string())
}

/// 收藏列表整体写回（传 JSON 字符串数组）。UI 侧增删收藏后把完整列表传回来。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_store_fav(json_ids: *const c_char) -> c_int {
    let raw = match cstr_arg(json_ids) {
        Some(v) => v,
        None => return set_error("store_fav: null"),
    };
    let ids: Vec<String> = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => return set_error(format!("store_fav: bad json: {e}")),
    };
    crate::ui_interface::store_fav(ids);
    0
}

/// 写入连接配置。`json` 是对象，**只认** `REMOTE_SERVER_KEYS` /
/// `VIEW_OPTION_KEYS` / `NETWORK_OPTION_KEYS` 三组白名单里的键。
///
/// 白名单不是洁癖：这个入口能改任意 Config 项，放开等于给 UI 一把万能钥匙
/// （比如误写 `stop-service` 或认证相关项）。UI 只需要四项，就只开四项。
///
/// 值为空串等于「删除该项，回到默认」，与上游设置页清空输入框的语义一致。
/// 返回 0 表示全部处理完（个别键被安装期内置配置锁住时会记 warn，但不算失败）。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_config_set(json: *const c_char) -> c_int {
    let raw = match cstr_arg(json) {
        Some(v) if !v.trim().is_empty() => v,
        _ => return set_error("config_set: json is null or empty"),
    };
    let parsed: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => return set_error(format!("config_set: bad json: {e}")),
    };
    let obj = match parsed.as_object() {
        Some(o) => o,
        None => return set_error("config_set: json is not an object"),
    };

    let mut applied = 0;
    for (k, v) in obj {
        if !is_ui_option_key(k) {
            log::warn!("ohos: config_set ignores non-whitelisted key {}", k);
            continue;
        }
        let val = match v {
            serde_json::Value::String(s) => s.trim().to_owned(),
            // null 与空串同义：都是「清掉这一项」。
            serde_json::Value::Null => String::new(),
            other => other.to_string(),
        };
        // 直接写 Config，而不走 `ui_interface::set_option`：后者在 ohos 分支
        // 的最后一步正是 `Config::set_option`，之前那次 `CheckTestNatType`
        // 是给被控端测 NAT 用的，主控改地址时没必要顺带发一次网络探测。
        config::Config::set_option(k.clone(), val.clone());
        if config::Config::get_option(k) == val {
            applied += 1;
        } else {
            // 被 OVERWRITE_SETTINGS（安装包内嵌的定制项）锁住了，改不动。
            log::warn!(
                "ohos: config '{}' not saved (overridden by installed config)",
                k
            );
        }
    }
    log::info!("ohos: config updated, {}/{} key(s) applied", applied, obj.len());
    0
}

/// 代理设置（JSON），形如 `{"proxy":"","username":"","password":""}`。
///
/// 代理**不**存在 Config 的 options map 里，而是落在 Config2 结构体的
/// `socks` 字段上（libs/hbb_common/src/config.rs:259），读写走
/// `Config::get_socks` / `Config::set_socks`（注意这两个方法挂在 `Config`
/// 而不是 `Config2` 上 —— 直接写 `Config2::get_socks` 会编不过，E0599）。
///
/// 上游把 `proxy-url` / `proxy-username` / `proxy-password` 注释为
/// 「不是真实的键，只用于定制客户端高级设置」，真正的键就是 `Socks5Server`
/// 的 `proxy` / `username` / `password` 三个字段。
///
/// 密码落盘时是加密的，`Config::get_socks()` 已解密，这里交给 UI 的是明文。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_proxy_json() -> *mut c_char {
    let s = config::Config::get_socks().unwrap_or_default();
    into_c_string(
        json!({
            "proxy": s.proxy,
            "username": s.username,
            "password": s.password,
        })
        .to_string(),
    )
}

/// 写入代理设置。三个字段都空 = 不使用代理（内部存 `None`）。
/// 只需传有变化的字段：未提供的字段沿用当前值。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_proxy_set(json: *const c_char) -> c_int {
    let raw = match cstr_arg(json) {
        Some(v) if !v.trim().is_empty() => v,
        _ => return set_error("proxy_set: json is null or empty"),
    };
    let parsed: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(e) => return set_error(format!("proxy_set: bad json: {e}")),
    };
    let obj = match parsed.as_object() {
        Some(o) => o,
        None => return set_error("proxy_set: json is not an object"),
    };

    // UI 每次都把三个字段一起传过来，所以缺哪个键都按空串处理 ——
    // 不做「沿用旧值」的兜底，否则用户把某项清空时会清不掉。
    let pick = |k: &str| -> String {
        obj.get(k)
            .and_then(|v: &serde_json::Value| v.as_str())
            .unwrap_or_default()
            .trim()
            .to_owned()
    };
    let s = config::Socks5Server {
        proxy: pick("proxy"),
        username: pick("username"),
        password: pick("password"),
    };

    // 三项全空表示「不用代理」，与上游 changeSocks5Proxy 清空时的语义一致。
    let socks = if s.proxy.is_empty() && s.username.is_empty() && s.password.is_empty() {
        None
    } else {
        Some(s)
    };
    config::Config::set_socks(socks);
    0
}

/// 读单个 option。键不在白名单里时返回空串（UI 上不该出现这种键）。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_option_get(key: *const c_char) -> *mut c_char {
    let key = match cstr_arg(key) {
        Some(v) if !v.is_empty() => v,
        _ => {
            set_error("option_get: null or empty key");
            return into_c_string(String::new());
        }
    };
    if !is_ui_option_key(key.as_str()) {
        set_error(format!("option_get: key not whitelisted: {key}"));
        return into_c_string(String::new());
    }
    into_c_string(config::Config::get_option(&key))
}

/// 写单个 option。返回 0 成功。值为 null / 空串表示「删除该项，回到默认」。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_option_set(
    key: *const c_char,
    value: *const c_char,
) -> c_int {
    let key = match cstr_arg(key) {
        Some(v) if !v.is_empty() => v,
        _ => return set_error("option_set: null or empty key"),
    };
    if !is_ui_option_key(key.as_str()) {
        return set_error(format!("option_set: key not whitelisted: {key}"));
    }
    let val = cstr_arg(value).unwrap_or_default().trim().to_owned();
    config::Config::set_option(key.clone(), val.clone());
    if config::Config::get_option(&key) != val {
        set_error(format!("option_set: '{}' not saved (overridden)", key))
    } else {
        0
    }
}

/// 读单个**本地**配置项（LocalConfig）。键不在 `LOCAL_OPTION_KEYS` 里返回空串。
///
/// 打洞开关等之所以单独走这条路：它们的读取方是 `common.rs` 的
/// `get_tcp_punch_enabled()` 一类函数，读的是 LocalConfig 而非全局 Config。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_local_option_get(key: *const c_char) -> *mut c_char {
    let key = match cstr_arg(key) {
        Some(v) if !v.is_empty() => v,
        _ => {
            set_error("local_option_get: null or empty key");
        return into_c_string(String::new());
    }
    };
    if !is_local_option_key(key.as_str()) {
        set_error(format!("local_option_get: key not whitelisted: {key}"));
        return into_c_string(String::new());
    }
    into_c_string(config::LocalConfig::get_option(&key))
}

/// 写单个**本地**配置项。返回 0 成功。空串 = 删除该项、回到默认。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_local_option_set(
    key: *const c_char,
    value: *const c_char,
) -> c_int {
    let key = match cstr_arg(key) {
        Some(v) if !v.is_empty() => v,
        _ => return set_error("local_option_set: null or empty key"),
    };
    if !is_local_option_key(key.as_str()) {
        return set_error(format!("local_option_set: key not whitelisted: {key}"));
    }
    let val = cstr_arg(value).unwrap_or_default().trim().to_owned();
    config::LocalConfig::set_option(key.clone(), val);
    0
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

/// 提交登录密码（也用于 OS 登录界面的账号密码，`username`/`os_password` 留空即可）。
///
/// 与上游 `session_login` 的语义一致：密码发到 io_loop 的 `Data::Login`，
/// 由 `handle_login_from_ui` 走标准登录握手。`remember` 非 0 表示把密码
/// 存进该 peer 的 PeerConfig（下次自动登录）。
///
/// 只在会话活着时有效；会话不存在返回 `ERR_NO_SESSION`。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_session_login(
    username: *const c_char,
    os_password: *const c_char,
    password: *const c_char,
    remember: c_int,
) -> c_int {
    let username = cstr_arg(username).unwrap_or_default();
    let os_password = cstr_arg(os_password).unwrap_or_default();
    let password = cstr_arg(password).unwrap_or_default();
    match session::with_session(|s| {
        s.login(username, os_password, password, remember != 0)
    }) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 回应「未加密连接」警告。`accept` 非 0 = 继续，0 = 取消并断开。
///
/// 上游在拿不到对端 E2EE 公钥时会同步等待这个回话（见
/// `client::confirm_insecure_connection`），不回就一直黑屏。
/// 会话不存在返回 `ERR_NO_SESSION`。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_session_continue_insecure(accept: c_int) -> c_int {
    match session::with_session(|_| session::continue_insecure(accept != 0)) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
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
    // 「仅查看」：不向远端发送任何鼠标/触摸输入（含滚轮）。设置页的开关
    // 写进命名字段，由 session::is_view_only 统一读。
    if session::is_view_only() {
        log::info!("ohos: input dropped (view-only), mouse mask={mask}");
        return 0;
    }
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
    if session::is_view_only() {
        return 0;
    }
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

/// 输入一段文字（软键盘用）。
///
/// 走的是 `KeyEvent.seq` 通道：服务端 `input_service::process_seq` 会把它当成
/// 「要打出来的字符串」逐字符注入，**不受本机键位布局影响**，中文/符号都能用。
/// 不要试图把文字拆成一个个 `rustdesk_ohos_key` 去发 —— 那条路要求调用方自己
/// 处理 Shift、大写、以及非 ASCII 的映射，服务端还会因为 key_up 顺序把字符吞掉。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_text(text: *const c_char) -> c_int {
    let text = match cstr_arg(text) {
        Some(v) => v,
        None => return set_error("text: text is null"),
    };
    if text.is_empty() {
        return 0;
    }
    if session::is_view_only() {
        return 0;
    }
    match session::with_session(|s| s.input_string(&text)) {
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

// ---------------------------------------------------------------------------
// 会话操作（Android 底栏 ⋮「更多」菜单，见 remote_page.dart:821 showActions）
// ---------------------------------------------------------------------------
//
// 这一组全是「发一条消息给 io_loop」，不等待结果，返回 0 只代表消息已入队。
// 远端到底做没做，要看后续的状态回调。菜单里那些「能不能点」的判断
// （比如 only Linux/Windows 才能重启）放在 ArkTS 侧按 peer_platform 判，
// 与 Android 的 toolbarControls 一致 —— 平台判断属于 UI 策略，不该下沉。

/// 锁定远端屏幕（Windows 的 Win+L，Linux 的锁屏键序列）。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_lock_screen() -> c_int {
    match session::with_session(|s| s.lock_screen()) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 重启远端设备。只有 Windows / Linux / macOS 的对端支持，调用方先自行判断。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_restart_remote() -> c_int {
    match session::with_session(|s| s.restart_remote_device()) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 把密码发到远端的 OS 登录界面（UAC / 锁屏登录框）。
///
/// `activate` 非 0 表示发完立刻回车，对应 Android 的
/// `handleOsPasswordAction`；只填不提交时用 0。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_input_os_password(pw: *const c_char, activate: c_int) -> c_int {
    let pw = cstr_arg(pw).unwrap_or_default();
    match session::with_session(|s| s.input_os_password(pw, activate != 0)) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 直接请求提权（对端已经是管理员会话时用）。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_elevate_direct() -> c_int {
    match session::with_session(|s| s.elevate_direct()) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 带账号密码请求提权（对端弹出 UAC 要凭据时用）。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_elevate_with_logon(
    username: *const c_char,
    password: *const c_char,
) -> c_int {
    let username = cstr_arg(username).unwrap_or_default();
    let password = cstr_arg(password).unwrap_or_default();
    match session::with_session(|s| s.elevate_with_logon(username, password)) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 会话录屏开关。`start` 非 0 开始，0 停止。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_record_screen(start: c_int) -> c_int {
    match session::with_session(|s| s.record_screen(start != 0)) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 当前是否在录屏。会话不存在返回 0（ArkTS 侧当作「没在录」）。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_is_recording() -> c_int {
    session::with_session(|s| if s.is_recording() { 1 } else { 0 }).unwrap_or(0)
}

/// 翻转一个会话级开关（"block-input"、"show-remote-cursor"…）。
///
/// 名字必须和上游 `toggle_option` 认的字面量一致，否则对端不认。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_toggle_option(name: *const c_char) -> c_int {
    let name = match cstr_arg(name) {
        Some(v) => v,
        None => return set_error("toggle_option: name is null"),
    };
    match session::with_session(|s| s.toggle_option(name)) {
        Some(()) => 0,
        None => ERR_NO_SESSION,
    }
}

/// 对端平台（"Windows" / "Linux" / "MacOS" / "Android"）。会话不存在返回空串。
///
/// 菜单项的可用性判断靠它：Android 被控端才有「返回/Home/多任务/音量/电源」，
/// Windows 才有「锁定用户输入」，Windows/Linux/macOS 才能「重启」。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_peer_platform() -> *mut c_char {
    into_c_string(session::with_session(|s| s.peer_platform()).unwrap_or_default())
}

/// 按 USB HID usage 发一个键（Android 被控端的音量键 / 电源键）。
///
/// 走的是 `handle_flutter_key_event` 的 `character == "flutter_key"` 分支，
/// 服务端按 `ControlKey` 处理，只认这四个 usage（见
/// `_handle_key_flutter_simulation`）：
///   0x007f 静音 / 0x0080 音量+ / 0x0081 音量- / 0x0066 电源
/// 别的 usage 会被静默丢弃，所以调用方只能传这四个。
///
/// 必须成对调用：down=1 之后再 down=0，否则对端会一直「按住」这个键。
/// 单次调用之间没有延时，需要长按（比如电源键的关机菜单）时由调用方自己 sleep。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_hid_key(usb_hid: c_int, down: c_int) -> c_int {
    // session_id 在这一条分支上完全用不到（只有非 flutter_key 分支才拿它
    // 记日志），传 nil 即可；鸿蒙侧只有一个会话，不存在要区分的场景。
    match session::with_session(|s| {
        s.handle_flutter_key_event(
            uuid::Uuid::nil(),
            "flutter_key",
            "flutter_key",
            usb_hid,
            0,
            down != 0,
        )
    }) {
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
    // 采样日志：帧链路排障用。首 3 帧与之后每 150 帧打一条。
    {
        use std::sync::atomic::{AtomicU64, Ordering};
        static PF_COUNT: AtomicU64 = AtomicU64::new(0);
        let n = PF_COUNT.fetch_add(1, Ordering::Relaxed);
        if n < 3 || n % 150 == 0 {
            log::info!("ohos: capture frame #{} {}x{} len {}", n, width, height, len);
        }
    }
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

// ---------------------------------------------------------------------------
// 被控端：远程协助（按需启动，不做常驻服务）
// ---------------------------------------------------------------------------
//
// 设计取舍：HarmonyOS 不允许普通应用安装常驻服务，所以「被控」只以**临时
// 远程协助**的形态存在 —— 用户在「共享屏幕」页手动打开开关，应用内起服务、
// 向 ID 服务器注册、开始采集；关掉开关就全部拆掉。
//
// 这也符合平台合规：屏幕上出现的是应用自己的窗口 + 系统采集提示，
// 不存在「后台悄悄被控」的可能。

static HOST_RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// 服务线程是否活着。`start_server` 返回（panic、runtime 结束）时置 false，
/// 由守护线程负责重新拉起 —— 这是「断线自动重连」的服务侧兜底。
static SERVER_ALIVE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// 守护线程只起一条。
static HOST_SUPERVISOR_STARTED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// 起服务线程（采集已经在跑，这里只负责注册 + 监听）。
///
/// 用 `swap(true)` 做互斥：守护线程和用户点开关可能同时想拉起服务，
/// 谁先抢到谁执行，另一个直接返回，不会出现两个 `start_server` 抢监听端口。
fn spawn_server_thread() {
    if SERVER_ALIVE.swap(true, Ordering::SeqCst) {
        return;
    }
    let spawned = thread::Builder::new()
        .name("ohos-host".into())
        .spawn(|| {
            // start_server 自带 #[tokio::main]，会在这个线程里建 runtime 并常驻。
            crate::server::start_server(true);
            SERVER_ALIVE.store(false, Ordering::SeqCst);
            log::warn!("ohos host: server thread exited");
        });
    if spawned.is_err() {
        SERVER_ALIVE.store(false, Ordering::SeqCst);
        log::error!("ohos host: spawn server thread failed");
    }
}

/// 宿主守护线程：断线/异常退出的自动恢复。
///
/// 覆盖三种「看起来是网络问题、其实是进程内掉了东西」的情况：
///   1. 服务线程退出（panic / runtime 被回收）→ 重新 `start_server`，
///      采集还在就不重起采集（避免重复弹系统授权）；
///   2. 系统单方面停掉采集（用户撤销录屏、切后台被回收）→ 重起采集；
///   3. 网络恢复 → 由状态看门狗触发 mediator 立即重新注册（见那边注释）。
///
/// 退避从 2s 起翻倍、封顶 30s，避免服务起不来时打爆日志和 CPU。
fn start_host_supervisor() {
    if HOST_SUPERVISOR_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let spawned = thread::Builder::new()
        .name("ohos-host-supervisor".into())
        .spawn(|| {
            let mut backoff = 2u64;
            loop {
                thread::sleep(Duration::from_secs(2));
                if !HOST_RUNNING.load(Ordering::SeqCst) {
                    backoff = 2; // 用户主动关了，重新计数
                    continue;
                }
                if SERVER_ALIVE.load(Ordering::SeqCst) {
                    backoff = 2;
                    continue;
                }
                log::warn!("ohos host: server is down, retry in {backoff}s");
                thread::sleep(Duration::from_secs(backoff));
                backoff = (backoff * 2).min(30);
                if !HOST_RUNNING.load(Ordering::SeqCst)
                    || SERVER_ALIVE.load(Ordering::SeqCst)
                {
                    continue;
                }
                if ffi::ohos_capture_is_running() != 1 {
                    let rc = ffi::ohos_capture_start(0);
                    log::warn!("ohos host: capture restart rc={rc}");
                    if rc != 0 {
                        // 采集起不来（多半是用户没重新授权）就别硬起服务，
                        // 否则又是「能连上但没画面」的半残状态。
                        continue;
                    }
                    crate::RendezvousMediator::restart();
                }
                spawn_server_thread();
            }
        });
    if spawned.is_err() {
        HOST_SUPERVISOR_STARTED.store(false, Ordering::SeqCst);
        log::error!("ohos host: spawn supervisor failed");
    }
}

/// 查询本机是否具备被控能力（2in1 形态 + 系统有采集接口）。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_host_supported() -> c_int {
    if ffi::ohos_capture_can_start() == 1 {
        1
    } else {
        0
    }
}

/// 注入授权状态：0 未授权 / 1 授权中 / 2 已授权。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_injection_status() -> c_int {
    ffi::ohos_input_query_authorized()
}

/// 触发系统的「允许远程控制本机」授权弹窗。返回 0 表示已进入授权流程。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_request_injection() -> c_int {
    let rc = ffi::ohos_input_request_authorization();
    if rc != 0 {
        return set_error(&format!("request_injection failed rc={}", rc));
    }
    0
}

/// 启动远程协助：采集 + 注册 + 监听，全部在应用进程内完成。
///
/// 顺序有讲究：**先起采集**（会弹系统授权，用户拒绝就整体失败），
/// 成功后再起 rendezvous，避免出现「已注册但没画面」的半残状态。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_host_start() -> c_int {
    if ffi::ohos_capture_can_start() != 1 {
        return set_error("host: 本机型不支持被控（仅 2in1 可用）");
    }
    if HOST_RUNNING.swap(true, Ordering::SeqCst) {
        log::info!("ohos host: already running");
        return 0;
    }

    let rc = ffi::ohos_capture_start(0);
    if rc != 0 {
        HOST_RUNNING.store(false, Ordering::SeqCst);
        return set_error(&format!(
            "host: 屏幕采集未启动（rc={}），用户可能拒绝了授权",
            rc
        ));
    }

    // stop-service 可能是上次 stop 留下的，启动前显式清零。
    config::Config::set_option("stop-service".to_owned(), "N".to_owned());

    spawn_server_thread();
    if !SERVER_ALIVE.load(Ordering::SeqCst) {
        ffi::ohos_capture_stop();
        HOST_RUNNING.store(false, Ordering::SeqCst);
        return set_error("host: 服务线程启动失败");
    }
    // 守护线程全程只需一条，这里幂等启动：断线、采集被系统回收、服务线程退出
    // 都由它兜底拉起（见 start_host_supervisor）。
    start_host_supervisor();
    log::info!("ohos host: started (capture + rendezvous)");
    0
}

/// 停止远程协助：断开会话、停采集、撤销注入授权。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_host_stop() -> c_int {
    if !HOST_RUNNING.swap(false, Ordering::SeqCst) {
        return 0;
    }
    ffi::ohos_capture_stop();
    // 复用一个上游就有的开关：stop-service=Y 后 restart() 会让 mediator
    // 退出循环并 close_connections()，不需要另开一条停止通道。
    config::Config::set_option("stop-service".to_owned(), "Y".to_owned());
    crate::RendezvousMediator::restart();
    ffi::ohos_input_cancel_injection();
    log::info!("ohos host: stopped");
    0
}

/// 远程协助状态：0 停止 / 1 运行中（等待或正在进行会话）。
#[no_mangle]
pub extern "C" fn rustdesk_ohos_host_state() -> c_int {
    if HOST_RUNNING.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}
