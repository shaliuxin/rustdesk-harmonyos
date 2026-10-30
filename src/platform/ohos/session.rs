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

use super::ui_handler::OhosUiSession;
use crate::ui_session_interface::{io_loop, Session};
use hbb_common::{config::LocalConfig, log, rendezvous_proto::ConnType};
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

    let mut session: Session<OhosUiSession> = Session {
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
    let session = Arc::new(session);
    *SESSION.write().unwrap() = Some(session.clone());

    log::info!("ohos: session start, peer {}", peer_id);
    std::thread::spawn(move || {
        let round = session.connection_round_state.lock().unwrap().new_round();
        // `io_loop` 带 `#[tokio::main(flavor = "current_thread")]`，是个**同步**函数，
        // 内部自己建 runtime 并阻塞到会话结束（与 flutter.rs:1429 的用法一致）。
        // 所以这里不能再套 runtime，否则会 panic: Cannot start a runtime from within a runtime。
        io_loop((*session).clone(), round);
        log::info!("ohos: session loop exited");
    });
    Ok(())
}

/// 关闭当前会话。可重复调用。
pub fn close() {
    let s = SESSION.write().unwrap().take();
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
