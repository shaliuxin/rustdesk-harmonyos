//! 被控端键盘注入：`rdev::Key` → OpenHarmony KeyCode。
//!
//! 上游的 `Connection::handle_msg` 里，`KeyEvent` 分支的桌面实现带
//! `not(target_env = "ohos")`，鸿蒙被 `_ => {}` 兜底，按键就此消失 ——
//! 现象就是「主控端键盘打字，鸿蒙端毫无反应」，而鼠标是好的（鼠标有单独分支）。
//!
//! 协议约定（见 `keyboard.rs` 的 `is_modifier_code`）：Map 模式下 `KeyEvent.chr`
//! 是 **evdev keycode**，被控端用 `rdev::linux_key_from_code` 还原成统一的
//! `rdev::Key`。鸿蒙的 target_os 就是 linux，所以这里可以直接复用同一条路径，
//! 再把 `rdev::Key` 翻成 OHOS 的 `KeyCode` 交给 `OH_Input_InjectKeyEvent`。
//!
//! Translate 模式（`chr` 是 unicode 字符）没有对应键码，走「字符 → 键位 + Shift」
//! 的合成序列；拿不到的字符直接丢弃，宁可少打一个字也不注入错误的键。

use super::ffi;
use hbb_common::log;
use base::message_proto::{key_event, KeyEvent, KeyboardMode};
use rdev::Key;

// ---- OHOS KeyCode（multimodalinput/oh_key_code.h）-------------------------
// 只摘用到的部分，字面量比 FFI 常量更省事：这些值是公开 ABI，不会变。

const K_0: i32 = 2000;
const K_1: i32 = 2001;
const K_9: i32 = 2009;
const K_DPAD_UP: i32 = 2012;
const K_DPAD_DOWN: i32 = 2013;
const K_DPAD_LEFT: i32 = 2014;
const K_DPAD_RIGHT: i32 = 2015;
const K_A: i32 = 2017; // A..Z 按字母序连续到 2042
const K_COMMA: i32 = 2043;
const K_PERIOD: i32 = 2044;
const K_ALT_LEFT: i32 = 2045;
const K_ALT_RIGHT: i32 = 2046;
const K_SHIFT_LEFT: i32 = 2047;
const K_SHIFT_RIGHT: i32 = 2048;
const K_TAB: i32 = 2049;
const K_SPACE: i32 = 2050;
const K_ENTER: i32 = 2054;
const K_DEL: i32 = 2055; // Backspace
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
const K_CTRL_RIGHT: i32 = 2073;
const K_CAPS_LOCK: i32 = 2074;
const K_SCROLL_LOCK: i32 = 2075;
const K_META_LEFT: i32 = 2076;
const K_META_RIGHT: i32 = 2077;
const K_PRINT: i32 = 2079;
const K_PAUSE: i32 = 2080;
const K_HOME: i32 = 2081;
const K_END: i32 = 2082;
const K_INSERT: i32 = 2083;
const K_F1: i32 = 2090; // F1..F12 连续到 2101
const K_NUM_LOCK: i32 = 2102;
const K_NUMPAD_0: i32 = 2103; // 小键盘 0..9 连续到 2112
const K_NUMPAD_DIVIDE: i32 = 2113;
const K_NUMPAD_MULTIPLY: i32 = 2114;
const K_NUMPAD_SUBTRACT: i32 = 2115;
const K_NUMPAD_ADD: i32 = 2116;
const K_NUMPAD_DOT: i32 = 2117;
const K_NUMPAD_ENTER: i32 = 2119;

