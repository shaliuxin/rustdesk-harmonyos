#[cfg(quartz)]
extern crate block;
#[macro_use]
extern crate cfg_if;
pub use hbb_common::libc;
#[cfg(dxgi)]
extern crate winapi;

pub use common::*;

#[cfg(quartz)]
pub mod quartz;

#[cfg(x11)]
pub mod x11;

#[cfg(all(x11, feature = "wayland"))]
pub mod wayland;

#[cfg(dxgi)]
pub mod dxgi;

#[cfg(target_os = "android")]
pub mod android;

// ---------------------------------------------------------------------------
// OHOS 兼容模块
// ---------------------------------------------------------------------------
// 上游把「主服务转发按键/指针」写成了 `scrap::android::*`（Android 上是 JNI 到
// 一个常驻主服务进程），把「Wayland 门户会话」写成 `scrap::wayland::*`。
// 这两处调用点都包在 `#[cfg(any(target_os = "linux", target_os = "android"))]` 里，
// 而鸿蒙的 target_os 就是 "linux"，会意外命中。
//
// 与其在上游加 cfg，这里按同名模块提供空实现 —— 与 `platform::ohos::linux_compat`
// 同一策略：用签名兼容换上游零改动。
//
// 语义说明：
//   - 鸿蒙的输入注入由 C++ 侧 OH_Input 完成（rdev 空后端 → ffi），不经过主服务；
//   - 鸿蒙没有 xdg-desktop-portal，屏幕采集走 AVScreenCapture，无「门户会话」概念。

#[cfg(target_env = "ohos")]
pub mod android {
    use hbb_common::ResultType;

    /// 转发按键事件给主服务。鸿蒙无此模型，空实现。
    pub fn call_main_service_key_event(_data: &[u8]) -> ResultType<()> {
        Ok(())
    }

    /// 转发指针事件给主服务。鸿蒙无此模型，空实现。
    pub fn call_main_service_pointer_input(
        _kind: &str,
        _mask: i32,
        _x: i32,
        _y: i32,
    ) -> ResultType<()> {
        Ok(())
    }

    /// 剪贴板：与 Android 的同名模块对齐。
    ///
    /// `src/clipboard.rs` 的移动端分支（`#[cfg(any(android, ohos))]`）会调
    /// `scrap::android::ffi::{call_clipboard_manager_update_clipboard, get_clipboards}`，
    /// 语义是「把整个 MultiClipboards 交给系统剪贴板 / 从系统剪贴板取回」。
    ///
    /// Android 上这两个函数走 JNI 到 ClipboardManager；鸿蒙上走 C++ 侧的
    /// OH_Pasteboard，传输格式同样是 protobuf 字节 —— 这样 `clipboard.rs` 里
    /// 的多格式协商、压缩标记、owner marker 全部原样复用。
    pub mod ffi {
        // 注意：message_proto 由 `base` crate 生成（`hbb_common` 里没有），
        // 这与 `src/clipboard.rs` 里 `use base::message_proto::*` 是同一来源。
        use base::message_proto::MultiClipboards;
        use hbb_common::protobuf::Message;
        use hbb_common::ResultType;
        use std::os::raw::{c_int, c_uchar};

        extern "C" {
            /// 把 protobuf 序列化的 MultiClipboards 写入系统剪贴板（多 MIME 记录）。
            /// 返回 0 成功。
            fn ohos_clipboard_update_multi(data: *const c_uchar, len: usize) -> c_int;
            /// 从系统剪贴板读回 MultiClipboards（protobuf 字节）。
            /// 成功时 `*out` / `*out_len` 指向 C++ 侧分配的缓冲区，调用方负责释放。
            fn ohos_clipboard_get_multi(out: *mut *mut c_uchar, out_len: *mut usize) -> c_int;
            /// 释放 C++ 侧分配的字节缓冲。
            fn ohos_free_bytes(p: *mut c_uchar);
        }

        pub fn call_clipboard_manager_update_clipboard(data: &[u8]) -> ResultType<()> {
            unsafe { ohos_clipboard_update_multi(data.as_ptr(), data.len()) };
            Ok(())
        }

        pub fn get_clipboards(_client: bool) -> Option<MultiClipboards> {
            unsafe {
                let mut ptr: *mut c_uchar = std::ptr::null_mut();
                let mut len: usize = 0;
                if ohos_clipboard_get_multi(&mut ptr, &mut len) != 0 || ptr.is_null() {
                    return None;
                }
                let bytes = std::slice::from_raw_parts(ptr, len).to_vec();
                ohos_free_bytes(ptr);
                MultiClipboards::parse_from_bytes(&bytes).ok()
            }
        }
    }
}

#[cfg(target_env = "ohos")]
pub mod wayland {
    /// 鸿蒙没有 Wayland 门户会话，`is_rdp_session_hold` 恒 false（表示未占用）。
    pub mod pipewire {
        pub fn is_rdp_session_hold() -> bool {
            false
        }

        /// 关闭门户会话。鸿蒙无会话可关。
        pub fn close_session() {}
    }
}

mod common;
