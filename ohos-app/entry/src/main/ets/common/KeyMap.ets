// ArkUI 的 KeyCode → RustDesk 键名。
//
// 这里有一条容易踩错的规则，先说清楚：
//
//   RustDesk 的 `input_key(name, ...)`（src/ui_session_interface.rs:899）
//   对**单字符** name 走 `Key::_Raw(chars[0])`，而 `_Raw` 在 `_input_key`
//   里同样是 `key_event.set_chr(raw)` —— 也就是被当作 **Unicode 字符码**，
//   不是 Windows 虚拟键码。所以：
//
//     "a"  → chr(97)  → 远端输入字符 a       ✅
//     "A"  → chr(65)  → 远端输入字符 A       ✅
//     "."  → chr(46)  → 远端输入字符 .       ✅
//
//   多字符 name 则必须命中 `client::KEY_MAP`（src/client.rs:5092，110 条 VK_*）。
//
// 因此本表的策略是：
//   1. 字母/数字 → 用 VK_A..VK_Z / VK_0..VK_9（走 KEY_MAP，语义最明确）
//   2. KEY_MAP 里有对应 VK_ 名的符号 → 用 VK_ 名
//   3. KEY_MAP 里**没有**的符号（句号、等号、反引号）→ 直接传那个字符，
//      走 set_chr 路径。这比硬凑一个相近的 VK 码安全得多。
//   4. 功能键 → VK_ 名
//
// 坐标注意：KeyCode 的数值来自 @ohos.multimodalInput.keyCode.d.ts，
// 这里写死数字是为了不依赖 SDK 的枚举成员名（不同 API 版本有增删），
// 每行注释里标了对应名字。

export class KeyMap {
  // 修饰键不单独发送：它们的按下状态会体现在 mouse/key 的 alt/ctrl/shift 参数里。
  // 单独发一个 VK_SHIFT 给远端，会在远端制造「粘住」的修饰键。
  static isModifier(code: number): boolean {
    return KeyMap.modifierOf(code) !== '';
  }

  // 返回 '' / 'alt' / 'ctrl' / 'shift' / 'meta'。
  // 调用方拿它去更新本地修饰状态（按下 = true，抬起 = false）。
  static modifierOf(code: number): string {
    switch (code) {
      case 2045:  // KEYCODE_ALT_LEFT
      case 2046:  // KEYCODE_ALT_RIGHT
        return 'alt';
      case 2047:  // KEYCODE_SHIFT_LEFT
      case 2048:  // KEYCODE_SHIFT_RIGHT
        return 'shift';
      case 2072:  // KEYCODE_CTRL_LEFT
      case 2073:  // KEYCODE_CTRL_RIGHT
        return 'ctrl';
      case 2076:  // KEYCODE_META_LEFT
        return 'meta';
      default:
        return '';
    }
  }

  // 返回 null 表示这个键不往远端发（修饰键、或者我们不认识的键）。
  static translate(code: number): string | null {
    const mapped: string | undefined = KeyMap.TABLE.get(code);
    if (mapped !== undefined) {
      return mapped;
    }
    return null;
  }

  private static readonly TABLE: Map<number, string> = KeyMap.buildTable();

  private static buildTable(): Map<number, string> {
    const m: Map<number, string> = new Map<number, string>();
    const put = (code: number, name: string): void => {
      m.set(code, name);
    };

    // --- 字母 --------------------------------------------------------------
    // KEYCODE_A = 2017 ... KEYCODE_Z = 2042
    const letters: string[] = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
                               'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z'];
    for (let i = 0; i < letters.length; i++) {
      put(2017 + i, 'VK_' + letters[i]);
    }

    // --- 数字 --------------------------------------------------------------
    // KEYCODE_0 = 2000 ... KEYCODE_9 = 2009
    for (let i = 0; i < 10; i++) {
      put(2000 + i, 'VK_' + i.toString());
    }

