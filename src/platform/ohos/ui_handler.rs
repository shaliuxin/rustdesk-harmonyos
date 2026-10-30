//! `InvokeUiSession` 的鸿蒙实现。
//!
//! 上游把 UI 抽象成 [`InvokeUiSession`]（48 个方法），Flutter / Sciter / iOS 各自实现一份。
//! 鸿蒙这份的职责只有两件事：
//!
//!   1. **帧**：`on_rgba` 拿到解码后的 RGBA，交给 ArkTS 侧画到 XComponent 上。
//!      走「帧槽 + 背压」模型，与 `flutter::FlutterHandler::on_rgba_soft_render` 同构：
//!      ArkTS 没取走上一帧时直接丢弃新帧，而不是排队——排队在弱网下会变成内存炸弹。
//!
//!   2. **事件**：连接状态、光标、消息框、文件传输进度等，序列化成 JSON 交给
//!      `ohos_ui_event`（C++ 侧转成 napi threadsafe function 派发到 ArkTS）。
//!
//! 为什么不做成「每个 setter 都调一次 C++」：这些回调来自 tokio 线程，
//! 而 ArkTS 的 UI 只能在主线程改；统一走一条 JSON 通道，C++ 侧只需要一次
//! 线程切换的实现，Rust 侧也不用关心线程模型。

use super::ffi;
use crate::client::QualityStatus;
use crate::ui_session_interface::InvokeUiSession;
use base::message_proto::*;
use hbb_common::rendezvous_proto::ConnType;
use scrap::ImageRgb;
use serde_json::json;
use std::{
    collections::HashMap,
    sync::{Arc, RwLock},
};

/// 单个显示器的帧槽。
///
/// 与 `flutter::RgbaData` 的区别只有一处：这里额外记住 `w/h`，因为 ArkTS 侧
/// 拿到的只是一个裸指针，必须同时知道尺寸才能建 `PixelMap`。
#[derive(Default)]
struct FrameSlot {
    data: Vec<u8>,
    w: usize,
    h: usize,
    /// false = ArkTS 已消费，下一帧可以交换缓冲；true = 还没取走，丢弃新帧。
    valid: bool,
}

/// 供 ArkTS 轮询的连接状态快照。
///
/// 事件是「边沿触发」，状态是「电平触发」：ArkTS 页面重建（切后台再回来、
/// 折叠屏展开）后只靠事件会丢状态，所以两者都要有。
#[derive(Clone, Default)]
struct UiState {
    connected: bool,
    secured: bool,
    direct: bool,
    stream_type: String,
    peer_id: String,
    display: (i32, i32, i32, i32),
    scale: f64,
    cursor: (i32, i32),
    cursor_embedded: bool,
    block_input: bool,
    displays: Vec<DisplayInfo>,
}

#[derive(Clone, Default)]
pub struct OhosUiSession {
    frames: Arc<RwLock<HashMap<usize, FrameSlot>>>,
    state: Arc<RwLock<UiState>>,
}

impl OhosUiSession {
    /// 取某显示器的帧指针。返回 `(ptr, width, height)`，`ptr` 为空表示当前没有可用帧。
    ///
    /// 调用方（`entry::rustdesk_ohos_frame_acquire`）拿到指针后必须尽快拷走，
    /// 拷完调 [`release_frame`] 让出缓冲，否则后续帧会被背压丢弃。
    pub fn acquire_frame(&self, display: usize) -> (*const u8, usize, usize) {
        if let Ok(g) = self.frames.read() {
            if let Some(slot) = g.get(&display) {
                if slot.valid {
                    return (slot.data.as_ptr(), slot.w, slot.h);
                }
            }
        }
        (std::ptr::null(), 0, 0)
    }

    /// 标记该显示器的帧已被消费。
    ///
    /// 只把 `valid` 置回 false、**不删槽**：槽里保留的是上一轮换出去的旧缓冲，
    /// 下一次 `on_rgba` 会用 `std::mem::swap` 把它换回视频管线复用。
    /// 删槽等于每帧重新分配一块 1080p（8MB）的 Vec。
    pub fn release_frame(&self, display: usize) {
        if let Ok(mut g) = self.frames.write() {
            if let Some(slot) = g.get_mut(&display) {
                slot.valid = false;
            }
        }
    }

    pub fn state_json(&self) -> String {
        let s = match self.state.read() {
            Ok(s) => s.clone(),
            Err(_) => return "{}".to_owned(),
        };
        json!({
            "connected": s.connected,
            "secured": s.secured,
            "direct": s.direct,
            "stream_type": s.stream_type,
            "peer_id": s.peer_id,
            "display": {
                "x": s.display.0,
                "y": s.display.1,
                "w": s.display.2,
                "h": s.display.3,
            },
            "scale": s.scale,
            "cursor": { "x": s.cursor.0, "y": s.cursor.1, "embedded": s.cursor_embedded },
            "block_input": s.block_input,
            "displays": s.displays.iter().map(|d| json!({
                "x": d.x,
                "y": d.y,
                "width": d.width,
                "height": d.height,
                "cursor_embedded": d.cursor_embedded,
                "scale": d.scale,
            })).collect::<Vec<_>>(),
        })
        .to_string()
    }

