//! 主控会话的启动与关闭。
//!
//! 这一层刻意做得极薄：真正干活的是上游的
//! [`crate::ui_session_interface::io_loop`]（连接、登录、解码、发输入全在里面），
//! 这里只负责「造一个 `Session<OhosUiSession>` 并把它跑起来」。
//!
//! 与 Flutter 版的差异（有意为之）：
//!   - **单会话**。手机上同时连两台机器没有意义，UI 也没有切换入口；
//!     Flutter 那套 `sessions::SESSIONS` 注册表（peer → 多个 UI 会话、
//!     多窗口拖拽）在这里只带来复杂度。需要多会话时再加，不影响协议层。
//!   - **不注册进 `flutter::sessions`**。那个注册表的类型是
//!     `Session<FlutterHandler>`，混进去会污染 flutter 模块。

use super::ui_handler::{self, OhosUiSession};
use crate::ui_session_interface::{io_loop, Session};
use hbb_common::{config, config::LocalConfig, log, rendezvous_proto::ConnType};
use std::sync::{Arc, RwLock};

pub type OhosSession = Arc<Session<OhosUiSession>>;

static SESSION: RwLock<Option<OhosSession>> = RwLock::new(None);

/// 当前活跃会话。
pub fn current() -> Option<OhosSession> {
    SESSION.read().ok().and_then(|g| g.clone())
}

/// 在会话上执行一段操作；无会话时返回 `None`。
pub fn with_session<R>(f: impl FnOnce(&OhosSession) -> R) -> Option<R> {
    current().map(|s| f(&s))
}

/// 「仅查看」是否生效。
///
/// Flutter 端的 view mode 是在 UI 层（input model）拦输入；鸿蒙端输入只有
/// 鼠标 / 键盘 / 文本三条 napi 通道，把闸门放在 Rust 入口一处就能全部盖住，
/// 不依赖 ArkTS 每条手势自己记得检查。
pub fn is_view_only() -> bool {
    with_session(|s| s.lc.read().unwrap().get_toggle_option("view-only")).unwrap_or(false)
}

/// 「连接默认选项」里的**开关型**选项。
///
/// 设置页把它们写在全局 Config（RustDesk2.toml），每次连接时灌进该 peer 的
/// LoginConfigHandler。上游没有这个概念 —— 桌面/Flutter 版这些选项本来就存在
/// per-peer 的 PeerConfig 里，由每台 peer 自己的设置页改；鸿蒙版没有 per-peer
/// 设置 UI，用全局默认值兜底是当前最合理的近似。
///
/// **键名必须是连字符**：读取方是 `LoginConfigHandler::get_toggle_option`
/// （src/client.rs:3498），它按字面量逐个 if 判断 `show-remote-cursor` /
/// `disable-audio`。写成下划线（`show_remote_cursor`）会写进 PeerConfig 的
/// options map 却永远没人来读 —— 现场表现是「设置里明明改了，连接没变化」，
/// 而配置文件里又确实存着值，极难排查。
///
/// 三元组：`(全局 Config 键, 会话开关名, 全局值为空串时按什么算)`。
///
/// 为什么第三列不是常数：本应用把三项的「关」写成了**空串**而不是 `"N"`
/// （见 `RustDesk.ets::saveConfig` 的 `? 'Y' : ''`），其余项写 `"Y"/"N"`。
/// 空串的语义只有各写各的那一侧知道，所以只能在表里逐项钉死，不能统一处理。
/// 取值原则是**与设置页看到的一致**（`RustDesk.optionGetBool` 视空串为开），
/// 否则会出现「界面显示开、实际按关连上」这种查不出原因的怪现象。
pub const SESSION_TOGGLES: [(&str, &str, bool); 9] = [
    // 写 "Y"/空串 的三项：空 = 关。
    ("show-remote-cursor", "show-remote-cursor", false),
    ("disable-audio", "disable-audio", false),
    // 其余写 "Y"/"N"：空串代表「从没设过」，按设置页的显示（开）走。
    ("follow_remote_cursor", "follow-remote-cursor", true),
    ("follow_remote_window", "follow-remote-window", true),
    ("show_quality_monitor", "show-quality-monitor", true),
    ("disable_clipboard", "disable-clipboard", true),
    ("view_only", "view-only", true),
    ("lock_after_session_end", "lock-after-session-end", true),
    ("privacy_mode", "privacy-mode", true),
];

