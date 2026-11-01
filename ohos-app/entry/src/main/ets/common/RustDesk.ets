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
  // Rust 侧（ui_handler::msgbox）发出来的字段名就是 `type`。
  // 之前这里写成 msgtype，运行时永远是 undefined，所有弹框类型都匹配不上：
  // 密码框不弹、未加密确认框不弹，连接就停在原地。
  type?: string;
  title: string;
  text: string;
  link?: string;
  retry?: boolean;
}

export interface BlockInputEventData {
  on: boolean;
}

// 质量监视器数据（ui_handler::update_quality_status 发出，1 秒左右一条）。
// 空串 / 0 表示该项暂无数据，UI 跳过不显示。
export interface QualityStatusEventData {
  speed: string;          // 网速，如 "12.3 Mbps"
  fps: number;
  delay: number;          // 往返延迟 ms
  target_bitrate: number; // 目标码率 kbit/s
  codec_format: string;   // "VP9" / "AV1" / "H264"…
  chroma: string;         // "4:2:0" / "4:4:4"
}

export interface CursorPositionEventData {
  x: number; // 远端画面坐标
  y: number;
}

export interface ChatEventData {
  text: string;
}

// --- 文件传输事件 ----------------------------------------------------------
//
// 全部由 src/platform/ohos/ui_handler.rs 发出。id 的语义：
//   id > 0  传输任务（下载/上传），进度、完成、出错都带这个 id；
//   id == 0 单纯的「浏览目录」回包（read_remote_dir 没有任务）；
//   其它  端上新建/删除/改名操作的回执（见 filesMkdir 的返回值）。

export interface FileEntryData {
  name: string;
  // 0=Dir 1=File 2=Symlink（protobuf FileType 的数值）
  entry_type: number;
  is_hidden: boolean;
  size: number;
  modified_time: number; // Unix 秒
}

export interface FolderFilesEventData {
  id: number;
  path: string;
  is_local: boolean;
  // true 表示这条只是「任务里有几个文件」的统计，不是目录内容，别拿去渲染列表。
  only_count: boolean;
  entries: FileEntryData[];
}

export interface JobProgressEventData {
  id: number;
  file_num: number;
  speed: number;         // 字节/秒
  finished_size: number; // 已传字节
}

export interface JobErrorEventData {
  id: number;
  err: string;
  file_num: number;
}

export interface JobDoneEventData {
  id: number;
  file_num: number;
}

export interface OverrideConfirmEventData {
  id: number;
  file_num: number;
  to: string;
  is_upload: boolean;
  is_identical: boolean;
}

export interface ConfirmDeleteEventData {
  id: number;
  index: number;
  name: string;
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

  // 提交登录密码（密码弹窗「确定」时调用）。username/osPassword 预留给
  // 「对端停在 OS 登录界面」的场景，平时传空串。
  static login(password: string, remember: boolean, username: string = '',
               osPassword: string = ''): number {
    return native.sessionLogin(password, username, osPassword, remember ? 1 : 0);
  }

  static refresh(display: number): void {
    native.sessionRefresh(display);
  }