/// 统一的键位翻译。`None` 表示这个键在鸿蒙上没有对应物。
pub fn key_to_code(key: &Key) -> Option<i32> {
    use Key::*;
    let code = match key {
        Escape => K_ESCAPE,
        Return => K_ENTER,
        KpReturn => K_NUMPAD_ENTER,
        Backspace => K_DEL,
        Delete => K_FORWARD_DEL,
        Tab => K_TAB,
        Space => K_SPACE,
        Insert => K_INSERT,
        Home => K_HOME,
        End => K_END,
        PageUp => K_PAGE_UP,
        PageDown => K_PAGE_DOWN,
        LeftArrow => K_DPAD_LEFT,
        RightArrow => K_DPAD_RIGHT,
        UpArrow => K_DPAD_UP,
        DownArrow => K_DPAD_DOWN,
        CapsLock => K_CAPS_LOCK,
        NumLock => K_NUM_LOCK,
        ScrollLock => K_SCROLL_LOCK,
        PrintScreen => K_PRINT,
        Pause => K_PAUSE,

        ShiftLeft => K_SHIFT_LEFT,
        ShiftRight => K_SHIFT_RIGHT,
        ControlLeft => K_CTRL_LEFT,
        ControlRight => K_CTRL_RIGHT,
        Alt => K_ALT_LEFT,
        AltGr => K_ALT_RIGHT,
        MetaLeft => K_META_LEFT,
        MetaRight => K_META_RIGHT,

        BackQuote => K_GRAVE,
        Minus => K_MINUS,
        Equal => K_EQUALS,
        LeftBracket => K_LEFT_BRACKET,
        RightBracket => K_RIGHT_BRACKET,
        BackSlash | IntlBackslash => K_BACKSLASH,
        SemiColon => K_SEMICOLON,
        Quote => K_APOSTROPHE,
        Comma => K_COMMA,
        Dot => K_PERIOD,
        Slash => K_SLASH,

        Num0 => K_0,
        Num1 => K_1,
        Num2 => K_0 + 2,
        Num3 => K_0 + 3,
        Num4 => K_0 + 4,
        Num5 => K_0 + 5,
        Num6 => K_0 + 6,
        Num7 => K_0 + 7,
        Num8 => K_0 + 8,
        Num9 => K_9,

        KeyA => K_A,
        KeyB => K_A + 1,
        KeyC => K_A + 2,
        KeyD => K_A + 3,
        KeyE => K_A + 4,
        KeyF => K_A + 5,
        KeyG => K_A + 6,
        KeyH => K_A + 7,
        KeyI => K_A + 8,
        KeyJ => K_A + 9,
        KeyK => K_A + 10,
        KeyL => K_A + 11,
        KeyM => K_A + 12,
        KeyN => K_A + 13,
        KeyO => K_A + 14,
        KeyP => K_A + 15,
        KeyQ => K_A + 16,
        KeyR => K_A + 17,
        KeyS => K_A + 18,
        KeyT => K_A + 19,
        KeyU => K_A + 20,
        KeyV => K_A + 21,
        KeyW => K_A + 22,
        KeyX => K_A + 23,
        KeyY => K_A + 24,
        KeyZ => K_A + 25,

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

        Kp0 => K_NUMPAD_0,
        Kp1 => K_NUMPAD_0 + 1,
        Kp2 => K_NUMPAD_0 + 2,
        Kp3 => K_NUMPAD_0 + 3,
        Kp4 => K_NUMPAD_0 + 4,
        Kp5 => K_NUMPAD_0 + 5,
        Kp6 => K_NUMPAD_0 + 6,
        Kp7 => K_NUMPAD_0 + 7,
        Kp8 => K_NUMPAD_0 + 8,
        Kp9 => K_NUMPAD_0 + 9,
        KpDivide => K_NUMPAD_DIVIDE,
        KpMultiply => K_NUMPAD_MULTIPLY,
        KpMinus => K_NUMPAD_SUBTRACT,
        KpPlus => K_NUMPAD_ADD,
        KpDecimal => K_NUMPAD_DOT,

        _ => return None,
    };
    Some(code)
}

/// 字符 → (键码, 是否需要 Shift)。覆盖 ASCII 可打印区，够输入文字了。
fn char_to_key(c: char) -> Option<(i32, bool)> {
    let r = match c {
        'a'..='z' => (K_A + (c as i32 - 'a' as i32), false),
        'A'..='Z' => (K_A + (c as i32 - 'A' as i32), true),
        '0' => (K_0, false),
        '1'..='9' => (K_0 + (c as i32 - '0' as i32), false),
        ' ' => (K_SPACE, false),
        '`' => (K_GRAVE, false),
        '~' => (K_GRAVE, true),
        '-' => (K_MINUS, false),
        '_' => (K_MINUS, true),
        '=' => (K_EQUALS, false),
        '+' => (K_EQUALS, true),
        '[' => (K_LEFT_BRACKET, false),
        '{' => (K_LEFT_BRACKET, true),
        ']' => (K_RIGHT_BRACKET, false),
        '}' => (K_RIGHT_BRACKET, true),
        '\\' => (K_BACKSLASH, false),
        '|' => (K_BACKSLASH, true),
        ';' => (K_SEMICOLON, false),
        ':' => (K_SEMICOLON, true),
        '\'' => (K_APOSTROPHE, false),
        '"' => (K_APOSTROPHE, true),
        ',' => (K_COMMA, false),
        '<' => (K_COMMA, true),
        '.' => (K_PERIOD, false),
        '>' => (K_PERIOD, true),
        '/' => (K_SLASH, false),
        '?' => (K_SLASH, true),
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
        '\n' | '\r' => (K_ENTER, false),
        '\t' => (K_TAB, false),
        '\u{8}' => (K_DEL, false),
        _ => return None,
    };
    Some(r)
}

fn inject(code: i32, down: bool) {
    let rc = ffi::ohos_input_inject_key(code, down);
    if rc != 0 {
        log::warn!("ohos: inject key {} down={} rc={}", code, down, rc);
    }
}

/// 一个字符的完整「按下 → 抬起」，必要时夹一层 Shift。
fn inject_char(c: char) {
    if let Some((code, shift)) = char_to_key(c) {
        if shift {
            inject(K_SHIFT_LEFT, true);
        }
        inject(code, true);
        inject(code, false);
        if shift {
            inject(K_SHIFT_LEFT, false);
        }
    }
}

/// 被控端的 KeyEvent 入口。返回是否成功注入（仅用于日志）。
pub fn handle_key_event(ev: &KeyEvent) -> bool {
    let chr = match ev.union {
        Some(key_event::Union::Chr(c)) => c,
        _ => return false,
    };
    let down = ev.down || ev.press;
    let translate = matches!(
        ev.mode.enum_value(),
        Ok(KeyboardMode::Translate) | Ok(KeyboardMode::Legacy)
    );

    if translate {
        // unicode 只按一次：up 事件再插一遍会重复出字。
        if down {
            if let Some(c) = char::from_u32(chr) {
                inject_char(c);
                return true;
            }
        }
        return false;
    }

    // Map 模式：chr 是 evdev keycode，先还原成统一的 Key。
    let key = rdev::linux_key_from_code(chr);
    match key_to_code(&key) {
        Some(code) => {
            inject(code, down);
            true
        }
        None => {
            // 日志只在按下时打，避免按住一个键刷屏。
            if down {
                log::debug!("ohos: unmapped key {:?} (chr={})", key, chr);
            }
            false
        }
    }
}
