// Rust 核心的唯一入口。ArkTS 侧只通过这个类碰 native，不直接 import libentry.so。
//
// 这样做的原因：native 那一层的所有函数都是「返回 int32 错误码」的 C 风格，
// 而且有些调用有顺序要求（init 必须最先、onEvent 必须在 init 之前才能收到
// 早期事件）。把这些约束收在一个类里，页面代码就只面对干净的方法。

import native from 'libentry.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3200;
const TAG: string = 'RustDeskArk';

// --- 状态结构 --------------------------------------------------------------
//
// 字段名与 src/platform/ohos/ui_handler.rs 的 state_json 严格一致。
// 注意 display 用 w/h，而 displays 数组用 width/height —— 这不是笔误：
// 上游 set_display(x,y,w,h,...) 的参数就叫 w/h，而 DisplayInfo 结构体
// 的字段叫 width/height。我们如实反映了上游这两个不同的形状。

export interface DisplayRect {
  x: number;
  y: number;
  w: number;
  h: number;
  cursor_embedded?: boolean;
  scale?: number;
}

export interface RemoteDisplay {
  x: number;
  y: number;
  width: number;
  height: number;
  cursor_embedded: boolean;
  scale: number;
}

export interface CursorPos {
  x: number;
  y: number;
  embedded?: boolean;
}

export interface SessionState {
  connected?: boolean;
  secured?: boolean;
  direct?: boolean;
  stream_type?: string;
  peer_id?: string;
  display?: DisplayRect;
  scale?: number;
  cursor?: CursorPos;
  block_input?: boolean;
  displays?: RemoteDisplay[];
}

// --- 事件 ------------------------------------------------------------------

export interface UiEvent {
  event: string;
  data?: Object;
}

export type UiListener = (ev: UiEvent) => void;

// 常用事件的载荷类型。用的时候 `ev.data as DisplayEventData` 转。
export interface DisplayEventData {
  x: number;
  y: number;
  w: number;
  h: number;
  cursor_embedded: boolean;
  scale: number;
}

export interface ConnectedEventData {
  conn_type: string;
}

export interface CloseEventData {
  reason: string;
}

export interface MsgboxEventData {
  msgtype: string;
  title: string;
  text: string;
  link?: string;
  retry?: boolean;
}

export interface BlockInputEventData {
  on: boolean;
}

export interface ChatEventData {
  text: string;
}

// --- 鼠标掩码 --------------------------------------------------------------
// 与 src/common.rs 的 MOUSE_TYPE_* / MOUSE_BUTTON_* 一致。
//
// 编码规则是 `(button << 3) | type`，见 src/client.rs:4397：
//     let left_down = MOUSE_BUTTON_LEFT << 3 | MOUSE_TYPE_DOWN;   // = 9
// 所以**不能**直接把常量或起来用 —— 那样 type 和 button 的低位会打架。
// 统一走 mouseMask()。
export class MouseType {
  static readonly MOVE: number = 0;
  static readonly DOWN: number = 1;
  static readonly UP: number = 2;
  static readonly WHEEL: number = 3;
  static readonly TRACKPAD: number = 4;
  static readonly MOVE_RELATIVE: number = 5;
}

export class MouseButton {
  static readonly NONE: number = 0;
  static readonly LEFT: number = 0x01;
  static readonly RIGHT: number = 0x02;
  static readonly WHEEL: number = 0x04;
  static readonly BACK: number = 0x08;
  static readonly FORWARD: number = 0x10;
}

export function mouseMask(button: number, type: number): number {
  return (button << 3) | type;
}

// --- 主类 ------------------------------------------------------------------

export class RustDesk {
  private static listeners: UiListener[] = [];
  private static initialized: boolean = false;
  private static lastErrorText: string = '';

  // 必须在任何其他调用之前执行。
  // appDir 用 UIAbility 的 context.filesDir（Rust 侧要在这里建配置、日志目录）。
  static init(appDir: string): boolean {
    if (RustDesk.initialized) {
      return true;
    }
    // 先挂事件回调再 init：Rust 在 init 里就会发第一条事件
    // （日志探针 / 设备形态），晚挂会丢。丢了也不致命，但排查时少一条线索。
    native.onEvent((json: string): void => {
      RustDesk.dispatch(json);
    });

    const rc: number = native.init(appDir);
    if (rc !== 0) {
      RustDesk.lastErrorText = native.lastError() ?? `init failed rc=${rc}`;
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', RustDesk.lastErrorText);
      return false;
    }
    RustDesk.initialized = true;
    hilog.info(DOMAIN, TAG, 'core initialized, abi=%{public}d', native.abiVersion());
    return true;
  }

  static isInitialized(): boolean {
    return RustDesk.initialized;
  }

  static getLastError(): string {
    const e: string | null = native.lastError();
    return e ?? RustDesk.lastErrorText;
  }

  // --- 事件订阅 -----------------------------------------------------------

  static on(listener: UiListener): void {
    RustDesk.listeners.push(listener);
  }

  static off(listener: UiListener): void {
    const i: number = RustDesk.listeners.indexOf(listener);
    if (i >= 0) {
      RustDesk.listeners.splice(i, 1);
    }
  }

