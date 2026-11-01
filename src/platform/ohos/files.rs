//! 主控侧文件传输。
//!
//! 这一层比会话层更薄：目录浏览、新建、改名、删除、上传、下载**全部是上游现成的**
//! （`libs/base/src/fs.rs` 的 `TransferJob` + `FileManager` trait 的默认实现，
//! 它们只是往 io_loop 里投一条 `Data::*`，真正的收发在 io_loop 里）。
//! 鸿蒙侧要做的只有两件事：
//!   1. 用 `ConnType::FILE_TRANSFER` 建一个会话（普通会话是被控桌面，不是文件管理器）；
//!   2. 把 trait 方法包成 C ABI，让 ArkTS 能调到。
//!
//! **本机侧（沙箱）完全不经过 Rust**：ArkTS 用 `@ohos.file.fs` 直接读写，
//! 所以这里没有任何「本地目录」的概念 —— 下载的目标路径、上传的源路径都由
//! ArkTS 算好传进来。这样既不用做 Android 那套 SAF 适配，也不会有两套目录语义。
//!
//! 事件（进度 / 出错 / 完成 / 目标目录列表）仍走 `ui_handler` 已经铺好的 JSON 通道，
//! 见 `ui_handler.rs` 的 `job_progress` / `folder_files` / `job_error` / `job_done`。

use super::session;
use crate::client::file_trait::FileManager;
use base::fs;
use hbb_common::{bail, log, rendezvous_proto::ConnType, ResultType};

/// 取当前会话。文件操作没有会话就无从谈起，统一在这里报错。
fn sess() -> ResultType<session::OhosSession> {
    session::current().ok_or_else(|| hbb_common::anyhow::anyhow!("no file transfer session"))
}

/// 建文件传输会话。
///
/// 复用了主控会话的全套逻辑（登录、密码、加密、中继），唯一区别是
/// `ConnType::FILE_TRANSFER`：对端收到后会弹「对方请求文件传输」的授权框，
/// 而不是开一路屏幕视频。
pub fn start(peer_id: &str, password: &str, force_relay: bool) -> ResultType<()> {
    session::start_conn(peer_id, password, force_relay, ConnType::FILE_TRANSFER)
}

/// 读远端目录。结果不是通过返回值给的，而是异步事件 `folder_files`
/// （路径、条目、是否是本机目录都在事件里）。
///
/// `path` 传空串表示「对端的默认目录」（通常是用户主目录），
/// 这是上游约定：`FileAction::ReadDir{path:""}` 由对端自己解析成 home。
pub fn list(path: &str, include_hidden: bool) -> ResultType<()> {
    let s = sess()?;
    log::info!("ohos: files list '{}' hidden={}", path, include_hidden);
    s.read_remote_dir(path.to_owned(), include_hidden);
    Ok(())
}

/// 在远端新建目录。返回本次操作 id（对端可能回一条 `FileDir` 刷新列表）。
pub fn mkdir(path: &str) -> ResultType<i32> {
    let s = sess()?;
    let id = fs::get_next_job_id();
    log::info!("ohos: files mkdir '{}' id={}", path, id);
    s.create_dir(id, path.to_owned(), true);
    Ok(id)
}

/// 重命名 / 移动：`new_name` 是**文件名**，不是路径（对端按同目录拼接）。
pub fn rename(path: &str, new_name: &str) -> ResultType<i32> {
    if new_name.trim().is_empty() {
        bail!("empty new name");
    }
    let s = sess()?;
    let id = fs::get_next_job_id();
    log::info!("ohos: files rename '{}' -> '{}' id={}", path, new_name, id);
    s.rename_file(id, path.to_owned(), new_name.to_owned(), true);
    Ok(id)
}

/// 删除远端文件或目录。目录走 `FileRemoveDir{recursive:true}`，一条消息删整棵树，
/// 不需要像桌面版那样先枚举再逐个删（那是为了显示删除进度）。
pub fn remove(path: &str, is_dir: bool) -> ResultType<i32> {
    let s = sess()?;
    let id = fs::get_next_job_id();
    log::info!("ohos: files remove '{}' dir={} id={}", path, is_dir, id);
    if is_dir {
        s.remove_dir(id, path.to_owned(), true);
    } else {
        s.remove_file(id, path.to_owned(), 0, true);
    }
    Ok(id)
}

/// 下载：远端 → 本机。
///
/// `local_to` 是**本机的完整目标路径**（文件或目录本身，不是父目录）：
/// 上游 `TransferJob::new_write` 会把远端条目名 `join` 到它上面，
/// 对单文件来说两者相等；对目录来说它是「本地新建的那个目录」。
/// 父目录不存在时上游会自动 `create_dir_all`。
pub fn download(remote_path: &str, local_to: &str) -> ResultType<i32> {
    if remote_path.trim().is_empty() || local_to.trim().is_empty() {
        bail!("empty path");
    }
    let s = sess()?;
    let id = fs::get_next_job_id();
    log::info!(
        "ohos: files download id={} remote='{}' -> '{}'",
        id,
        remote_path,
        local_to
    );
    // 第 2 个参数是 JobType::Generic(0)，第 5 个是 file_num=0（单任务），
    // 最后一个是 is_remote=true（“远端是源”）。
    s.send_files(
        id,
        0,
        remote_path.to_owned(),
        local_to.to_owned(),
        0,
        false,
        true,
    );
    Ok(id)
}

/// 上传：本机 → 远端。
///
/// `remote_dir` 是远端目标**目录**，条目名由 Rust 侧递归枚举后逐个拼上去。
pub fn upload(local_path: &str, remote_dir: &str) -> ResultType<i32> {
    if local_path.trim().is_empty() {
        bail!("empty local path");
    }
    let s = sess()?;
    let id = fs::get_next_job_id();
    log::info!(
        "ohos: files upload id={} local='{}' -> '{}'",
        id,
        local_path,
        remote_dir
    );
    s.send_files(
        id,
        0,
        local_path.to_owned(),
        remote_dir.to_owned(),
        0,
        false,
        false,
    );
    Ok(id)
}

/// 取消一个传输任务。已经被取消/已结束的任务再取消一次也没关系。
pub fn cancel(id: i32) {
    if let Some(s) = session::current() {
        log::info!("ohos: files cancel id={}", id);
        s.cancel_job(id);
    }
}

/// 断点续传。`is_remote` 与当初建任务时的方向一致：
/// 下载（远端是源）传 true，上传传 false。
pub fn resume(id: i32, is_remote: bool) {
    if let Some(s) = session::current() {
        log::info!("ohos: files resume id={} remote={}", id, is_remote);
        s.resume_job(id, is_remote);
    }
}

/// 回应「目标已存在，是否覆盖」。
///
/// `remember` 为真时把这次选择写进任务的覆盖策略，后面同名文件不再一个个问。
pub fn confirm_override(
    id: i32,
    file_num: i32,
    need_override: bool,
    remember: bool,
    is_upload: bool,
) {
    if let Some(s) = session::current() {
        log::info!(
            "ohos: files override id={} file={} override={} remember={} upload={}",
            id,
            file_num,
            need_override,
            remember,
            is_upload
        );
        s.set_confirm_override_file(id, file_num, need_override, remember, is_upload);
    }
}