/// 视图样式与图像质量在 PeerConfig 上是**命名字段**（`view_style` /
/// `image_quality`），不是 options map 里的键，所以不能走 `set_option`：
/// 塞进 map 同样没人读。这两项要走 `save_view_style` / `save_image_quality`。
///
/// 于是我们只在**全局 Config** 里存一份「下次连接用什么默认值」，键名带
/// `ohos-default-` 前缀 —— 这样一眼能看出它是鸿蒙 UI 自己约定的键，
/// 而不是上游 client.rs 会去读的 option，避免又被误当成 option 键。
///
/// 值域与上游一致：视图样式 `original` / `adaptive`；
/// 图像质量 `best` / `balanced` / `low`（`custom` 需要额外给
/// `custom_image_quality`，鸿蒙版暂不开放）。
pub const KEY_DEFAULT_VIEW_STYLE: &str = "ohos-default-view-style";
pub const KEY_DEFAULT_IMAGE_QUALITY: &str = "ohos-default-image-quality";

/// 建立主控会话。
///
/// 参数语义与 Flutter 的 `session_add` 一致：
///   - `peer_id` 可以带 `@server` 后缀（`123456789@192.168.1.2`），
///     也可以带 `?key=...&relay=...` 之类的参数，由 `LoginConfigHandler::initialize` 解析；
///   - `password` 是预设密码，为空表示等对端提示时再向用户索要；
///   - `force_relay` 强制走中继（跨 NAT 失败时的兜底）。
///
/// 返回后连接在后台线程上进行，结果通过 `ui_handler` 的 JSON 事件上报。
pub fn start(peer_id: &str, password: &str, force_relay: bool) -> hbb_common::ResultType<()> {
    if peer_id.trim().is_empty() {
        hbb_common::bail!("empty peer id");
    }
    close();

    LocalConfig::set_remote_id(peer_id);

    // 不需要 `mut`：`lc` 是 `Arc<RwLock<..>>`，内部可变性已经够了。
    let session: Session<OhosUiSession> = Session {
        password: password.to_owned(),
        ..Default::default()
    };
    session.lc.write().unwrap().initialize(
        peer_id.to_owned(),
        ConnType::DEFAULT_CONN,
        None,
        force_relay,
        None,
        None,
        None,
    );
    // 把设置页的「连接默认选项」灌进本会话。
    //
    // 分两条路，**不能混**：
    //   • 开关型（privacy_mode / lock_after_session_end / show-remote-cursor …）
    //     是 PeerConfig 的**命名字段**，必须走 `set_session_toggle` 直接写字段；
    //     用 `set_option` 只会塞进 options map，而读取方 `get_toggle_option`
    //     读字段 —— 写了也没人读，正是「隐私模式 / 会话结束后锁定 开关没反应」
    //     的根因（这两项连上游的 UserDefaultConfig 兜底都没有，因为设置页只写了
    //     全局 Config，而 serde 默认值读的是另一份 `RustDesk2_default.toml`）。
    //   • `force-always-relay` 是例外：它由 `client.rs:3007` 用
    //     `get_option("force-always-relay")` 从 options map 读，所以走 `set_option`。
    let mut applied: Vec<String> = Vec::new();
    for (global_key, toggle, empty_on) in SESSION_TOGGLES {
        let v = config::Config::get_option(global_key);
        let on = if v.is_empty() { empty_on } else { v != "N" };
        session.lc.write().unwrap().set_session_toggle(toggle, on);
        applied.push(format!("{}={}", toggle, if on { "Y" } else { "N" }));
    }
    // 空串一律归一化成 "N"：不这么写，用户把「强制中继」关掉后配置里是空串，
    // 上一次会话留在 peer 配置里的 "Y" 就会一直生效，成了关不掉的开关。
    let relay = config::Config::get_option("force-always-relay");
    let relay = if relay == "Y" { "Y" } else { "N" };
    session
        .lc
        .write()
        .unwrap()
        .set_option("force-always-relay".to_owned(), relay.to_owned());
    applied.push(format!("force-always-relay={}", relay));
    // 真彩 4:4:4 / 编解码偏好是 options map 键，读取方是
    // scrap::codec::Decoder::preference(peer_id)：它按**本 peer 的** PeerConfig
    // （peers/<id>.toml）读 options，读全局默认没用。空值归一化：i444 必须
    // 显式写 Y/N（空串会被 preference 当成关），codec-preference 缺省 auto。
    for (key, empty_value) in [("i444", "N"), ("codec-preference", "auto")] {
        let v = config::Config::get_option(key);
        let v = if v.is_empty() { empty_value } else { v.as_str() };
        session
            .lc
            .write()
            .unwrap()
            .set_option(key.to_owned(), v.to_owned());
        applied.push(format!("{}={}", key, v));
    }
    // 一行日志把本次会话实际生效的开关全列出来。排查「设置里改了没反应」
    // 时第一眼看的就是它：配置里的值和这里不一致，说明问题在写入侧；
    // 一致但行为没变，才去查协议/对端。
    log::info!("ohos: session toggles {}", applied.join(" "));

    // 视图样式与图像质量走命名字段：必须用 save_view_style / save_image_quality
    // 写 PeerConfig 的 `view_style` / `image_quality`，否则值留在 options map
    // 里没人读（历史上这里错用了 set_option，导致这两项设置完全不生效）。
    let view_style = config::Config::get_option(KEY_DEFAULT_VIEW_STYLE);
    if !view_style.is_empty() {
        session.lc.write().unwrap().save_view_style(view_style);
    }
    let image_quality = config::Config::get_option(KEY_DEFAULT_IMAGE_QUALITY);
    if !image_quality.is_empty() {
        // 返回的 Message 是「立刻通知对端改画质」，仅会话中途改才需要；
        // 这里是建连前落盘，下一帧自然会带上，忽略返回值即可。
        session.lc.write().unwrap().save_image_quality(image_quality);
    }
    let session = Arc::new(session);
    // 声明「现在是我这个会话」，之后旧会话的残留事件（close 等）会被丢掉。
    ui_handler::CURRENT_SID.store(session.ui_handler.sid, std::sync::atomic::Ordering::SeqCst);
    *SESSION.write().unwrap() = Some(session.clone());

    log::info!("ohos: session start, peer {}", peer_id);
    let running = session.clone();
    std::thread::spawn(move || {
        let round = session.connection_round_state.lock().unwrap().new_round();
        // `io_loop` 带 `#[tokio::main(flavor = "current_thread")]`，是个**同步**函数，
        // 内部自己建 runtime 并阻塞到会话结束（与 flutter.rs:1429 的用法一致）。
        // 所以这里不能再套 runtime，否则会 panic: Cannot start a runtime from within a runtime。
        io_loop((*session).clone(), round);
        log::info!("ohos: session loop exited");
        // io_loop 返回 = 会话真的结束了（对端关连接、网络断、用户断开…）。
        // 只有这时才该告诉 UI「已断开」；首帧到达时的 close_success 不是断线。
        let is_current = SESSION
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(|s| s.ui_handler.sid))
            == Some(running.ui_handler.sid);
        if is_current {
            *SESSION.write().unwrap() = None;
            ui_handler::CURRENT_SID.store(0, std::sync::atomic::Ordering::SeqCst);
            ui_handler::emit("close", serde_json::json!({ "reason": "disconnected" }));
        }
    });
    Ok(())
}