  private static dispatch(json: string): void {
    let ev: UiEvent;
    try {
      ev = JSON.parse(json) as UiEvent;
    } catch (e) {
      // 事件是 UI 的唯一数据源，解析失败只可能是 Rust 侧 bug。
      // 不抛异常：一条坏消息不该让整个会话崩掉。
      hilog.error(DOMAIN, TAG, 'bad event json: %{public}s', json);
      return;
    }
    // 复制一份再遍历：监听器里可能会 off 自己。
    const snapshot: UiListener[] = RustDesk.listeners.slice();
    for (const l of snapshot) {
      try {
        l(ev);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'listener threw on event %{public}s', ev.event);
      }
    }
  }

  // --- 会话 ---------------------------------------------------------------

  static startSession(peerId: string, password: string, forceRelay: boolean): number {
    return native.sessionStart(peerId, password, forceRelay ? 1 : 0);
  }

  static closeSession(): void {
    native.sessionClose();
  }

  static refresh(display: number): void {
    native.sessionRefresh(display);
  }

  static state(): SessionState {
    const json: string | null = native.stateJson();
    if (json === null || json.length === 0) {
      return {};
    }
    try {
      return JSON.parse(json) as SessionState;
    } catch (e) {
      return {};
    }
  }

  static switchDisplay(index: number): number {
    return native.switchDisplay(index);
  }

  // --- 服务器配置 ---------------------------------------------------------

  static getConfig(): ServerConfig {
    const cfg: ServerConfig = new ServerConfig();
    const json: string | null = native.configJson();
    if (json === null || json.length === 0) {
      return cfg;
    }
    try {
      // Rust 侧保证这五个键一定存在，所以不需要逐字段判空。
      const w: Record<string, string> = JSON.parse(json) as Record<string, string>;
      cfg.idServer = w['custom-rendezvous-server'] ?? '';
      cfg.relayServer = w['relay-server'] ?? '';
      cfg.apiServer = w['api-server'] ?? '';
      cfg.key = w['key'] ?? '';
      cfg.effectiveServer = w['effective-rendezvous-server'] ?? '';
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'bad config json: %{public}s', json);
    }
    return cfg;
  }

  // 返回 0 成功。写盘由 Rust 侧的 Config 负责（config 文件在同一目录下）。
  // 注意：改完服务器地址不需要重启应用 —— 连接时会重新读 Config。
  static saveConfig(cfg: ServerConfig): number {
    const w: Record<string, string> = {
      'custom-rendezvous-server': cfg.idServer.trim(),
      'relay-server': cfg.relayServer.trim(),
      'api-server': cfg.apiServer.trim(),
      'key': cfg.key.trim(),
    };
    return native.configSet(JSON.stringify(w));
  }

  static ctrlAltDel(): number {
    return native.ctrlAltDel();
  }

  static sendChat(text: string): number {
    return native.sendChat(text);
  }

  // --- 输入 ---------------------------------------------------------------

  static mouse(mask: number, x: number, y: number, mods: Modifiers): number {
    return native.mouse(mask, x, y, mods.alt ? 1 : 0, mods.ctrl ? 1 : 0,
                        mods.shift ? 1 : 0, mods.command ? 1 : 0);
  }

  static key(name: string, down: boolean, mods: Modifiers): number {
    return native.key(name, down ? 1 : 0, 0, mods.alt ? 1 : 0, mods.ctrl ? 1 : 0,
                      mods.shift ? 1 : 0, mods.command ? 1 : 0);
  }

  // 字符输入（软键盘）。走单字符路径，Rust 侧会当作 Unicode 字符处理。
  static char(ch: string, mods: Modifiers): number {
    if (ch.length === 0) {
      return 0;
    }
    // 一次 press：down + up 由 Rust 侧的 press 标志完成。
    return native.key(ch, 0, 1, mods.alt ? 1 : 0, mods.ctrl ? 1 : 0,
                      mods.shift ? 1 : 0, mods.command ? 1 : 0);
  }

  // --- 渲染控制 -----------------------------------------------------------

  static setRenderActive(active: boolean): void {
    native.setRenderActive(active);
  }

  static displaysSync(): number {
    return native.displaysSync();
  }

  static logProbe(msg: string): void {
    native.logProbe(msg);
  }
}

// --- 服务器配置 ------------------------------------------------------------
//
// 键名与 Rust 侧 REMOTE_SERVER_KEYS 一致（也和上游桌面端设置页的字符串一致）。
// 这里把带横线的 CLI 风格键名挡在 RustDesk 内部，UI 只面对驼峰字段 ——
// 页面里出现 cfg['custom-rendezvous-server'] 这种东西没有必要。
//
// 「留空」一律表示用默认值：
//   relayServer 空 → 用 ID 服务器下发的地址
//   apiServer   空 → http://<ID服务器>:21114
export class ServerConfig {
  // ID / Rendezvous 服务器，形如 192.168.1.10 或 rd.example.com:21116
  idServer: string = '';
  relayServer: string = '';
  apiServer: string = '';
  // 自建服务器公钥（id_ed25519.pub 的全部内容，单行）
  key: string = '';
  // 实际生效的地址，只读，由 Rust 侧算出来（可能来自编译期内置的定制服务器）
  effectiveServer: string = '';
}

export class Modifiers {
  alt: boolean = false;
  ctrl: boolean = false;
  shift: boolean = false;
  command: boolean = false;

  reset(): void {
    this.alt = false;
    this.ctrl = false;
    this.shift = false;
    this.command = false;
  }
}