    fn with_state(&self, f: impl FnOnce(&mut UiState)) {
        if let Ok(mut g) = self.state.write() {
            f(&mut g);
        }
    }
}

/// 发一条事件给 ArkTS。`payload` 里可以带任何 serde 能序列化的东西。
pub fn emit(event: &str, payload: serde_json::Value) {
    let msg = json!({ "event": event, "data": payload }).to_string();
    ffi::ohos_ui_event(&msg);
}

impl InvokeUiSession for OhosUiSession {
    fn set_cursor_data(&self, cd: CursorData) {
        // 远程光标的位图。移动端不画系统光标（`cursor_embedded` 常为 true），
        // 但控制桌面时仍需要，交给 ArkTS 侧缓存。
        emit(
            "cursor_data",
            json!({
                "id": cd.id,
                "hotx": cd.hotx,
                "hoty": cd.hoty,
                "width": cd.width,
                "height": cd.height,
                "colors": cd.colors,
            }),
        );
    }

    fn set_cursor_id(&self, id: String) {
        emit("cursor_id", json!(id));
    }

    fn set_cursor_position(&self, cp: CursorPosition) {
        self.with_state(|s| s.cursor = (cp.x, cp.y));
        emit("cursor_position", json!({ "x": cp.x, "y": cp.y }));
    }

    fn set_display(&self, x: i32, y: i32, w: i32, h: i32, cursor_embedded: bool, scale: f64) {
        self.with_state(|s| {
            s.display = (x, y, w, h);
            s.cursor_embedded = cursor_embedded;
            s.scale = scale;
        });
        emit(
            "display",
            json!({
                "x": x, "y": y, "w": w, "h": h,
                "cursor_embedded": cursor_embedded,
                "scale": scale,
            }),
        );
    }

    fn switch_display(&self, display: &SwitchDisplay) {
        emit("switch_display", json!({ "display": display.display }));
    }

    fn set_peer_info(&self, peer_info: &PeerInfo) {
        self.with_state(|s| s.peer_id = peer_info.username.clone());
        emit(
            "peer_info",
            json!({
                "username": peer_info.username,
                "hostname": peer_info.hostname,
                "platform": peer_info.platform,
                "version": peer_info.version,
                "displays": peer_info.displays.len(),
                "current_display": peer_info.current_display,
            }),
        );
    }

    fn set_displays(&self, displays: &Vec<DisplayInfo>) {
        self.with_state(|s| s.displays = displays.clone());
        emit(
            "displays",
            json!(displays
                .iter()
                .map(|d| json!({
                    "x": d.x, "y": d.y, "width": d.width, "height": d.height,
                    "cursor_embedded": d.cursor_embedded, "scale": d.scale,
                }))
                .collect::<Vec<_>>()),
        );
    }

    fn set_platform_additions(&self, data: &str) {
        emit("platform_additions", json!(data));
    }

    fn on_connected(&self, conn_type: ConnType) {
        self.with_state(|s| {
            s.connected = true;
            s.stream_type = format!("{:?}", conn_type);
        });
        emit("connected", json!({ "conn_type": format!("{:?}", conn_type) }));
    }

    fn update_privacy_mode(&self) {
        emit("privacy_mode", json!(null));
    }

    fn set_permission(&self, name: &str, value: bool) {
        emit("permission", json!({ "name": name, "value": value }));
    }

    fn close_success(&self) {
        self.with_state(|s| s.connected = false);
        emit("close", json!({ "reason": "success" }));
    }

    fn update_quality_status(&self, qs: QualityStatus) {
        emit("quality_status", json!({ "status": format!("{:?}", qs) }));
    }

    fn set_connection_type(&self, is_secured: bool, direct: bool, stream_type: &str) {
        self.with_state(|s| {
            s.secured = is_secured;
            s.direct = direct;
            s.stream_type = stream_type.to_owned();
        });
        emit(
            "connection_type",
            json!({ "secured": is_secured, "direct": direct, "stream_type": stream_type }),
        );
    }

    fn set_fingerprint(&self, fingerprint: String) {
        emit("fingerprint", json!(fingerprint));
    }

    // --- 文件传输：M2 才做 UI，这里先把事件通道铺好 ---

    fn job_error(&self, id: i32, err: String, file_num: i32) {
        emit("job_error", json!({ "id": id, "err": err, "file_num": file_num }));
    }

    fn job_done(&self, id: i32, file_num: i32) {
        emit("job_done", json!({ "id": id, "file_num": file_num }));
    }

    fn clear_all_jobs(&self) {
        emit("clear_all_jobs", json!(null));
    }

    fn new_message(&self, msg: String) {
        emit("chat", json!(msg));
    }

    fn update_transfer_list(&self) {
        emit("transfer_list", json!(null));
    }

    fn load_last_job(&self, cnt: i32, job_json: &str, auto_start: bool) {
        emit(
            "load_last_job",
            json!({ "count": cnt, "jobs": job_json, "auto_start": auto_start }),
        );
    }