/// 关闭当前会话。可重复调用。
pub fn close() {
    let s = SESSION.write().unwrap().take();
    // 先撤销「当前会话」标记：io_loop 退出时会回调 close_success，
    // 那是我们自己关的，不该再当成断线事件推给 UI（页面可能正在退出）。
    ui_handler::CURRENT_SID.store(0, std::sync::atomic::Ordering::SeqCst);
    if let Some(s) = s {
        log::info!("ohos: session close");
        s.close();
        // 与移动端一致：把本地按下的修饰键状态清掉，避免对端「粘键」。
        crate::keyboard::release_remote_keys("map");
    }
}

/// 主动请求关键帧（例如从后台回到前台、旋转屏幕后画面残缺）。
pub fn refresh(display: i32) {
    with_session(|s| s.refresh_video(display));
}

/// 回应「未加密连接」警告。
///
/// 上游在建链后若拿不到对端的 E2EE 公钥，会 `msgbox("insecure-connection-…")`
/// 并**阻塞在 `confirm_insecure_connection` 里等这一句回话** —— 不回就是永久卡住，
/// 表现为「连上了但一直黑屏、也没有密码框」。所以这个 ABI 不是可选项。
///
/// `accept == false` 时上游会把连接拆掉（等价于用户取消）。
pub fn continue_insecure(accept: bool) {
    with_session(|s| s.continue_insecure_connection(accept));
}

/// 提交登录凭据。密码弹窗的「确定」走这里。
///
/// `os_username` / `os_password` 只在对端停在 OS 登录界面时才用得上
/// （`auto-login` 场景），鸿蒙版当前不提供那个输入框，保持空串。
pub fn login(os_username: &str, os_password: &str, password: &str, remember: bool) {
    with_session(|s| {
        s.login(
            os_username.to_owned(),
            os_password.to_owned(),
            password.to_owned(),
            remember,
        );
    });
}