    // --- 符号（KEY_MAP 里有的）--------------------------------------------
    put(2043, 'VK_COMMA');        // ,
    put(2064, 'VK_SLASH');        // /
    put(2062, 'VK_SEMICOLON');    // ;
    put(2063, 'VK_QUOTE');        // '
    put(2059, 'VK_LBRACKET');     // [
    put(2060, 'VK_RBRACKET');     // ]
    put(2061, 'VK_BACKSLASH');    // \
    put(2057, 'VK_MINUS');        // -

    // --- 符号（KEY_MAP 里没有，直接传字符）--------------------------------
    // 上游 KEY_MAP 缺 period / equals / grave 这三条，凑 VK 码会送错键，
    // 传字符反而一定能对（见文件头的说明）。
    put(2044, '.');               // KEYCODE_PERIOD
    put(2058, '=');               // KEYCODE_EQUALS
    put(2056, '`');               // KEYCODE_GRAVE

    // --- 编辑键 -----------------------------------------------------------
    put(2054, 'VK_ENTER');        // KEYCODE_ENTER
    put(2055, 'VK_BACK');         // KEYCODE_DEL（Backspace）
    put(2071, 'VK_DELETE');       // KEYCODE_FORWARD_DEL
    put(2049, 'VK_TAB');          // KEYCODE_TAB
    put(2050, 'VK_SPACE');        // KEYCODE_SPACE
    put(2070, 'VK_ESCAPE');       // KEYCODE_ESCAPE
    put(2083, 'VK_INSERT');       // KEYCODE_INSERT
    put(2081, 'VK_HOME');         // KEYCODE_MOVE_HOME
    put(2082, 'VK_END');          // KEYCODE_MOVE_END
    put(2068, 'VK_PRIOR');        // KEYCODE_PAGE_UP
    put(2069, 'VK_NEXT');         // KEYCODE_PAGE_DOWN
    put(2080, 'VK_PAUSE');        // KEYCODE_BREAK
    put(2079, 'VK_SNAPSHOT');     // KEYCODE_SYSRQ
    put(2074, 'VK_CAPITAL');      // KEYCODE_CAPS_LOCK
    put(2075, 'VK_SCROLL');       // KEYCODE_SCROLL_LOCK
    put(2067, 'VK_MENU');         // KEYCODE_MENU（右键菜单键）

    // --- 方向键 -----------------------------------------------------------
    put(2012, 'VK_UP');           // KEYCODE_DPAD_UP
    put(2013, 'VK_DOWN');         // KEYCODE_DPAD_DOWN
    put(2014, 'VK_LEFT');         // KEYCODE_DPAD_LEFT
    put(2015, 'VK_RIGHT');        // KEYCODE_DPAD_RIGHT

    // --- 功能键 -----------------------------------------------------------
    // KEYCODE_F1 = 2090 ... KEYCODE_F12 = 2101
    for (let i = 0; i < 12; i++) {
      put(2090 + i, 'VK_F' + (i + 1).toString());
    }

    // --- 数字键盘 ---------------------------------------------------------
    // 注意 RustDesk 叫 VK_NUMPAD0，没有下划线。
    for (let i = 0; i < 10; i++) {
      put(2103 + i, 'VK_NUMPAD' + i.toString());
    }
    put(2113, 'VK_DIVIDE');       // KEYCODE_NUMPAD_DIVIDE
    put(2114, 'VK_MULTIPLY');     // KEYCODE_NUMPAD_MULTIPLY
    put(2115, 'VK_SUBTRACT');     // KEYCODE_NUMPAD_SUBTRACT
    put(2116, 'VK_ADD');          // KEYCODE_NUMPAD_ADD
    put(2117, 'VK_DECIMAL');      // KEYCODE_NUMPAD_DOT
    put(2119, 'VK_ENTER');        // KEYCODE_NUMPAD_ENTER

    return m;
  }
}