    fn update_folder_files(
        &self,
        id: i32,
        entries: &Vec<FileEntry>,
        path: String,
        is_local: bool,
        only_count: bool,
    ) {
        emit(
            "folder_files",
            json!({
                "id": id,
                "path": path,
                "is_local": is_local,
                "only_count": only_count,
                "entries": entries.iter().map(|e| json!({
                    "name": e.name,
                    // protobuf 的枚举字段是 `EnumOrUnknown<FileType>`，不能直接 serde，
                    // 取 i32 交给 ArkTS 判断（0=Dir 1=File 2=Symlink）。
                    "entry_type": e.entry_type.value(),
                    "is_hidden": e.is_hidden,
                    "size": e.size,
                    "modified_time": e.modified_time,
                })).collect::<Vec<_>>(),
            }),
        );
    }

    fn confirm_delete_files(&self, id: i32, i: i32, name: String) {
        emit("confirm_delete", json!({ "id": id, "index": i, "name": name }));
    }

    fn override_file_confirm(
        &self,
        id: i32,
        file_num: i32,
        to: String,
        is_upload: bool,
        is_identical: bool,
    ) {
        emit(
            "override_file_confirm",
            json!({
                "id": id, "file_num": file_num, "to": to,
                "is_upload": is_upload, "is_identical": is_identical,
            }),
        );
    }

    fn update_block_input_state(&self, on: bool) {
        self.with_state(|s| s.block_input = on);
        emit("block_input", json!({ "on": on }));
    }

    fn job_progress(&self, id: i32, file_num: i32, speed: f64, finished_size: f64) {
        emit(
            "job_progress",
            json!({
                "id": id, "file_num": file_num,
                "speed": speed, "finished_size": finished_size,
            }),
        );
    }

    fn adapt_size(&self) {
        emit("adapt_size", json!(null));
    }

    /// 解码后的一帧。语义与 `flutter::on_rgba_soft_render` 一致：
    /// 上一帧还没被消费就直接返回，把缓冲让回给视频管线复用。
    fn on_rgba(&self, display: usize, rgba: &mut ImageRgb) {
        let mut frames = match self.frames.write() {
            Ok(g) => g,
            Err(_) => return,
        };
        let slot = frames.entry(display).or_default();
        if slot.valid {
            return;
        }
        // 交换而不是拷贝：视频管线下一帧会直接复用这块缓冲。
        std::mem::swap(&mut rgba.raw, &mut slot.data);
        slot.w = rgba.w;
        slot.h = rgba.h;
        slot.valid = true;
        drop(frames);
        emit("rgba", json!({ "display": display }));
    }

    fn msgbox(&self, msgtype: &str, title: &str, text: &str, link: &str, retry: bool) {
        emit(
            "msgbox",
            json!({ "type": msgtype, "title": title, "text": text, "link": link, "retry": retry }),
        );
    }

    fn clipboard(&self, content: String) {
        // 对端剪贴板 → 本机。实际写入由 ArkTS 的 pasteboard 完成。
        emit("clipboard", json!(content));
    }

    fn cancel_msgbox(&self, tag: &str) {
        emit("cancel_msgbox", json!(tag));
    }

    fn switch_back(&self, id: &str) {
        emit("switch_back", json!(id));
    }

    fn portable_service_running(&self, running: bool) {
        emit("portable_service", json!({ "running": running }));
    }

    // --- 语音通话：M2 之后再实现 ---

    fn on_voice_call_started(&self) {
        emit("voice_call_started", json!(null));
    }

    fn on_voice_call_closed(&self, reason: &str) {
        emit("voice_call_closed", json!(reason));
    }

    fn on_voice_call_waiting(&self) {
        emit("voice_call_waiting", json!(null));
    }

    fn on_voice_call_incoming(&self) {
        emit("voice_call_incoming", json!(null));
    }

    fn get_rgba(&self, display: usize) -> *const u8 {
        self.acquire_frame(display).0
    }

    fn next_rgba(&self, display: usize) {
        self.release_frame(display);
    }

    fn set_multiple_windows_session(&self, sessions: Vec<WindowsSession>) {
        emit(
            "windows_session",
            json!(sessions
                .iter()
                .map(|s| json!({ "sid": s.sid }))
                .collect::<Vec<_>>()),
        );
    }

    fn set_current_display(&self, disp_idx: i32) {
        emit("current_display", json!(disp_idx));
    }

    fn update_record_status(&self, start: bool) {
        emit("record_status", json!({ "start": start }));
    }

    fn printer_request(&self, id: i32, path: String) {
        emit("printer_request", json!({ "id": id, "path": path }));
    }

    fn handle_screenshot_resp(&self, sid: String, msg: String) {
        emit("screenshot", json!({ "sid": sid, "msg": msg }));
    }

    fn handle_terminal_response(&self, response: TerminalResponse) {
        // 终端（`ipc` 里那套）在手机上不做 UI，保留通道以防对端主动推送。
        emit("terminal_response", json!(format!("{:?}", response)));
    }
}
