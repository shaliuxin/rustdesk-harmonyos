//! 被控端文件传输服务。
//!
//! 桌面端把文件系统操作交给独立的 CM（连接管理器）进程：`Connection` 只负责
//! 协议解析，收到 `FileAction` 后通过 `send_to_cm(ipc::Data::FS(..))` 把请求
//! 丢给 CM，CM 在 `ui_cm_interface::start_listen` 里处理并回发
//! `Data::RawMessage` / `Data::FileBlockFromCM`。
//!
//! 鸿蒙没有 CM 进程，`tx_to_cm` 的接收端不存在，消息直接蒸发——表现就是主控
//! 打开文件窗口后一直空白（连 `ReadDir` 都没人应答）。
//!
//! 这里起一个最小的「CM 替身」：只消费 `ipc::Data` 里的 `FS` 变体，复用
//! `ui_cm_interface` 的 `handle_fs`（浏览/新建/删除/重命名/上传落盘）和
//! `handle_read_jobs_tick`（下载时按块读取文件），回包走 `tx_from_cm`
//! 交给 `Connection` 发给对端。其余 Data 变体（剪贴板、权限、语音…）与
//! 文件传输无关，忽略。
//!
//! 注意：每个被控连接一个实例，`conn_id` 用于把读块回包路由回正确的连接。

use hbb_common::{
    log,
    tokio::{
        select,
        sync::mpsc::{UnboundedReceiver, UnboundedSender},
        time::{self, Duration, Instant},
    },
};

use crate::ipc;

/// 有读任务（对端下载）时的驱动间隔，与桌面 CM 一致。
const MILLI5: Duration = Duration::from_millis(5);
/// 空闲时退避，避免空转。
const SEC30: Duration = Duration::from_secs(30);

/// 启动本地文件服务。必须在 tokio runtime 内调用。
pub fn start(
    mut rx: UnboundedReceiver<ipc::Data>,
    tx: UnboundedSender<ipc::Data>,
    conn_id: i32,
) {
    hbb_common::tokio::spawn(async move {
        // 上传（对端写本机）与下载（本机读给对端）各自的任务表。
        let mut write_jobs: Vec<base::fs::TransferJob> = Vec::new();
        let mut read_jobs: Vec<base::fs::TransferJob> = Vec::new();
        let mut file_timer =
            crate::rustdesk_interval(time::interval_at(Instant::now() + SEC30, SEC30));
        log::info!("ohos fs service started, conn_id={}", conn_id);
        loop {
            select! {
                data = rx.recv() => {
                    match data {
                        Some(ipc::Data::FS(fs)) => {
                            crate::ui_cm_interface::handle_fs(
                                fs,
                                &mut write_jobs,
                                &mut read_jobs,
                                &tx,
                                None,
                                conn_id,
                            )
                            .await;
                            // 新读任务要立刻开始发块，不等 30 秒的空闲节拍。
                            if !read_jobs.is_empty() {
                                file_timer =
                                    crate::rustdesk_interval(time::interval(MILLI5));
                            }
                        }
                        Some(_) => {
                            // 聊天已由 Connection 自己 emit host_chat；其余 CM 事件
                            // （剪贴板文件、权限回滚、语音）鸿蒙暂不支持，丢弃。
                        }
                        None => break,
                    }
                }
                _ = file_timer.tick() => {
                    if !read_jobs.is_empty() {
                        if let Err(err) =
                            crate::ui_cm_interface::handle_read_jobs_tick(
                                &mut read_jobs,
                                &tx,
                                conn_id,
                            )
                            .await
                        {
                            log::error!("ohos fs: handle read jobs failed: {}", err);
                        }
                    } else {
                        file_timer = crate::rustdesk_interval(time::interval_at(
                            Instant::now() + SEC30,
                            SEC30,
                        ));
                    }
                }
            }
        }
        log::info!("ohos fs service exited, conn_id={}", conn_id);
    });
}
