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

    /// 被控端的键鼠注入实现。
    ///
    /// 上游 connection.rs 在移动端把鼠标/按键事件交给 `call_main_service_*`，
    /// Android 走 JNI 到 Flutter，鸿蒙直接走 C ABI 到 C++ 的 `OH_Input_Inject*`。
    /// 这样上游一个 cfg 都不用改（这里的 shim 本来就是我们的新增文件）。
    mod inject {
        use super::*;
        use base::message_proto::{ControlKey, KeyEvent};
        use hbb_common::protobuf::{EnumOrUnknown, Message as _};
        use std::sync::Mutex;

        extern "C" {
            fn ohos_input_inject_mouse_move(x: i32, y: i32) -> i32;
            fn ohos_input_inject_mouse_button(button: i32, down: i32, x: i32, y: i32) -> i32;
            fn ohos_input_inject_mouse_wheel(x: i32, y: i32, vertical: f32) -> i32;
            fn ohos_input_inject_key(keycode: i32, down: i32) -> i32;
        }

        // --- OHOS KeyCode（multimodalinput/oh_key_code.h）---
        const K_0: i32 = 2000;
        const K_A: i32 = 2017;
        const K_COMMA: i32 = 2043;
        const K_PERIOD: i32 = 2044;
        const K_ALT_LEFT: i32 = 2045;
        const K_SHIFT_LEFT: i32 = 2047;
        const K_TAB: i32 = 2049;
        const K_SPACE: i32 = 2050;
        const K_ENTER: i32 = 2054;
        const K_DEL: i32 = 2055;
        const K_GRAVE: i32 = 2056;
        const K_MINUS: i32 = 2057;
        const K_EQUALS: i32 = 2058;
        const K_LEFT_BRACKET: i32 = 2059;
        const K_RIGHT_BRACKET: i32 = 2060;
        const K_BACKSLASH: i32 = 2061;
        const K_SEMICOLON: i32 = 2062;
        const K_APOSTROPHE: i32 = 2063;
        const K_SLASH: i32 = 2064;
        const K_PAGE_UP: i32 = 2068;
        const K_PAGE_DOWN: i32 = 2069;
        const K_ESCAPE: i32 = 2070;
        const K_FORWARD_DEL: i32 = 2071;
        const K_CTRL_LEFT: i32 = 2072;
        const K_CAPS_LOCK: i32 = 2074;
        const K_META_LEFT: i32 = 2076;
        const K_MOVE_HOME: i32 = 2081;
        const K_MOVE_END: i32 = 2082;
        const K_INSERT: i32 = 2083;
        const K_F1: i32 = 2090;
        const K_NUMPAD_0: i32 = 2103;
        const K_DPAD_UP: i32 = 2012;
        const K_DPAD_DOWN: i32 = 2013;
        const K_DPAD_LEFT: i32 = 2014;
        const K_DPAD_RIGHT: i32 = 2015;

        /// 当前按住的修饰键（keycode）。上游每次事件都带完整修饰键列表，
        /// 这里做差量同步：缺的按下、多的抬起。
        static HELD_MODS: Mutex<Vec<i32>> = Mutex::new(Vec::new());

        fn mod_keycode(k: ControlKey) -> Option<i32> {
            match k {
                ControlKey::Shift => Some(K_SHIFT_LEFT),
                ControlKey::Control => Some(K_CTRL_LEFT),
                ControlKey::Alt | ControlKey::Option | ControlKey::Menu => Some(K_ALT_LEFT),
                ControlKey::Meta => Some(K_META_LEFT),
                _ => None,
            }
        }

        fn sync_mods(target: &[i32]) {
            let mut held = HELD_MODS.lock().unwrap_or_else(|e| e.into_inner());
            for k in held.iter() {
                if !target.contains(k) {
                    unsafe { ohos_input_inject_key(*k, 0) };
                }
            }
            for k in target.iter() {
                if !held.contains(k) {
                    unsafe { ohos_input_inject_key(*k, 1) };
                }
            }
            *held = target.to_vec();
        }

        /// ControlKey（功能键）→ OHOS keycode。
        fn control_keycode(k: ControlKey) -> Option<i32> {
            use ControlKey::*;
            Some(match k {
                Backspace => K_DEL,
                CapsLock => K_CAPS_LOCK,
                Delete => K_FORWARD_DEL,
                DownArrow => K_DPAD_DOWN,
                End => K_MOVE_END,
                Escape => K_ESCAPE,
                F1 => K_F1,
                F2 => K_F1 + 1,
                F3 => K_F1 + 2,
                F4 => K_F1 + 3,
                F5 => K_F1 + 4,
                F6 => K_F1 + 5,
                F7 => K_F1 + 6,
                F8 => K_F1 + 7,
                F9 => K_F1 + 8,
                F10 => K_F1 + 9,
                F11 => K_F1 + 10,
                F12 => K_F1 + 11,
                Home => K_MOVE_HOME,
                LeftArrow => K_DPAD_LEFT,
                PageDown => K_PAGE_DOWN,
                PageUp => K_PAGE_UP,
                Return => K_ENTER,
                RightArrow => K_DPAD_RIGHT,
                Shift => K_SHIFT_LEFT,
                Control => K_CTRL_LEFT,
                Space => K_SPACE,
                Tab => K_TAB,
                UpArrow => K_DPAD_UP,
                Alt | Option | Menu => K_ALT_LEFT,
                Meta => K_META_LEFT,
                Insert => K_INSERT,
                Numpad0 => K_NUMPAD_0,
                Numpad1 => K_NUMPAD_0 + 1,
                Numpad2 => K_NUMPAD_0 + 2,
                Numpad3 => K_NUMPAD_0 + 3,
                Numpad4 => K_NUMPAD_0 + 4,
                Numpad5 => K_NUMPAD_0 + 5,
                Numpad6 => K_NUMPAD_0 + 6,
                Numpad7 => K_NUMPAD_0 + 7,
                Numpad8 => K_NUMPAD_0 + 8,
                Numpad9 => K_NUMPAD_0 + 9,
                _ => return None,
            })
        }

        /// 可打印字符 → (keycode, 是否需要 shift)。
        ///
        /// 只覆盖 US 布局的 ASCII：`chr` 在 legacy 模式下就是字符本身，
        /// 非 ASCII（中文等）无法用键码表达，交给上游的文本输入通道。
        fn char_keycode(c: char) -> Option<(i32, bool)> {
            let (code, shift) = match c {
                '0'..='9' => (K_0 + (c as i32 - '0' as i32), false),
                'a'..='z' => (K_A + (c as i32 - 'a' as i32), false),
                'A'..='Z' => (K_A + (c as i32 - 'A' as i32), true),
                ' ' => (K_SPACE, false),
                ',' => (K_COMMA, false),
                '.' => (K_PERIOD, false),
                '`' => (K_GRAVE, false),
                '-' => (K_MINUS, false),
                '=' => (K_EQUALS, false),
                '[' => (K_LEFT_BRACKET, false),
                ']' => (K_RIGHT_BRACKET, false),
                '\\' => (K_BACKSLASH, false),
                ';' => (K_SEMICOLON, false),
                '\'' => (K_APOSTROPHE, false),
                '/' => (K_SLASH, false),
                // 需要 shift 的符号：按「基础键 + shift」表达
                '!' => (K_0 + 1, true),
                '@' => (K_0 + 2, true),
                '#' => (K_0 + 3, true),
                '$' => (K_0 + 4, true),
                '%' => (K_0 + 5, true),
                '^' => (K_0 + 6, true),
                '&' => (K_0 + 7, true),
                '*' => (K_0 + 8, true),
                '(' => (K_0 + 9, true),
                ')' => (K_0, true),
                '_' => (K_MINUS, true),
                '+' => (K_EQUALS, true),
                '{' => (K_LEFT_BRACKET, true),
                '}' => (K_RIGHT_BRACKET, true),
                '|' => (K_BACKSLASH, true),
                ':' => (K_SEMICOLON, true),
                '"' => (K_APOSTROPHE, true),
                '<' => (K_COMMA, true),
                '>' => (K_PERIOD, true),
                '?' => (K_SLASH, true),
                '~' => (K_GRAVE, true),
                _ => return None,
            };
            Some((code, shift))
        }

        pub fn pointer(kind: &str, mask: i32, x: i32, y: i32) {
            // 触摸注入这条链在 2in1 上不需要；手机形态本来就不开被控。
            if kind != "mouse" {
                return;
            }
            const TYPE_MASK: i32 = 0x7;
            let evt_type = mask & TYPE_MASK;
            let buttons = mask >> 3; // 1=左 2=右 4=中 8=后退 16=前进

            // 上游协议里只有 move 事件带坐标，down/up 往往是 (0,0) —— Android 端
            // 也是靠 InputService 自己记住 mouseX/mouseY 再补上的（见
            // InputService.kt onMouseInput）。OHOS 的全局注入要求坐标有效，
            // (0,0) 会被判成非法参数（rc=401），所以这里同样用最近一次 move 的
            // 落点补齐按下/抬起事件。
            static LAST_POS: Mutex<(i32, i32)> = Mutex::new((0, 0));
            let (x, y) = match evt_type {
                0 => {
                    let mut p = LAST_POS.lock().unwrap_or_else(|e| e.into_inner());
                    if x != 0 || y != 0 {
                        *p = (x.max(0), y.max(0));
                    }
                    (x.max(0), y.max(0))
                }
                1 | 2 => {
                    let p = *LAST_POS.lock().unwrap_or_else(|e| e.into_inner());
                    (if x == 0 { p.0 } else { x }, if y == 0 { p.1 } else { y })
                }
                _ => (x, y),
            };

            unsafe {
                match evt_type {
                    0 => {
                        ohos_input_inject_mouse_move(x, y);
                    }
                    1 | 2 => {
                        // OHOS：0=左 1=中 2=右 3=前进 4=后退
                        let button = match buttons {
                            1 => 0,
                            2 => 2,
                            4 => 1,
                            8 => 4,
                            16 => 3,
                            _ => 0,
                        };
                        ohos_input_inject_mouse_button(button, (evt_type == 1) as i32, x, y);
                    }
                    3 | 4 => {
                        // 滚轮：协议把增量放在 y 上。不同客户端单位不一致 ——
                        // Windows/Flutter 一档给 ±120，部分客户端直接给 ±1。
                        // OH_Input 的轴值是「像素增量」而不是档数，统一折算成
                        // 每档 120 再下发（发 ±1 只会滚 1 像素，肉眼等于没动）。
                        let p = *LAST_POS.lock().unwrap_or_else(|e| e.into_inner());
                        let raw = y as f32;
                        let step = if raw.abs() >= 30.0 { raw } else { raw * 120.0 };
                        ohos_input_inject_mouse_wheel(p.0, p.1, step);
                    }
                    _ => {}
                }
            }
        }

        pub fn key(data: &[u8]) {
            use base::message_proto::key_event::Union;
            let evt = match KeyEvent::parse_from_bytes(data) {
                Ok(v) => v,
                Err(_) => return,
            };
            // 1) 修饰键先同步到位，主键的按下/抬起才能带对状态
            let mut mods: Vec<i32> = Vec::new();
            for m in evt.modifiers.iter() {
                if let Ok(k) = m.enum_value() {
                    if let Some(code) = mod_keycode(k) {
                        mods.push(code);
                    }
                }
            }
            // 2) 主键：功能键优先，其次按字符
            let code = match &evt.union {
                Some(Union::ControlKey(k)) => k
                    .enum_value()
                    .ok()
                    .filter(|v| *v != ControlKey::Unknown)
                    .and_then(control_keycode),
                Some(Union::Chr(c)) => char_keycode(char::from_u32(*c).unwrap_or('\0')).map(
                    |(code, shift)| {
                        if shift && !mods.contains(&K_SHIFT_LEFT) {
                            mods.push(K_SHIFT_LEFT);
                        }
                        code
                    },
                ),
                Some(Union::Unicode(c)) => char_keycode(char::from_u32(*c).unwrap_or('\0')).map(
                    |(code, shift)| {
                        if shift && !mods.contains(&K_SHIFT_LEFT) {
                            mods.push(K_SHIFT_LEFT);
                        }
                        code
                    },
                ),
                _ => None,
            };
            let code = match code {
                Some(c) => c,
                None => return,
            };
            let down = evt.down || evt.press;
            // 抬起事件里，修饰键列表已经是「抬完之后的」状态，先抬主键再同步；
            // 按下事件则相反。
            if down {
                sync_mods(&mods);
                unsafe { ohos_input_inject_key(code, 1) };
            } else {
                unsafe { ohos_input_inject_key(code, 0) };
                sync_mods(&mods);
            }
        }
    }

    /// 转发按键事件：鸿蒙直接从 protobuf 解析后走 OH_Input 注入。
    pub fn call_main_service_key_event(data: &[u8]) -> ResultType<()> {
        inject::key(data);
        Ok(())
    }

    /// 转发指针事件（目前只有鼠标；触摸注入未实现，直接忽略）。
    pub fn call_main_service_pointer_input(
        kind: &str,
        mask: i32,
        x: i32,
        y: i32,
    ) -> ResultType<()> {
        inject::pointer(kind, mask, x, y);
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

            /// 系统播放声的环形缓冲：可读字节数 / 取走最多 cap 字节。
            fn ohos_capture_audio_available() -> c_int;
            fn ohos_capture_read_audio(dst: *mut c_uchar, cap: c_int) -> c_int;
        }

        /// 从 AVScreenCapture 的音频环形缓冲取 PCM，转成 f32 交错样本。
        ///
        /// 与 Android 的同名函数签名/语义保持一致（返回 `Some(())` 表示本轮到数据），
        /// 这样 `audio_service::pa_impl` 里两侧可以共用同一段编码逻辑。
        ///
        /// 只取**整 10ms 块**：系统给的是 S16LE / 48kHz / 立体声，10ms = 960 帧 =
        /// 1920 字节；Opus 只接受固定帧长（120/240/480/960/1920/2880 样本/声道），
        /// 半块的尾巴留在环形缓冲里等下一轮拼齐。
        pub fn get_audio_raw(dst: &mut Vec<u8>, _last: &mut Vec<u8>) -> Option<()> {
            const BLOCK: usize = 1920; // 10ms @ 48k stereo s16le
            const MAX_BLOCKS: usize = 5; // 单次最多 50ms，避免编码帧过大

            let avail = unsafe { ohos_capture_audio_available() };
            let avail = if avail > 0 { avail as usize } else { return None };
            let blocks = (avail / BLOCK).min(MAX_BLOCKS);
            if blocks == 0 {
                return None;
            }
            let want = blocks * BLOCK;
            let mut raw = vec![0u8; want];
            let n = unsafe { ohos_capture_read_audio(raw.as_mut_ptr(), want as c_int) };
            let n = (n.max(0) as usize / BLOCK) * BLOCK;
            if n == 0 {
                return None;
            }
            dst.clear();
            dst.reserve(n / 2 * 4);
            for i in 0..n / 2 {
                let s = i16::from_le_bytes([raw[i * 2], raw[i * 2 + 1]]);
                dst.extend_from_slice(&(s as f32 / 32768.0).to_le_bytes());
            }
            Some(())
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
