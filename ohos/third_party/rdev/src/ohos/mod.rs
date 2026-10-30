//! OpenHarmony 后端：全部为「能力不存在」的空实现。
//!
//! 与 android 的处理方式不同（上游直接把 android 的 listen/grab 从 API 里删掉），这里
//! **保留与 linux 后端完全一致的签名**，因为 rustdesk 的 `src/keyboard.rs` 有 160 余处
//! `rdev::` 调用，其中相当一部分没有按平台加 cfg。签名一致 → 调用点零改动，
//! 运行期它们只是"什么也没抓到"（OHOS 没有全局键鼠钩子，这是事实而非缺陷）。
//!
//! 真正的键鼠注入走 `src/platform/ohos/ffi.rs` 的 `ohos_input_*`（2in1 形态下由
//! OH_Input 提供），不经过 rdev。

use crate::rdev::{
    DisplayError, Event, EventType, GrabError, KeyboardState, ListenError, SimulateError,
    UnicodeInfo,
};

pub fn display_size() -> Result<(u64, u64), DisplayError> {
    Err(DisplayError::NoDisplay)
}

pub fn listen<T>(_callback: T) -> Result<(), ListenError>
where
    T: FnMut(Event) + 'static,
{
    Err(ListenError::MissingDisplayError)
}

pub fn simulate(_event_type: &EventType) -> Result<(), SimulateError> {
    Err(SimulateError)
}

pub fn simulate_char(_chr: char, _pressed: bool) -> Result<(), SimulateError> {
    Err(SimulateError)
}

pub fn simulate_unicode(_unicode: u16) -> Result<(), SimulateError> {
    Err(SimulateError)
}

// --- grab 系列：无全局钩子，保持"未抓取"状态 ---

pub fn enable_grab() {}

pub fn disable_grab() {}

pub fn is_grabbed() -> bool {
    false
}

/// 注意回调签名必须与 linux 后端的 `FnMut(Event) -> Option<Event>` 一致。
/// rustdesk 的 `keyboard.rs` 在这个回调里做「按键是否已被本地吞掉」的判定，
/// 返回 `None` 表示拦截、`Some(ev)` 表示继续下发；签名写窄了会让调用点编译不过。
pub fn start_grab_listen<T>(_callback: T) -> Result<(), GrabError>
where
    T: FnMut(Event) -> Option<Event> + 'static,
{
    Err(GrabError::ListenError)
}

pub fn exit_grab_listen() {}

// --- Keyboard：OHOS 下不存在 X11 的 XIM/XIC，键位状态机由 RustDesk 自己的
//     `keyboard::client`（基于 linux keycode 表）负责，这里只需满足类型要求。 ---

#[derive(Default)]
pub struct Keyboard;

impl Keyboard {
    pub fn new() -> Option<Keyboard> {
        Some(Keyboard)
    }
}

impl KeyboardState for Keyboard {
    fn add(&mut self, _event_type: &EventType) -> Option<UnicodeInfo> {
        None
    }
}