  // 回应「未加密连接」警告。不回应的话上游的 confirm_insecure_connection
  // 会一直 await，连接停在那里不动（黑屏、也不弹密码框）。
  static continueInsecure(accept: boolean): number {
    return native.sessionContinueInsecure(accept ? 1 : 0);
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
      // Rust 侧保证这些键一定存在，所以不需要逐字段判空。
      const w: Record<string, string> = JSON.parse(json) as Record<string, string>;
      cfg.idServer = w['custom-rendezvous-server'] ?? '';
      cfg.relayServer = w['relay-server'] ?? '';
      cfg.apiServer = w['api-server'] ?? '';
      cfg.key = w['key'] ?? '';
      cfg.effectiveServer = w['effective-rendezvous-server'] ?? '';
      // 视图样式 / 图像质量用的是我们自己的全局默认键（带 ohos-default- 前缀）。
      // 不能直接叫 "view-style"：那是 LoginConfigHandler 的 options map 键，
      // 语义完全不同，混用会导致「改了不生效」且极难定位。
      cfg.viewStyle = w['ohos-default-view-style'] ?? '';
      cfg.imageQuality = w['ohos-default-image-quality'] ?? '';
      cfg.showRemoteCursor = (w['show-remote-cursor'] ?? '') === 'Y';
      cfg.disableAudio = (w['disable-audio'] ?? '') === 'Y';
      cfg.forceAlwaysRelay = (w['force-always-relay'] ?? '') === 'Y';
      // 网络项的值是 "Y" / "N"，**空串表示按默认**（连公共服务器默认开，
      // 自建服务器默认关，见 Rust 侧 get_local_option）。所以这里只有明确读到
      // "N" 才算关，其余一律按开显示 —— 反过来会把「没设过」显示成关闭。
    cfg.disableUdp = (w['disable-udp'] ?? '') === 'Y';
    cfg.allowWebsocket = (w['allow-websocket'] ?? '') !== 'N';
      // 本机身份（首页「你的设备」卡片用）。由 Rust 侧额外给出，不在
      // REMOTE_SERVER_KEYS 里，也不参与 saveConfig（是只读的）。
      cfg.id = w['id'] ?? '';
      cfg.temporaryPassword = w['temporary-password'] ?? '';
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
      'ohos-default-view-style': cfg.viewStyle,
      'ohos-default-image-quality': cfg.imageQuality,
      'show-remote-cursor': cfg.showRemoteCursor ? 'Y' : '',
      'disable-audio': cfg.disableAudio ? 'Y' : '',
      'force-always-relay': cfg.forceAlwaysRelay ? 'Y' : '',
      // 网络项写 "Y"/"N"：空串是「按默认」，但 UI 上已经把默认值解析成布尔了，
      // 这里显式写死，避免「用户以为关了其实还是默认」。
      // 四个 punch 开关不在这里 —— 它们的读取方是 LocalConfig，
      // 由 Settings.ets 调 localOptionSetBool 单独写。
      'disable-udp': cfg.disableUdp ? 'Y' : 'N',
      'allow-websocket': cfg.allowWebsocket ? 'Y' : 'N',
    };
    return native.configSet(JSON.stringify(w));
  }

  // 代理设置。存在 Config2.socks（不是 options map），走专用 ABI。
  // 密码落盘时 Rust 侧会加密，这里拿到的是明文。
  static proxy(): Record<string, string> {
    const json: string | null = native.proxyJson();
    if (json === null || json.length === 0) {
      return {};
    }
    try {
      return (JSON.parse(json) as Record<string, string>) ?? {};
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'bad proxy json: %{public}s', json);
      return {};
    }
  }

  // 写代理设置。三个字段一起写；全空表示「不使用代理」。
  static setProxy(proxy: string, username: string, password: string): number {
    const w: Record<string, string> = {
      'proxy': proxy.trim(),
      'username': username.trim(),
      'password': password.trim(),
    };
    return native.proxySet(JSON.stringify(w));
  }

  // 读单个配置项的原始值。键不在白名单里会得到空串。
  static optionGet(key: string): string {
    return native.optionGet(key) ?? '';
  }

  // 写单个配置项。返回 0 成功。传空串 = 删除该项、回到默认。
  static optionSet(key: string, value: string): number {
    return native.optionSet(key, value);
  }

  // 布尔型配置项：读到 "N" 才算关；空串是「没设过」，按默认（开）处理。
  //
  // 这里显式写类名而不是 `this`：ArkTS 禁止在静态（stand-alone）函数里用
  // `this`（arkts-no-standalone-this），会直接编译失败。
  static optionGetBool(key: string): boolean {
    return RustDesk.optionGet(key) !== 'N';
  }

  static optionSetBool(key: string, on: boolean): number {
    return RustDesk.optionSet(key, on ? 'Y' : 'N');
  }

  // --- 本地配置项（LocalConfig）-------------------------------------------
  //
  // 与全局 Config 的区别不是形式上的：打洞开关这类项的读取方是 common.rs 的
  // get_tcp_punch_enabled() 等函数，它们读 LocalConfig。写错存储位置的后果是
  // 「设置里改了、行为没变」，而配置文件里又确实存着值 —— 排查成本高，
  // 所以这里与全局接口分开命名，调用处一眼能看出走哪条路。

  static localOptionGet(key: string): string {
    return native.localOptionGet(key) ?? '';
  }

  static localOptionSet(key: string, value: string): number {
    return native.localOptionSet(key, value);
  }

  // 本地布尔项：空串按默认（开）处理，只有明确 "N" 才算关。
  // 打洞类选项在连自建服务器时默认是关的（见 common.rs get_local_option），
  // 这里读取时保持与之一致的语义。
  static localOptionGetBool(key: string, defaultValue: boolean): boolean {
    const v: string = RustDesk.localOptionGet(key);
    if (v.length === 0) {
      return defaultValue;
    }
    return v !== 'N';
  }

  static localOptionSetBool(key: string, on: boolean): number {
    return RustDesk.localOptionSet(key, on ? 'Y' : 'N');
  }

  // --- ID 服务器连接状态 ---------------------------------------------------
  //
  // 上游的在线状态来自守护进程的 IPC 上报，鸿蒙端没有常驻服务，
  // 所以由 Rust 侧的后台看门狗线程自己探测（对 21116 做带超时的 TCP 连接）。
  //
  // 这里的常量与 `entry.rs` 的 SERVER_STATUS_* 一一对应。数值沿用上游
  // `ConnectStatus` 的定义（-1 失败 / 0 连接中 / 1 就绪），以后若接上
  // 守护进程那条路，本函数不用改。
  static readonly SERVER_STATUS_FAILED: number = -1;
  static readonly SERVER_STATUS_CONNECTING: number = 0;
  static readonly SERVER_STATUS_READY: number = 1;

  /// 当前生效 ID 服务器的连接状态：见上面三个常量。不阻塞。
  static serverStatus(): number {
    return native.serverStatus();
  }

  // --- 被控端：远程协助 -----------------------------------------------------
  //
  // 只做薄封装：状态机在 Rust 的 entry.rs（HOST_RUNNING + 采集开关），
  // ArkTS 侧不缓存，避免两处状态不一致。

  /** 本机是否支持被控（仅 2in1）。 */
  static hostSupported(): boolean {
    return native.hostSupported() === 1;
  }

  /** 开启远程协助。返回 0 成功，负数失败（细节见 lastErrorText）。 */
  static hostStart(): number {
    return native.hostStart();
  }

  static hostStop(): void {
    native.hostStop();
  }

  static hostRunning(): boolean {
    return native.hostState() === 1;
  }

  /** 当前被控连接数。>0 说明有人正在控制本机。 */
  static hostSessions(): number {
    return native.hostSessions();
  }

  /** 被控端回话：把文字发给正在控制本机的主控。 */
  static hostSendChat(text: string): boolean {
    return native.hostSendChat(text) === 0;
  }

  /** 注入授权：0 未授权 / 1 授权中 / 2 已授权。 */
  static injectionStatus(): number {
    return native.injectionStatus();
  }

  /** 触发系统的「允许远程控制」弹窗，异步给结果。 */
  static requestInjection(): number {
    return native.requestInjection();
  }

  static ctrlAltDel(): number {
    return native.ctrlAltDel();
  }

  // --- 本机身份 / 最近会话（首页用）---------------------------------------

  // 刷新一次性密码。刷新后必须重新 getConfig() 才能拿到新值。
  static updateTemporaryPassword(): void {
    native.updateTempPassword();
  }

  // 设置固定密码。传空串 = 清除固定密码（回到只用一次性密码）。
  // 返回 0 成功，非 0 表示被配置策略拒绝（例如 disable-change-permanent-password）。
  static setPermanentPassword(pw: string): number {
    return native.setPermanentPassword(pw);
  }

  // 最近连接过的对端，按最后连接时间倒序。解析失败返回空数组而不是抛异常 ——
  // 首页不该因为一条坏数据就白屏。
  static peers(): PeerInfo[] {
    const json: string | null = native.peersJson();
    if (json === null || json.length === 0) {
      return [];
    }
    try {
      const arr: PeerInfo[] = JSON.parse(json) as PeerInfo[];
      return arr ?? [];
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'bad peers json: %{public}s', json);
      return [];
    }
  }

  // 收藏列表整体写回（传完整列表，不是增量）。
  static storeFav(ids: string[]): number {
    return native.storeFav(JSON.stringify(ids));
  }

  static sendChat(text: string): number {
    return native.sendChat(text);
  }

  // --- 会话操作（Android 底栏 ⋮「更多」菜单）-------------------------------
  //
  // 这一组对应 Android `toolbarControls` 里的菜单项，全部「发完就忘」：
  // 返回 0 只代表消息进了 io_loop 的队列，远端做没做成要看后续事件。
  // 所以调用方不要拿返回值当「执行成功」弹 toast。

  static lockScreen(): number {
    return native.lockScreen();
  }

  static restartRemote(): number {
    return native.restartRemote();
  }

  // activate：发完立刻回车。Android 的 handleOsPasswordAction 就是这个语义。
  static inputOsPassword(pw: string, activate: boolean): number {
    return native.inputOsPassword(pw, activate ? 1 : 0);
  }

  static elevateDirect(): number {
    return native.elevateDirect();
  }

  static elevateWithLogon(username: string, password: string): number {
    return native.elevateWithLogon(username, password);
  }

  static recordScreen(start: boolean): number {
    return native.recordScreen(start ? 1 : 0);
  }

  static isRecording(): boolean {
    return native.isRecording() !== 0;
  }

  static toggleOption(name: string): number {
    return native.toggleOption(name);
  }

  // 对端平台（"Windows" / "Linux" / "MacOS" / "Android"）。没会话时返回空串，
  // 菜单项的可用性判断据此做（见 SessionPage 的 moreMenu）。
  static peerPlatform(): string {
    const p: string | null = native.peerPlatform();
    return p ?? '';
  }

  // 核心版本号，「关于」页用。取不到时给个空串让页面自己兜底。
  static coreVersion(): string {
    const v: string | null = native.version();
    return v ?? '';
  }

  // --- Android 被控端专用键 ------------------------------------------------
  //
  // 这些键没有 VK_ 名字，服务端只认 USB HID usage。HID_* 常量与 Rust 侧
  // `_handle_key_flutter_simulation` 的表一一对应，写成别的会被静默丢弃。

  static readonly HID_MUTE: number = 0x007f;
  static readonly HID_VOLUME_UP: number = 0x0080;
  static readonly HID_VOLUME_DOWN: number = 0x0081;
  static readonly HID_POWER: number = 0x0066;

  // 发一次 HID 键。down 之后必须再发一次 up，否则对端会一直「按住」。
  private static hidKey(usbHid: number, down: boolean): number {
    return native.hidKey(usbHid, down ? 1 : 0);
  }

  // 完整按一下（按下 → 100ms → 抬起）。对端要长按语义时不要用这个。
  //
  // setTimeout 的回调里不能写 `this`（ArkTS 的 arkts-no-standalone-this），
  // 所以这里显式写类名——静态方法里的 this 本来就只是类本身。
  static tapHidKey(usbHid: number): void {
    RustDesk.hidKey(usbHid, true);
    setTimeout(() => { RustDesk.hidKey(usbHid, false); }, 100);
  }

  // --- 输入 ---------------------------------------------------------------

  static mouse(mask: number, x: number, y: number, mods: Modifiers): number {
    return native.mouse(mask, x, y, mods.alt ? 1 : 0, mods.ctrl ? 1 : 0,
                        mods.shift ? 1 : 0, mods.command ? 1 : 0);
  }

  static key(name: string, down: boolean, mods: Modifiers): number {
    // 上游 KeyEvent 的语义（src/ui_session_interface.rs::_input_key）：
    //   press=1 → KeyEvent.press（「按下」）
    //   down=1  → KeyEvent.down（Linux 服务端才认）
    // 服务端 connection.rs 的 KeyEvent 分支里 `is_press = me.press`
    // （Windows/macOS），之前传 down=1/press=0，服务端把**每一个键**
    // 都当成「抬起」处理 → 键盘完全没反应。Ctrl+Alt+Del 一直有效是
    // 因为服务端在 press 判断之前就拦截了 CtrlAltDel 这个特殊键（SAS）。
    // 按下一律发 press=1，抬起发 0/0，Windows/Linux/macOS 通吃。
    return native.key(name, 0, down ? 1 : 0, mods.alt ? 1 : 0, mods.ctrl ? 1 : 0,
                      mods.shift ? 1 : 0, mods.command ? 1 : 0);
  }

  // 文字输入（软键盘）。整段发给服务端，服务端按 KeyEvent.seq 逐字符注入。
  // 为什么不用 char() 逐键发：逐键要调用方自己算 Shift、大写、非 ASCII 映射，
  // 而且服务端对「只有 press 没有 down」的 Chr 事件在 Windows 上什么都不打
  // （input_service::process_chr 只在 down 时注入）。seq 通道没有这些坑。
  static text(value: string): number {
    if (value.length === 0) {
      return 0;
    }
    return native.text(value);
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

  // --- 文件传输 -----------------------------------------------------------
  //
  // 与远程桌面是**两个会话类型**：filesStart 建的是 FileTransfer 连接，
  // 对端不会推视频，只会跑文件协议（对方屏幕上会弹「请求文件传输」）。
  // 所以进文件管理器前不需要（也不能）先 startSession。
  //
  // 目录列表不走返回值：远端目录要等对端回包，统一通过 folder_files 事件。

  static filesStart(peerId: string, password: string, forceRelay: boolean): number {
    return native.filesStart(peerId, password, forceRelay ? 1 : 0);
  }

  static filesList(path: string, includeHidden: boolean): number {
    return native.filesList(path, includeHidden ? 1 : 0);
  }

  static filesMkdir(path: string): number {
    return native.filesMkdir(path);
  }

  static filesRename(path: string, newName: string): number {
    return native.filesRename(path, newName);
  }

  static filesRemove(path: string, isDir: boolean): number {
    return native.filesRemove(path, isDir ? 1 : 0);
  }

  static filesDownload(remotePath: string, localTo: string): number {
    return native.filesDownload(remotePath, localTo);
  }

  static filesUpload(localPath: string, remoteDir: string): number {
    return native.filesUpload(localPath, remoteDir);
  }

  static filesCancel(id: number): void {
    native.filesCancel(id);
  }

  static filesResume(id: number, isRemote: boolean): void {
    native.filesResume(id, isRemote ? 1 : 0);
  }

  static filesConfirm(id: number, fileNum: number, needOverride: boolean,
                      remember: boolean, isUpload: boolean): void {
    native.filesConfirm(id, fileNum, needOverride ? 1 : 0, remember ? 1 : 0,
      isUpload ? 1 : 0);
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
// 最近会话里的一项。字段与 Rust 侧 rustdesk_ohos_peers_json 的输出一致。
export interface PeerInfo {
  id: string;
  ts: number;   // 最后连接时间，Unix 秒
  fav: boolean; // 是否已收藏
}

export class ServerConfig {
  // ID / Rendezvous 服务器，形如 192.168.1.10 或 rd.example.com:21116
  idServer: string = '';
  relayServer: string = '';
  apiServer: string = '';
  // 自建服务器公钥（id_ed25519.pub 的全部内容，单行）
  key: string = '';
  // 实际生效的地址，只读，由 Rust 侧算出来（可能来自编译期内置的定制服务器）
  effectiveServer: string = '';
  // 本机 ID 与一次性密码，只读（首页「你的设备」卡片）。不参与 saveConfig。
  id: string = '';
  temporaryPassword: string = '';

  // --- 连接默认选项（上游存 per-peer，这里用全局值兜底） ---
  // view-style: original=原始大小 adaptive=自适应窗口
  viewStyle: string = '';
  // image-quality: best / balanced / low / original
  imageQuality: string = '';
  showRemoteCursor: boolean = false;
  disableAudio: boolean = false;
  forceAlwaysRelay: boolean = false;

  // --- 网络 / 打洞（Android 设置页同款）---
  // 这些项在 Rust 侧是 "Y"/"N"，空串＝按默认；读的时候已经归一化成布尔了
  // （见 getConfig）。写的时候一律显式写 "Y"/"N"。
  disableUdp: boolean = false;
  enableTcpPunch: boolean = true;
  enableUdpPunch: boolean = true;
  enableIpv6Punch: boolean = true;
  enableWebrtc: boolean = true;
  allowWebsocket: boolean = true;
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
