import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  RustDesk, UiEvent, DisplayEventData, CloseEventData,
  BlockInputEventData, MsgboxEventData, SessionState, RemoteDisplay,
  QualityStatusEventData, CursorPositionEventData,
  Modifiers, MouseType, MouseButton, mouseMask
} from '../common/RustDesk';
import { KeyMap } from '../common/KeyMap';

// 会话页：XComponent 负责显示（帧由 C++ 渲染线程直接写 Surface），
// 这一页只做三件事 —— 手势换算成鼠标事件、物理键盘换算成 VK 键名、UI 浮层。
//
// 画面为什么不在这里画：
//   1080p 一帧 8MB，走 napi 传 ArrayBuffer 每帧都要跨语言拷贝，
//   30fps 就是 250MB/s，手机上直接卡死。所以帧完全不过 ArkTS，
//   由 renderer.cpp 从 Rust 帧槽直写 XComponent 的 Surface。

class Position {
  x: number = 0;
  y: number = 0;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

// 「更多」菜单里的一行。
//
// 为什么要把菜单项做成数据再让 ForEach 渲染，而不是在 @Builder 里 if/else 堆
// Text：Android 的 toolbarControls 是按**对端平台**动态拼的（Android 被控端
// 有返回/Home/音量，Windows 才有锁定输入…），用数据写可以在普通方法里算，
// builder 里只负责渲染 —— ArkTS 的 @Builder 里不允许写普通语句。
class MoreItem {
  label: string;
  // 右侧补充说明（比如录屏的「录制中」），空串表示不显示。
  hint: string;
  // 危险操作（重启远端）用警示色。
  danger: boolean;
  act: () => void;

  constructor(label: string, act: () => void, hint: string = '', danger: boolean = false) {
    this.label = label;
    this.act = act;
    this.hint = hint;
    this.danger = danger;
  }
}

const DOMAIN: number = 0x3200;
const TAG: string = 'RustDeskSession';

const LONG_PRESS_MS: number = 500;
const MOVE_THRESHOLD_PX: number = 6;
// 「自动补抬起」的兜底时间。按下后如果迟迟收不到 Up/Cancel（某些模拟器上
// 按下就把指针甩出窗口，后续事件流整个断掉，实测日志里只有 type=0 没有
// type=1），到点就替用户发一次左键抬起。
// 比 LONG_PRESS_MS 略长，保证长按先判定；真实 Up 一到就取消，正常情况下
// 这个定时器永远不会触发。
const AUTO_UP_MS: number = 620;
// 已经进入拖动后，把兜底时间放宽：手停在中途思考一两秒不该被抬起打断。
const AUTO_UP_DRAG_MS: number = 1500;
// 手指表里的记录超过这么久没更新就认为该手指已经离开（抬手事件会丢）。
const FINGER_STALE_MS: number = 2500;
// RustDesk 鼠标事件 type：0=MOVE 1=DOWN 2=UP 3=WHEEL（mask = (button<<3)|type）。
// mask=0 即「无按键的移动」，服务端收到后只移动光标不按键。
const MOUSE_TYPE_MOVE: number = 0;
// 双指滚动：累计到这个像素数才发一次滚轮，避免一次滑动刷出几十个事件。
const WHEEL_STEP_PX: number = 32;

// ArkUI 鼠标枚举的数值常量。
// 为什么不直接写 MouseButton.Left：本文件从 RustDesk 导入了同名的
// MouseButton 类（RustDesk 的按钮位掩码），它会遮蔽 ArkUI 的全局枚举，
// 写 .Left 会被解析成我们的类 → 编译期报「不存在该成员」。
// MouseAction：Press=1 Release=2 Move=3 Hover=4
// MouseButton：None=0 Left=1 Right=2 Middle=3 Back=4 Forward=5
const ARK_ACTION_PRESS: number = 1;
const ARK_ACTION_RELEASE: number = 2;
const ARK_ACTION_MOVE: number = 3;
const ARK_ACTION_HOVER: number = 4;
const ARK_BTN_LEFT: number = 1;
const ARK_BTN_RIGHT: number = 2;
const ARK_BTN_MIDDLE: number = 3;
const ARK_BTN_BACK: number = 4;
const ARK_BTN_FORWARD: number = 5;
// 鼠标事件在触摸路径刚处理过之后要静默这么久（毫秒）。
// 手机形态的模拟器/触屏设备点一下往往同时上报 TouchEvent 和兼容 MouseEvent，
// 不设闸门就会变成「点一下 = 按两次」，远端表现为双击。
const MOUSE_AFTER_TOUCH_MS: number = 300;
// 滚轮：ArkUI 轴事件给的是 vp，触控板一次给几 vp、鼠标一格给十几 vp。
// 攒够这个量才发一格滚轮，避免触控板一划刷出几十个事件。
const AXIS_VP_PER_STEP: number = 15;
// AxisAction：NONE=0 BEGIN=1 UPDATE=2 END=3 CANCEL=4。
// 用数值常量而不是枚举：AxisAction 是 @since 17 的枚举，直接引用在低版本
// 运行时上会取不到值，而数值永远可用。
const AXIS_ACTION_BEGIN: number = 1;
const AXIS_ACTION_END: number = 3;
const AXIS_ACTION_CANCEL: number = 4;

// --- 设备形态判定 ---------------------------------------------------------
// 为什么需要它：鼠标事件通道（onMouse/onHover）在 DevEco 模拟器上是坏的 ——
// 模拟器把 guest 的指针位置回写本机光标时缩放方向反了（实测放大 ~3.3 倍），
// 一挂 onMouse 指针就飞到窗口外，反而不如纯触控。真机没有这层回写。
// 所以按「真实 PC / 平板」开关这条通道，模拟器一律走触控。
function isRealDesktopDevice(): boolean {
  try {
    const dt: string = deviceInfo.deviceType;
    // 2in1 = PC/笔记本形态；tablet 也可能接鼠标键盘。
    if (dt !== '2in1' && dt !== 'tablet') {
      return false;
    }
    const model: string = deviceInfo.productModel.toLowerCase();
    const market: string = deviceInfo.marketName.toLowerCase();
    const name: string = deviceInfo.hardwareModel.toLowerCase();
    // 模拟器：model = "emulator"。留在触控模式。
    return model.indexOf('emulator') < 0 && market.indexOf('emulator') < 0 &&
      name.indexOf('emulator') < 0;
  } catch (e) {
    return false;
  }
}

// 鼠标通道用 AttributeModifier 挂：**没开启就一个事件都不注册**。
// 不能图省事写 .onMouse(...) 再在回调里 return —— 只要注册了，
// 模拟器就会开始往本机光标回写坐标（A/B 实测），指针照样飞出去。
class MouseChannelModifier implements AttributeModifier<CommonAttribute> {
  enabled: boolean = false;
  onMouseCb: (ev: MouseEvent) => void = (ev: MouseEvent) => {};
  onHoverCb: (isHover: boolean, ev: HoverEvent) => void = (isHover: boolean, ev: HoverEvent) => {};

  constructor(enabled: boolean) {
    this.enabled = enabled;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    if (!this.enabled) {
      return;
    }
    instance.onMouse(this.onMouseCb);
    instance.onHover(this.onHoverCb);
  }
}

@Entry
@Component
struct SessionPage {
  @State peerId: string = '';
  @State statusText: string = '连接中…';
  // `connected` 只在收到对端 PeerInfo（真正登录完成）后为 true。
  // 「传输层连通」（connection_type 事件，含连上中继服务器）不等于已连接：
  // 连中继服务器时 TCP 一秒就通，但被控端可能根本没上线 —— 之前把这一步
  // 显示成「已连接」，就是用户看到「假连接成功」的直接原因。
  @State connected: boolean = false;
  @State failed: boolean = false;
  // 密码弹窗
  @State showPasswordDialog: boolean = false;
  @State passwordInput: string = '';
  @State rememberPassword: boolean = false;
  @State passwordHint: string = '请输入被控机的访问密码';
  // 「未加密连接」确认框。上游建链后若拿不到对端 E2EE 公钥，会停下等这一步确认；
  // 不弹这个框、或不把结果回给 Rust，连接就永久停住（黑屏、也不弹密码框）。
  @State showInsecureDialog: boolean = false;
  // 远端画面分辨率（来自 display 事件）
  @State remoteW: number = 0;
  @State remoteH: number = 0;
  // 可用区域（来自 onAreaChange）
  @State areaW: number = 0;
  @State areaH: number = 0;
  // 软键盘。手机上没有实体键盘，不铺这一层就完全没有打字通道。
  @State kbVisible: boolean = false;
  @State kbText: string = '';

  // 手势状态（不需要触发重绘，用普通成员即可）
  private mods: Modifiers = new Modifiers();
  private pressStartX: number = 0;
  private pressStartY: number = 0;
  private lastDispX: number = 0;
  private lastDispY: number = 0;
  private moved: boolean = false;
  private longPressTimer: number = -1;
  private longPressFired: boolean = false;
  private wheelAccum: number = 0;
  private twoFingerY: number = 0;
  private twoFingerActive: boolean = false;
  private touchLogTs: number = 0;
  private autoUpTimer: number = -1;

  // 按下中的手指表（并行数组：id / x / y / 最近活跃时刻）。
  //
  // 为什么不用 ev.touches 直接判多指：实测这个环境里每条事件只带一个触点
  // （日志 `n=1`，连系统注入的点击也一样），第二根手指根本不出现在同一个
  // TouchEvent 里。正确做法是按触点 id 自己累积 —— 第一根 id=0 按下、第二根
  // id=1 按下，两条事件各自只带自己，我们合并后才知道「现在有两根手指」。
  private fingerIds: number[] = [];
  private fingerXs: number[] = [];
  private fingerYs: number[] = [];
  private fingerTs: number[] = [];

  // 滚动模式（顶栏 ↕ 打开）：单指上下滑 = 滚轮，专门给「多指手势做不出来」
  // 的环境兜底。开启后单指不再移动光标/点击，只发滚轮。
  private scrollMode: boolean = false;
  private scrollAccum: number = 0;
  private scrollLastY: number = 0;

  // 底部工具栏是否展开（Android 的 BottomAppBar 也能收起，见 remote_page.dart
  // 的 _showBar / ⌄ 按钮）。收起后画面完整可见，只剩一个小把手召回来。
  @State barVisible: boolean = true;

  // --- 「更多」菜单 --------------------------------------------------------
  @State moreVisible: boolean = false;
  // 对端平台，决定菜单里有哪些项（Android 被控端才有返回/Home/音量…）。
  // 打开菜单时现取：远端平台不会变，但会话可能刚建立还没拿到。
  @State peerPlatform: string = '';
  @State recording: boolean = false;
  // OS 密码输入弹窗
  @State osPwdVisible: boolean = false;
  @State osPwdInput: string = '';
  // 手势说明（Android 的 KeyHelpTools / _showGestureHelp）
  @State helpVisible: boolean = false;
  // 显示器选择面板
  @State displayPickerVisible: boolean = false;
  // 当前切到远端的第几块屏幕（仅当远端多显示器时有意义）。
  private displayIndex: number = 0;

  // --- 鼠标状态（2in1 / PC 形态）------------------------------------------
  // 鸿蒙 PC 上鼠标产生的是 MouseEvent，**不会**触发 onTouch；只挂 onTouch
  // 的实现在 PC 上等于完全没有输入通道。这几个成员专给鼠标路径用。
  private lastTouchTs: number = 0;
  private lastMouseSig: string = '';
  private mouseBtnDown: number = 0;
  // 设置页里的「反转滚轮」/「交换左右键」。这两项上游是 per-peer 的字段
  // （PeerConfig.reverse_mouse_wheel 只能由 Flutter UI 读出来再自己翻转），
  // 客户端协议里没有「请对端反转滚轮」这种消息，所以只能在本机做映射。
  // 以前只写进配置、没人读 —— 属于「设置里改了没反应」的一类。
  private reverseWheel: boolean = false;
  private swapButtons: boolean = false;
  // 同一个落点的高频重复 DOWN 去重。模拟器/触屏在按住不动时会每帧重发一次
  // TouchType.Down（实测 20ms 一次、坐标完全一致），远端会收到一串没有对应
  // UP 的按下，光标卡住、拖动异常。真人的连点间隔远大于这个窗口。
  private lastDownX: number = -1;
  private lastDownY: number = -1;
  private lastDownTs: number = 0;
  // 鼠标通道是否真的注册（见 isRealDesktopDevice / MouseChannelModifier）。
  private mouseMod: MouseChannelModifier = new MouseChannelModifier(isRealDesktopDevice());
  // 滚轮累计量（vp），攒够 AXIS_VP_PER_STEP 才发一格；以及「一组轴事件只发一格」的闸门。
  private axisAccum: number = 0;
  private axisLogTs: number = 0;
  private axisGesture: boolean = false;
  private axisSent: boolean = false;

  // --- 质量监视器（设置页「显示质量监视器」）------------------------------
  // 数据源：Rust 的 update_quality_status，约 1 秒一条 quality_status 事件。
  @State qmVisible: boolean = false;
  @State qmSpeed: string = '';
  @State qmFps: string = '';
  @State qmDelay: string = '';
  @State qmCodec: string = '';

  // --- 远程光标（设置页「显示远程光标」）----------------------------------
  // 只有对端没有把光标画进视频帧（cursor_embedded=false）时才需要本地画；
  // Windows 被控端默认内嵌光标，此时远端指针本来就在画面里，再画一个就重影。
  @State remoteCursorX: number = -1;
  @State remoteCursorY: number = -1;
  private showRemoteCursor: boolean = false;
  private cursorEmbedded: boolean = true;
  private lastCursorUpdateTs: number = 0;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null && params['peerId'] !== undefined) {
      this.peerId = params['peerId'] as string;
    }
    // 鼠标回调必须是箭头函数包一层，直接在 modifier 里存 this.handleMouse
    // 会丢掉组件 this（普通方法不是绑定过的）。
    this.mouseMod.onMouseCb = (ev: MouseEvent) => { this.handleMouse(ev); };
    this.mouseMod.onHoverCb = (isHover: boolean, ev: HoverEvent) => {
      if (isHover) {
        this.handleHover(ev);
      }
    };
    hilog.info(DOMAIN, TAG, 'device type=%{public}s model=%{public}s -> mouse channel %{public}s',
      deviceInfo.deviceType, deviceInfo.productModel, this.mouseMod.enabled ? 'ON' : 'OFF');
    RustDesk.on(this.onCoreEvent);

    // 「反转滚轮」「交换左右键」在本机生效（协议里没有对应消息）。
    // 每次进页面读一次即可：会话中途改设置属于罕见路径，重新进页面就会生效。
    this.reverseWheel = RustDesk.optionGetBool('reverse_mouse_wheel');
    this.swapButtons = RustDesk.optionGetBool('swap-left-right-mouse');
    hilog.info(DOMAIN, TAG, 'input options: reverse_wheel=%{public}s swap_buttons=%{public}s',
      this.reverseWheel ? 'Y' : 'N', this.swapButtons ? 'Y' : 'N');

    // 质量监视器 / 远程光标的显示开关同样是进页面读一次。
    this.qmVisible = RustDesk.optionGetBool('show-quality-monitor');
    this.showRemoteCursor = RustDesk.optionGetBool('show-remote-cursor');
    hilog.info(DOMAIN, TAG, 'overlay options: quality_monitor=%{public}s remote_cursor=%{public}s',
      this.qmVisible ? 'Y' : 'N', this.showRemoteCursor ? 'Y' : 'N');

    // 页面可能是在会话已建立之后才重建的（切后台再回来），
    // 所以先读一次状态快照，不能只依赖事件。
    const st: SessionState = RustDesk.state();
    this.applyState(st);
  }

  aboutToDisappear(): void {
    RustDesk.off(this.onCoreEvent);
    this.clearLongPress();
    this.clearAutoUp();
    // 拖动中直接离开页面（按返回、弹窗抢焦点）时左键会停在按下状态，
    // 远端从此把每次移动都当拖动。参考实现也是在 blur/离开时统一
    // releaseHeldMouseButtons（StarRustDesk: releaseHeldMouseButtons('input_blur')）。
    if (this.moved) {
      const end: Position = this.toRemote(this.lastDispX, this.lastDispY);
      RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.UP), end.x, end.y, this.mods);
      this.moved = false;
    }
    // 离开页面就断开：手机上没有「后台保持会话」的语义，
    // 不断开的话 Rust 的 io_loop 线程会一直跑着。
    RustDesk.closeSession();
  }

  private applyState(st: SessionState): void {
    if (st.connected === true) {
      this.connected = true;
      this.statusText = '已连接';
    }
    const d = st.display;
    if (d !== undefined && d.w > 0 && d.h > 0) {
      this.remoteW = d.w;
      this.remoteH = d.h;
    }
  }

  private onCoreEvent = (ev: UiEvent): void => {
    switch (ev.event) {
      case 'display': {
        const d: DisplayEventData = ev.data as DisplayEventData;
        if (d !== undefined && d.w > 0 && d.h > 0) {
          // 分辨率变化（对端切显示器 / 改分辨率）后要重新请求关键帧，
          // 否则画面会花到下一个关键帧为止。
          if (this.remoteW !== 0 && this.remoteW !== d.w) {
            RustDesk.refresh(0);
          }
          this.remoteW = d.w;
          this.remoteH = d.h;
          // 光标是否内嵌在视频帧里：内嵌时不再本地画远程光标（会重影）。
          this.cursorEmbedded = d.cursor_embedded;
        }
        break;
      }
      case 'connected': {
        // 对端 PeerInfo 已收到 = 登录真正完成。
        this.connected = true;
        this.statusText = '已连接';
        break;
      }
      case 'connection_type': {
        // 传输层连通（直连打洞成功 / 连上了中继服务器）。此刻还没登录：
        // 后续要么弹密码框（msgbox input-password），要么等对端接受。
        if (!this.connected) {
          this.statusText = '通道已建立，正在登录…';
        }
        break;
      }
      case 'msgbox': {
        const d: MsgboxEventData = ev.data as MsgboxEventData;
        this.handleMsgbox(d);
        break;
      }
      case 'close_connecting':
        // 上游语义：首帧到达 = 连接真正建立，关掉「连接中」进度。
        // 注意这**不是**断线事件，别当成 close 处理。
        this.connected = true;
        this.failed = false;
        this.statusText = '已连接';
        break;
      case 'close': {
        const d: CloseEventData = ev.data as CloseEventData;
        // 防陈旧事件：事件经 napi 异步投递，「重连顶掉旧会话」时旧会话的
        // close（reason=success）可能晚到几秒，落在新页面上。若 Rust 侧
        // 当前会话仍在连接状态，这条 close 一定是旧会话的，忽略。
        const live: SessionState = RustDesk.state();
        if (live !== null && live.connected === true) {
          hilog.info(DOMAIN, TAG, 'drop stale close event (session still connected)');
          break;
        }
        this.connected = false;
        this.failed = d !== undefined && d.reason !== 'success';
        this.statusText = `连接已断开（${d?.reason ?? 'unknown'}）`;
        break;
      }
      case 'block_input': {
        const d: BlockInputEventData = ev.data as BlockInputEventData;
        if (d !== undefined && d.on) {
          promptAction.showToast({ message: '远端已屏蔽本机输入' });
        }
        break;
      }
      case 'quality_status': {
        const d: QualityStatusEventData = ev.data as QualityStatusEventData;
        hilog.debug(DOMAIN, TAG, 'quality_status: %{public}s', JSON.stringify(ev.data));
        if (d !== undefined && this.qmVisible) {
          // 合并式更新：延迟来自 TestDelay（1 秒级），速度/FPS/编解码来自
          // io_loop 的周期统计（另一条事件），两边各带各的字段。
          // 不能整体覆盖 —— 否则两类事件互相把对方字段清空，界面只剩一项。
          if ((d.speed ?? '').length > 0) {
            this.qmSpeed = d.speed;
          }
          if ((d.fps ?? 0) > 0) {
            this.qmFps = `${d.fps}`;
          }
          if ((d.delay ?? 0) > 0) {
            this.qmDelay = `${d.delay}ms`;
          }
          if ((d.codec_format ?? '').length > 0) {
            this.qmCodec = d.codec_format +
              ((d.chroma ?? '') === '4:4:4' ? ' 4:4:4' : '');
          }
        }
        break;
      }
      case 'cursor_position': {
        const d: CursorPositionEventData = ev.data as CursorPositionEventData;
        if (d !== undefined && this.showRemoteCursor && !this.cursorEmbedded) {
          // 光标移动事件频率跟远端鼠标一样高，限到 ~30fps 再刷 @State，
          // 避免高频小位移把 UI 线程打满。后面的事件只刷新限流窗口外的。
          const now: number = Date.now();
          if (now - this.lastCursorUpdateTs >= 33) {
            this.lastCursorUpdateTs = now;
            this.updateRemoteCursor(d.x, d.y);
          }
        }
        break;
      }
      default:
        // rgba 事件由 C++ 渲染线程自己拉帧，ArkTS 不需要处理。
        break;
    }
  }

  // msgbox 是上游用来表达「连接过程中需要用户决策 / 值得展示的信息」的通道，
  // 类型见 src/client.rs 的 handle_login_error / handle_peer_info。
  private handleMsgbox(d: MsgboxEventData): void {
    if (d === undefined) {
      return;
    }
    const mt: string = d.type !== undefined ? d.type : '';
    switch (mt) {
      case 'input-password':
        this.passwordHint = '请输入被控机的访问密码';
        this.passwordInput = '';
        this.showPasswordDialog = true;
        break;
      case 're-input-password':
        this.passwordHint = '密码错误，请重新输入';
        this.passwordInput = '';
        this.showPasswordDialog = true;
        break;
      case 'input-2fa':
        this.failed = true;
        this.statusText = '对端要求 2FA 验证码（暂不支持）';
        break;
      case 'wait-remote-accept-nook':
        this.statusText = '已发起请求，等待对端接受…';
        break;
      case 'insecure-connection-nocancel-hasclose':
      case 'insecure-connection':
        // 上游的 confirm_insecure_connection 正在等我们回话，必须弹框。
        this.showInsecureDialog = true;
        this.statusText = '等待确认：本次连接未加密';
        break;
      case 'error':
        this.failed = true;
        // text 可能是 HTML（上游允许 <br>），去掉标签避免满屏尖括号。
        this.statusText = `${d.title}: ${this.stripHtml(d.text)}`;
        break;
      case 'success':
        this.statusText = d.text.length > 0 ? d.text : '已连接';
        break;
      default:
        if (!this.connected) {
          this.statusText = d.title;
        }
        break;
    }
  }

  private stripHtml(s: string): string {
    const noTags: string = s.replace(/<br\s*\/?>/gi, ' ').replace(/<[^>]*>/g, '');
    return noTags.length > 80 ? `${noTags.substring(0, 80)}…` : noTags;
  }

  private submitPassword(): void {
    const pwd: string = this.passwordInput;
    if (pwd.length === 0) {
      promptAction.showToast({ message: '请输入密码' });
      return;
    }
    this.showPasswordDialog = false;
    this.statusText = '正在验证密码…';
    const rc: number = RustDesk.login(pwd, this.rememberPassword);
    if (rc !== 0) {
      this.failed = true;
      this.statusText = `提交密码失败（${rc}）：会话可能已断开`;
    }
  }

  private cancelPassword(): void {
    // 不给密码就没法继续，直接退出会话页（会顺带 closeSession）。
    this.showPasswordDialog = false;
    router.back();
  }

  private answerInsecure(accept: boolean): void {
    this.showInsecureDialog = false;
    const rc: number = RustDesk.continueInsecure(accept);
    if (rc !== 0) {
      this.failed = true;
      this.statusText = `回应确认失败（${rc}）：会话可能已断开`;
      return;
    }
    if (accept) {
      this.statusText = '通道已建立，正在登录…';
    } else {
      this.statusText = '已因未加密取消连接';
      this.failed = true;
    }
  }

  // --- 坐标换算 -----------------------------------------------------------
  // XComponent 的尺寸按远端宽高比设置（见 build 里的 displayW/displayH），
  // 所以这里就是纯线性映射，没有黑边偏移。
  //
  // 软键盘条显示时必须把它的高度从可用区域里扣掉，否则画面会伸到输入条
  // 底下：输入条盖住画面最底部（往往正好是远端任务栏），那一片的点击
  // 全被输入条挡住 —— 表现就是「点任务栏没反应」。
  private static readonly KB_BAR_H: number = 56;

  private effAreaH(): number {
    if (this.kbVisible && this.areaH > SessionPage.KB_BAR_H) {
      return this.areaH - SessionPage.KB_BAR_H;
    }
    return this.areaH;
  }

  private displayW(): number {
    const ah: number = this.effAreaH();
    if (this.areaW <= 0 || ah <= 0 || this.remoteW <= 0 || this.remoteH <= 0) {
      return this.areaW;
    }
    const s: number = Math.min(this.areaW / this.remoteW, ah / this.remoteH);
    return this.remoteW * s;
  }

  private displayH(): number {
    const ah: number = this.effAreaH();
    if (this.areaW <= 0 || ah <= 0 || this.remoteW <= 0 || this.remoteH <= 0) {
      return this.areaH;
    }
    const s: number = Math.min(this.areaW / this.remoteW, ah / this.remoteH);
    return this.remoteH * s;
  }

  private toRemote(lx: number, ly: number): Position {
    const dw: number = this.displayW();
    const dh: number = this.displayH();
    const ah: number = this.effAreaH();
    if (dw <= 0 || dh <= 0 || this.areaW <= 0 || ah <= 0) {
      return new Position(0, 0);
    }
    // 触摸坐标是相对**整个页面**的（事件挂在最外层 Stack 上），
    // 而画面在页面里是居中的，所以要先减掉黑边偏移。
    const left: number = (this.areaW - dw) / 2;
    const top: number = (ah - dh) / 2;
    let x: number = Math.round((lx - left) * this.remoteW / dw);
    let y: number = Math.round((ly - top) * this.remoteH / dh);
    x = x < 0 ? 0 : (x > this.remoteW - 1 ? this.remoteW - 1 : x);
    y = y < 0 ? 0 : (y > this.remoteH - 1 ? this.remoteH - 1 : y);
    return new Position(x, y);
  }

  // 远端光标坐标 → 页面显示坐标（toRemote 的反变换）。只在画布范围内显示。
  private updateRemoteCursor(rx: number, ry: number): void {
    const dw: number = this.displayW();
    const dh: number = this.displayH();
    const ah: number = this.effAreaH();
    if (dw <= 0 || dh <= 0 || this.remoteW <= 0 || this.remoteH <= 0) {
      return;
    }
    const left: number = (this.areaW - dw) / 2;
    const top: number = (ah - dh) / 2;
    const sx: number = left + rx * dw / this.remoteW;
    const sy: number = top + ry * dh / this.remoteH;
    if (sx < 0 || sy < 0 || sx > this.areaW || sy > ah) {
      this.remoteCursorX = -1; // 超出画面：隐藏
      return;
    }
    this.remoteCursorX = sx;
    this.remoteCursorY = sy;
  }

  // 质量监视器的文本行（空项跳过）。
  private qmText(): string {
    const parts: string[] = [];
    if (this.qmSpeed.length > 0) {
      parts.push(this.qmSpeed);
    }
    if (this.qmFps.length > 0) {
      parts.push(`FPS ${this.qmFps}`);
    }
    if (this.qmDelay.length > 0) {
      parts.push(`延迟 ${this.qmDelay}`);
    }
    if (this.qmCodec.length > 0) {
      parts.push(this.qmCodec);
    }
    return parts.join('  ');
  }

  // --- 手势 ---------------------------------------------------------------

  private clearLongPress(): void {
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  private fireLongPress = (): void => {
    // 长按 → 右键点击。移动端没有第二键，这是最接近「上下文菜单」的映射。
    // 与单击同一套顺序：先 MOVE 把远端光标放到落点，再按下/抬起右键。
    // 已经不用先补 LEFT UP 了 —— 这套实现按下时**不发**左键（见 handleTouch
    // 的 Down 分支），不存在「按着没松」的状态。
    const p: Position = this.toRemote(this.pressStartX, this.pressStartY);
    if (this.moved) {
      return;  // 已经开始拖动了，不是长按
    }
    this.longPressFired = true;
    // 长按是「次键」。开了交换左右键时次键就是左键。
    const btn: number = this.swapButtons ? MouseButton.LEFT : MouseButton.RIGHT;
    RustDesk.mouse(MOUSE_TYPE_MOVE, p.x, p.y, this.mods);
    RustDesk.mouse(mouseMask(btn, MouseType.DOWN), p.x, p.y, this.mods);
    RustDesk.mouse(mouseMask(btn, MouseType.UP), p.x, p.y, this.mods);
  };

  // --- 手指表 -------------------------------------------------------------

  private fingerIndexOf(id: number): number {
    for (let i = 0; i < this.fingerIds.length; i++) {
      if (this.fingerIds[i] === id) {
        return i;
      }
    }
    return -1;
  }

  private fingerPut(id: number, x: number, y: number): void {
    const i: number = this.fingerIndexOf(id);
    if (i >= 0) {
      this.fingerXs[i] = x;
      this.fingerYs[i] = y;
      this.fingerTs[i] = Date.now();
      return;
    }
    this.fingerIds.push(id);
    this.fingerXs.push(x);
    this.fingerYs.push(y);
    this.fingerTs.push(Date.now());
  }

  private fingerDrop(id: number): void {
    const i: number = this.fingerIndexOf(id);
    if (i < 0) {
      return;
    }
    this.fingerIds.splice(i, 1);
    this.fingerXs.splice(i, 1);
    this.fingerYs.splice(i, 1);
    this.fingerTs.splice(i, 1);
  }

  private fingerClear(): void {
    this.fingerIds = [];
    this.fingerXs = [];
    this.fingerYs = [];
    this.fingerTs = [];
  }

  // 抬手事件会丢（实测：日志里只有 type=0 没有 type=1），手指表就会残留，
  // 之后每次单指都被误判成双指。超过这个时间没再收到某根手指的任何事件，
  // 就当它已经离开了。
  private fingerSweep(): void {
    const now: number = Date.now();
    for (let i = this.fingerIds.length - 1; i >= 0; i--) {
      if (now - this.fingerTs[i] > FINGER_STALE_MS) {
        this.fingerIds.splice(i, 1);
        this.fingerXs.splice(i, 1);
        this.fingerYs.splice(i, 1);
        this.fingerTs.splice(i, 1);
      }
    }
  }

  // 自动补抬起：按下之后 Up/Cancel 迟迟不来时替用户抬起左键。
  // 真实 Up 到达会走 clearAutoUp()，所以正常环境下这只是个空转的定时器。
  private clearAutoUp(): void {
    if (this.autoUpTimer !== -1) {
      clearTimeout(this.autoUpTimer);
      this.autoUpTimer = -1;
    }
  }

  private resetAutoUp(delay: number): void {
    this.clearAutoUp();
    this.autoUpTimer = setTimeout(this.fireAutoUp, delay);
  }

  private fireAutoUp = (): void => {
    this.autoUpTimer = -1;
    // 走到这里说明一次触摸已经结束（抬手事件没送回来），手指表里的残留
    // 必须清掉，否则下次单指也会被当成双指。
    this.fingerClear();
    if (this.pressStartX === 0 && this.pressStartY === 0) {
      return;
    }
    if (this.longPressFired) {
      return;  // 长按有自己的抬起语义（fireLongPress 里已经抬起），不重复补
    }
    // 只有「真的按着左键」才需要补抬起 —— 也就是拖动中。普通点击在按下时
    // 根本不发 DOWN，抬手丢了顶多丢一次点击，不会把远端左键卡住。
    if (!this.moved) {
      this.pressStartX = 0;
      this.pressStartY = 0;
      return;
    }
    const end: Position = this.toRemote(this.lastDispX, this.lastDispY);
    hilog.info(DOMAIN, TAG, 'auto up: drag without up event, releasing at %{public}d,%{public}d', end.x, end.y);
    RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.UP), end.x, end.y, this.mods);
    this.pressStartX = 0;
    this.pressStartY = 0;
    this.moved = false;
  };

  // --- 鼠标 ---------------------------------------------------------------
  //
  // 鸿蒙 PC（2in1）上鼠标只产生 MouseEvent，一个 onTouch 都不会来；手机
  // 形态下触屏点按通常还会补发一份兼容 MouseEvent。两条路径都必须能用，
  // 且不能双发 —— 闸门是 lastTouchTs，触摸刚处理过就忽略鼠标。
  //
  // 这套映射同时也决定了 PC 端主控的可用性：远端要能「指哪打哪」，靠的
  // 就是下面 PRESS 分支里先发 MOVE 再发 DOWN 这个顺序。
  private rdButtonOf(arkBtn: number): number {
    // 「交换左右键」：纯本机映射（协议里没有这个开关）。只换主/次两键，
    // 中键与侧键保持原义 —— 上游的 swap-left-right-mouse 也是这个语义。
    let b: number = arkBtn;
    if (this.swapButtons) {
      if (b === ARK_BTN_LEFT) {
        b = ARK_BTN_RIGHT;
      } else if (b === ARK_BTN_RIGHT) {
        b = ARK_BTN_LEFT;
      }
    }
    switch (b) {
      case ARK_BTN_RIGHT:
        return MouseButton.RIGHT;
      case ARK_BTN_MIDDLE:
        // RustDesk 没有独立的中键位（按钮位只有 LEFT/RIGHT/WHEEL/BACK/FORWARD），
        // 中键点击按 WHEEL 位发，服务端当作滚轮键按下处理。
        return MouseButton.WHEEL;
      case ARK_BTN_BACK:
        return MouseButton.BACK;
      case ARK_BTN_FORWARD:
        return MouseButton.FORWARD;
      default:
        return MouseButton.LEFT;
    }
  }

  // 移动/悬停：只在落点真的变化时才发。鼠标每挪一个像素都上线一包的话，
  // 1080p 桌面拖一下窗口就能刷出上千个 MouseEvent。
  private sendMove(mask: number, x: number, y: number): void {
    const sig: string = mask + ':' + x + ':' + y;
    if (sig === this.lastMouseSig) {
      return;
    }
    this.lastMouseSig = sig;
    RustDesk.mouse(mask, x, y, this.mods);
  }

  private currentMoveMask(): number {
    // 按着键移动 = 拖拽，mask 要带按钮位，服务端才知道在做 drag。
    return this.mouseBtnDown !== 0
      ? mouseMask(this.mouseBtnDown, MouseType.MOVE)
      : MOUSE_TYPE_MOVE;
  }

  private handleHover(ev: HoverEvent): void {
    if (this.remoteW <= 0 || this.remoteH <= 0) {
      return;
    }
    if (Date.now() - this.lastTouchTs < MOUSE_AFTER_TOUCH_MS) {
      return;
    }
    // HoverEvent 的坐标在类型上是可选的（部分 SDK 只在有效移动时填），
    // 拿不到就当这次悬停无效，绝不能把 undefined 传进坐标换算。
    const hx: number = ev.x as number;
    const hy: number = ev.y as number;
    if (!Number.isFinite(hx) || !Number.isFinite(hy)) {
      return;
    }
    if (hy < 56 || (this.kbVisible && hy > this.areaH - 56)) {
      return;
    }
    const p: Position = this.toRemote(hx, hy);
    this.sendMove(this.currentMoveMask(), p.x, p.y);
  }

  private handleMouse(ev: MouseEvent): void {
    // 同 handleTouch：能不能发输入只看有没有远端画面，不看可能被污染的 connected。
    if (this.remoteW <= 0 || this.remoteH <= 0) {
      return;
    }
    // 这一次点按已经由触摸路径发过了，鼠标这份是兼容上报，丢掉。
    if (Date.now() - this.lastTouchTs < MOUSE_AFTER_TOUCH_MS) {
      return;
    }
    // 顶部 56vp 是本机状态栏、底部 56vp 是本机软键盘条，都不是远端画面。
    if (ev.y < 56 || (this.kbVisible && ev.y > this.areaH - 56)) {
      return;
    }

    const act: number = ev.action as number;
    const btn: number = ev.button as number;
    const p: Position = this.toRemote(ev.x, ev.y);

    if (act === ARK_ACTION_MOVE || act === ARK_ACTION_HOVER) {
      this.sendMove(this.currentMoveMask(), p.x, p.y);
      return;
    }
    if (act !== ARK_ACTION_PRESS && act !== ARK_ACTION_RELEASE) {
      return;
    }

    const rdBtn: number = this.rdButtonOf(btn);
    if (act === ARK_ACTION_PRESS) {
      // 排查「鼠标点了没反应」的第一现场：这条日志出现 = 鼠标事件确实
      // 进到了应用；完全不出现而只有 touch down，说明模拟器把鼠标当触摸。
      hilog.info(DOMAIN, TAG, 'mouse press ark_btn=%{public}d -> %{public}d,%{public}d',
        btn, p.x, p.y);
      this.mouseBtnDown = this.mouseBtnDown | rdBtn;
      // 与触摸一致：先 MOVE 再 DOWN。服务端 DOWN 分支只在**光标当前位置**
      // 按键、不做移动（input_service::handle_mouse_simulation_），少了这
      // 一下点击就会落在上一次的位置上 —— 表现为「点了没反应」或点错地方。
      RustDesk.mouse(MOUSE_TYPE_MOVE, p.x, p.y, this.mods);
      RustDesk.mouse(mouseMask(rdBtn, MouseType.DOWN), p.x, p.y, this.mods);
    } else {
      this.mouseBtnDown = this.mouseBtnDown & ~rdBtn;
      RustDesk.mouse(mouseMask(rdBtn, MouseType.UP), p.x, p.y, this.mods);
    }
  }

  // --- 滚轮 ---------------------------------------------------------------
  //
  // 轴事件（onAxisEvent）是 PC 上鼠标滚轮、触控板双指的唯一来源。它和
  // onMouse 是两条独立通道：只注册轴事件不会触发模拟器的指针回写 bug
  // （实测：滚动时指针不动），所以这条通道无条件挂载。
  //
  // 协议侧：滚轮事件 mask = (WHEEL<<3)|WHEEL，**y 字段承载滚动格数**，
  // 正数=向上滚。位置不会因为滚轮而改变，所以先补一发 MOVE 把远端光标
  // 移到指针所在处，再发滚轮 —— 否则滚动会作用在上一次点击的位置上。
  private handleAxis(ev: AxisEvent): void {
    // 入口诊断：轴事件到底有没有进来、指针落点在哪。限频 200ms 防刷屏。
    // 注意 hilog **不支持 %{public}f**（实测打印成 "}f" 并把后面的参数全部错位），
    // 浮点一律乘 100 取整后按整数打。
    const nowTs: number = Date.now();
    if (nowTs - this.axisLogTs > 200) {
      this.axisLogTs = nowTs;
      hilog.info(DOMAIN, TAG,
        'axis in act=%{public}d x=%{public}d y=%{public}d v=%{public}d h=%{public}d tool=%{public}d remote=%{public}dx%{public}d',
        ev.action, Math.round(ev.x), Math.round(ev.y), Math.round(ev.getVerticalAxisValue() * 100),
        Math.round(ev.getHorizontalAxisValue() * 100), ev.sourceTool, this.remoteW, this.remoteH);
    }
    if (this.remoteW <= 0 || this.remoteH <= 0) {
      return;
    }
    if (Date.now() - this.lastTouchTs < MOUSE_AFTER_TOUCH_MS) {
      return;
    }
    const v: number = ev.getVerticalAxisValue();
    const hv: number = ev.getHorizontalAxisValue();
    if ((!Number.isFinite(v) || v === 0) && (!Number.isFinite(hv) || hv === 0)) {
      return;
    }
    const ax: number = ev.x as number;
    const ay: number = ev.y as number;
    if (!Number.isFinite(ax) || !Number.isFinite(ay)) {
      return;
    }
    // 顶栏、软键盘条不是远端画面。
    // 顶栏 56vp、底部 56vp（工具栏 / 软键盘条）都不是远端画面。
    if (ay < 56 || ay > this.areaH - 56) {
      return;
    }
    const p: Position = this.toRemote(ax, ay);
    // 滚轮协议里**不带位置**：服务端 WHEEL 分支把 x 当横向滚动量、y 当纵向
    // 滚动量（input_service.rs: 先 `let x = -evt.x;` 再 mouse_scroll_x/y），
    // 滚动发生在「远端光标当前所在处」。所以位置要靠这一次 MOVE 补，
    // 而滚轮包里的 x 必须是 0 —— 之前把 p.x 传进去，服务端会当成
    // 横向滚动 -1600*120 格，纵向那一下就被这个巨大横滚盖掉了。
    this.sendMove(this.currentMoveMask(), p.x, p.y);

    const act: number = ev.action as number;
    const isTouchpad: boolean = ev.sourceTool === 4;
    // 一格滚轮 = 一组 BEGIN..UPDATE..END 事件（实测一次物理滚动 44ms 内来 3 条）。
    // 鼠标按「每组发一格」计数；触控板按 vp 累计（AXIS_VP_PER_STEP）。
    if (act === AXIS_ACTION_BEGIN) {
      this.axisGesture = true;
      this.axisSent = false;
    } else if (act === AXIS_ACTION_END || act === AXIS_ACTION_CANCEL) {
      this.axisGesture = false;
      this.axisSent = false;
    }

    let dx: number = 0;
    let dy: number = 0;
    if (isTouchpad) {
      this.axisAccum += v;
      const steps: number = Math.trunc(this.axisAccum / AXIS_VP_PER_STEP);
      if (steps === 0) {
        return;
      }
      this.axisAccum -= steps * AXIS_VP_PER_STEP;
      dy = Math.max(-5, Math.min(5, steps)) > 0 ? -1 : 1;
    } else {
      if (this.axisSent) {
        return;  // 同一组只发一格，避免一次物理滚动刷成 3 格
      }
      this.axisSent = true;
      // 横向优先：横向轴值更大就当横向滚动（触控板、Shift+滚轮）。
      if (Math.abs(hv) > Math.abs(v)) {
        dx = hv > 0 ? -1 : 1;
      } else {
        // 方向取反，与上游 Flutter 一致（input_model.dart: rawDy>0 → dy=-accel）：
        // 轴值增大（向后滑）= 视口上移 → 远端发负数。
        dy = v > 0 ? -1 : 1;
      }
    }
    // 「反转滚轮」：设置项 reverse_mouse_wheel 在本机翻转纵向方向，
    // 与上游 Flutter 的处理位置一致（协议侧没有这个开关）。
    if (this.reverseWheel) {
      dy = -dy;
    }
    hilog.info(DOMAIN, TAG, 'wheel v=%{public}d -> dx=%{public}d dy=%{public}d at %{public}d,%{public}d',
      Math.round(v * 100), dx, dy, p.x, p.y);
    RustDesk.mouse(mouseMask(MouseButton.WHEEL, MouseType.WHEEL), dx, dy, this.mods);
  }

  private handleTouch(ev: TouchEvent): void {
    // 触摸路径优先：记下时间戳，让紧随其后的兼容 MouseEvent 静默。
    this.lastTouchTs = Date.now();
    // 注意：这里**不能**用 `connected` 做闸门。`connected` 只是 UI 状态，
    // 一条陈旧/误判的 close 事件就能把它置 false，而会话其实还活着 ——
    // 那样键盘还能用（handleKey 不看这个标志），鼠标却全部被丢掉。
    // 判定「能不能操作」只看有没有真的收到过远端画面。
    if (this.remoteW <= 0 || this.remoteH <= 0) {
      return;
    }
    const ts: TouchObject[] = ev.touches;

    // 维护手指表：只看 changedTouches 的 id 自己累积，不依赖 ev.touches 的
    // 完整性（见 fingerIds 的注释）。这一步必须在双指判定之前。
    const chgAll: TouchObject[] = ev.changedTouches;
    for (let i = 0; i < chgAll.length; i++) {
      const c: TouchObject = chgAll[i];
      if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
        this.fingerDrop(c.id);
      } else {
        this.fingerPut(c.id, c.x, c.y);
      }
    }
    this.fingerSweep();

    // 入口诊断：每次触摸到底带了几根手指、落在哪。限频 120ms 防刷屏。
    // n = 系统给的 ev.touches 条数，f = 我们自己累积出的手指数 —— 这两个数
    // 不一样正是「双指退化成单指」的直接证据。
    const nowT: number = Date.now();
    if (nowT - this.touchLogTs > 120) {
      this.touchLogTs = nowT;
      let pts: string = '';
      for (let i = 0; i < ts.length; i++) {
        pts += `${Math.round(ts[i].x)},${Math.round(ts[i].y)} `;
      }
      hilog.info(DOMAIN, TAG, 'touch type=%{public}d n=%{public}d chg=%{public}d f=%{public}d pts=[%{public}s]',
        ev.type, ts.length, ev.changedTouches.length, this.fingerIds.length, pts);
    }

    // --- 双指：滚动 ------------------------------------------------------
    if (this.fingerIds.length >= 2) {
      this.clearLongPress();
      this.clearAutoUp();
      if (this.moved) {
        // 拖动中落进第二根手指：先放开左键再进滚动，否则远端会以为还在拖，
        // 滚轮事件会被当成「拖着滚」。单击没有按下态，不需要补 UP。
        const p: Position = this.toRemote(this.lastDispX, this.lastDispY);
        RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.UP), p.x, p.y, this.mods);
        this.moved = false;
      }
      const midX: number = (this.fingerXs[0] + this.fingerXs[1]) / 2;
      const midY: number = (this.fingerYs[0] + this.fingerYs[1]) / 2;
      if (!this.twoFingerActive) {
        this.twoFingerActive = true;
        this.twoFingerY = midY;
        this.wheelAccum = 0;
        hilog.info(DOMAIN, TAG, 'two-finger start n=%{public}d at %{public}d,%{public}d',
          this.fingerIds.length, Math.round(midX), Math.round(midY));
        return;
      }
      const dy: number = midY - this.twoFingerY;
      this.twoFingerY = midY;
      this.wheelAccum += dy;
      if (Math.abs(this.wheelAccum) >= WHEEL_STEP_PX) {
        // 向上滑（dy < 0）在桌面上是「内容上移」= 滚轮向上，RustDesk 用 y 的
        // 正负表示方向，向上滚为正 —— 与 handleAxis 的结论保持一致。
        // 设置里的「反转滚轮」同样作用在双指滚动上，保持两条通道方向一致。
        const steps: number = (this.wheelAccum < 0 ? 1 : -1) * (this.reverseWheel ? -1 : 1);
        const p: Position = this.toRemote(midX, midY);
        // 滚轮包的 x 是**横向滚动量**，不是坐标，纵向滚动必须传 0。
        RustDesk.mouse(MOUSE_TYPE_MOVE, p.x, p.y, this.mods);
        RustDesk.mouse(mouseMask(MouseButton.WHEEL, MouseType.WHEEL), 0, steps, this.mods);
        this.wheelAccum = 0;
        hilog.info(DOMAIN, TAG, 'wheel(2f) %{public}d at %{public}d,%{public}d', steps, p.x, p.y);
      }
      return;
    }

    // 退出双指：残指只剩一根时要把基准重置到它当前的位置，否则下一次 Move
    // 会拿双指起点的旧 pressStart 算位移，一上手就被判成拖动。
    if (this.twoFingerActive) {
      this.twoFingerActive = false;
      this.wheelAccum = 0;
      if (this.fingerIds.length === 1) {
        this.pressStartX = this.fingerXs[0];
        this.pressStartY = this.fingerYs[0];
        this.lastDispX = this.fingerXs[0];
        this.lastDispY = this.fingerYs[0];
      }
    }

    // --- 滚动模式：单指上下滑 = 滚轮 ---------------------------------------
    // 双指手势在这台模拟器上做不出来（每条事件只带一个触点，第二根手指不上报），
    // 这个模式把滚动降到单指就能完成，功能等价且不依赖多指上报。
    if (this.scrollMode) {
      const chgS: TouchObject[] = ev.changedTouches;
      if (chgS.length === 0) {
        return;
      }
      const s: TouchObject = chgS[0];
      const sp: Position = this.toRemote(s.x, s.y);
      if (ev.type === TouchType.Down) {
        this.scrollAccum = 0;
        this.scrollLastY = s.y;
        // 只把远端光标移过去，**不按下**：滚动模式不该产生点击。
        RustDesk.mouse(MOUSE_TYPE_MOVE, sp.x, sp.y, this.mods);
      } else if (ev.type === TouchType.Move) {
        const d: number = s.y - this.scrollLastY;
        this.scrollLastY = s.y;
        this.scrollAccum += d;
        if (Math.abs(this.scrollAccum) >= WHEEL_STEP_PX) {
          // 手指向上滑（d < 0）＝ 内容上移 ＝ 滚轮向上，与 handleAxis 的方向一致。
          const steps: number = (this.scrollAccum < 0 ? 1 : -1) * (this.reverseWheel ? -1 : 1);
          RustDesk.mouse(MOUSE_TYPE_MOVE, sp.x, sp.y, this.mods);
          RustDesk.mouse(mouseMask(MouseButton.WHEEL, MouseType.WHEEL), 0, steps, this.mods);
          this.scrollAccum = 0;
          hilog.info(DOMAIN, TAG, 'wheel(1f) %{public}d at %{public}d,%{public}d', steps, sp.x, sp.y);
        }
      }
      return;
    }

    const changed: TouchObject[] = ev.changedTouches;
    if (changed.length === 0) {
      return;
    }
    const t: TouchObject = changed[0];
    // 顶部 56vp 是状态栏按钮区，不当成远端点击（否则按返回/断开
    // 也会顺手在远端点一下）。
    if (ev.type === TouchType.Down && t.y < 56) {
      this.pressStartX = 0;
      this.pressStartY = 0;
      return;
    }
    // 底部 56vp 是工具栏 / 软键盘条，同样是本机 UI。
    // 工具栏可收起，但收起后那块区域仍不该当成远端点击，所以无条件排除。
    if (t.y > this.areaH - 56) {
      this.pressStartX = 0;
      this.pressStartY = 0;
      return;
    }
    const p: Position = this.toRemote(t.x, t.y);

    switch (ev.type) {
      case TouchType.Down: {
        // 同一落点的高频重复按下直接丢掉（见 lastDownX 的注释）。
        if (t.x === this.lastDownX && t.y === this.lastDownY &&
          Date.now() - this.lastDownTs < 80) {
          break;
        }
        this.lastDownX = t.x;
        this.lastDownY = t.y;
        this.lastDownTs = Date.now();
        // 与 mouse press 日志配对看：两者都出现说明手上有兼容鼠标事件，
        // 只出现这一条说明输入来自触摸（触屏 / 模拟器把鼠标转成了触摸）。
        hilog.info(DOMAIN, TAG, 'touch down %{public}d,%{public}d -> %{public}d,%{public}d src=%{public}d tool=%{public}d',
          t.x, t.y, p.x, p.y, ev.source, ev.sourceTool);
        this.pressStartX = t.x;
        this.pressStartY = t.y;
        this.lastDispX = t.x;
        this.lastDispY = t.y;
        this.moved = false;
        this.longPressFired = false;
        // **按下时不发任何鼠标包**，点击留到抬起那一下一次性发完。
        // 移植自 StarRustDesk（RemotePage.ets 的 finishSingleTouch：抬起才
        // sendLeftClick）。按住不动就发 DOWN 的写法在这个环境里代价很大：
        // 抬手事件丢失时远端左键会一直按着，之后所有移动都变成拖动，表现
        // 就是「点一下之后整个画面跟着动」。当前实现还把这一下当拖动起点，
        // 连单击都做不出来。
        // 代价是「长按拖动」要在移动超过阈值时才补 DOWN —— 见 Move 分支。
        this.longPressTimer = setTimeout(this.fireLongPress, LONG_PRESS_MS);
        break;
      }
      case TouchType.Move: {
        const dx: number = t.x - this.pressStartX;
        const dy: number = t.y - this.pressStartY;
        if (!this.moved && dx * dx + dy * dy > MOVE_THRESHOLD_PX * MOVE_THRESHOLD_PX) {
          // 挪够了才算拖动：先补 MOVE 定光标，再按下左键，之后才是带按钮位的
          // 移动。服务端 DOWN 只按「光标当前所在位置」，少了前面那一下 MOVE
          // 就会从旧位置开始拖（与 Flutter 的 remote_input.dart 一致）。
          this.moved = true;
          this.clearLongPress();
          const sp: Position = this.toRemote(this.pressStartX, this.pressStartY);
          RustDesk.mouse(MOUSE_TYPE_MOVE, sp.x, sp.y, this.mods);
          RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.DOWN), sp.x, sp.y, this.mods);
          hilog.info(DOMAIN, TAG, 'drag start at %{public}d,%{public}d', sp.x, sp.y);
        }
        if (this.moved && !this.longPressFired) {
          // 拖动时保持左键按下：mask 里带 LEFT 位。
          RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.MOVE), p.x, p.y, this.mods);
          // 拖动中抬手事件丢失的兜底：只有「真的按着左键」时才需要，
          // 普通点击不会再粘键，所以这个定时器不再影响单击。
          this.resetAutoUp(AUTO_UP_DRAG_MS);
        }
        this.lastDispX = t.x;
        this.lastDispY = t.y;
        break;
      }
      case TouchType.Up:
      case TouchType.Cancel: {
        this.clearLongPress();
        this.clearAutoUp();
        hilog.info(DOMAIN, TAG, 'touch up type=%{public}d at %{public}d,%{public}d moved=%{public}d',
          ev.type, t.x, t.y, this.moved ? 1 : 0);
        // 没有对应的按下（例如按在状态栏上）就不该补抬起。
        if (this.pressStartX === 0 && this.pressStartY === 0) {
          break;
        }
        if (!this.longPressFired) {
          // 落点一律用**按下/最后移动**的位置，不读抬起事件自带的坐标：
          // 实测这个环境的 Up 事件坐标和 Down 对不上（同一次点按
          // down y=623.9 / up y=235.0，x 却完全一致），拿它当落点会让远端
          // 光标凭空跳一段。StarRustDesk 的 finishSingleTouch 也是用
          // lastAbsX/lastAbsY 而不是事件坐标。
          const end: Position = this.toRemote(this.lastDispX, this.lastDispY);
          if (this.moved) {
            // 拖动收尾：补一次移动再松开。
            RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.MOVE), end.x, end.y, this.mods);
            RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.UP), end.x, end.y, this.mods);
          } else if (ev.type === TouchType.Up) {
            // 单击：MOVE → DOWN → UP 一次发完。中间没有等待，远端看到的就是
            // 一次干脆的左键点击（与 StarRustDesk 的 sendLeftClick 同构）。
            // Cancel 不发点击：那是手势被系统接管/页面被遮挡。
            // 开了「交换左右键」时这一下换成右键 —— 触屏上这是唯一能点到
            // 主键的地方，不跟着换的话这个开关等于没生效。
            const btn: number = this.swapButtons ? MouseButton.RIGHT : MouseButton.LEFT;
            RustDesk.mouse(MOUSE_TYPE_MOVE, end.x, end.y, this.mods);
            RustDesk.mouse(mouseMask(btn, MouseType.DOWN), end.x, end.y, this.mods);
            RustDesk.mouse(mouseMask(btn, MouseType.UP), end.x, end.y, this.mods);
          }
        }
        this.pressStartX = 0;
        this.pressStartY = 0;
        this.moved = false;
        this.longPressFired = false;
        break;
      }
      default:
        break;
    }
  }

  // --- 物理键盘 -----------------------------------------------------------
  // 只有 2in1 / 接了外接键盘才会走到这里。软键盘输入走输入框（M2 再做）。
  private handleKey(ev: KeyEvent): void {
    // 同 handleTouch：能不能发输入只看「有没有远端画面」，
    // 不看可能被陈旧事件污染的 connected。
    if (this.remoteW <= 0 || this.remoteH <= 0) {
      return;
    }
    const code: number = ev.keyCode;
    const down: boolean = ev.type === KeyType.Down;
    const which: string = KeyMap.modifierOf(code);
    if (which !== '') {
      // 修饰键只更新本地状态，不发给远端（否则远端会粘住 Shift/Ctrl）。
      if (which === 'alt') {
        this.mods.alt = down;
      } else if (which === 'ctrl') {
        this.mods.ctrl = down;
      } else if (which === 'shift') {
        this.mods.shift = down;
      } else if (which === 'meta') {
        this.mods.command = down;
      }
      return;
    }
    const name: string | null = KeyMap.translate(code);
    if (name === null) {
      return;  // 不认识的键，静默丢弃
    }
    RustDesk.key(name, down, this.mods);
  }

  // --- 软键盘 -------------------------------------------------------------
  // 做法：底部放一个真实的 TextInput，按 ⌨ 打开并抢焦点，系统输入法就出来了。
  // 文字按「增量」发给远端（整段发 seq），退格/替换用 Backspace 键事件补。
  //
  // 为什么不用 onChange 里的每个字符直接发：中文输入法会先产生拼音候选串，
  // 逐字符发会把拼音也打到远端去。这里只在「新串以旧串开头」时发新增部分，
  // 其余情况（退格、选中替换、粘贴）按旧串长度补 Backspace 再重发，
  // 这样候选串的变化不会漏到远端。
  private kbSendReplace(prev: string, next: string): void {
    if (next.length > prev.length && next.startsWith(prev)) {
      RustDesk.text(next.substring(prev.length));
      return;
    }
    if (prev.length > 0) {
      // 退格：press=1 让服务端 down+up 成一次完整按键。
      for (let i = 0; i < prev.length; i++) {
        RustDesk.key('VK_BACK', true, this.mods);
      }
    }
    if (next.length > 0) {
      RustDesk.text(next);
    }
  }

  private onKbChange(value: string): void {
    const prev: string = this.kbText;
    if (value === prev) {
      return;
    }
    this.kbSendReplace(prev, value);
    this.kbText = value;
  }

  // --- UI -----------------------------------------------------------------

  // 宽屏（PC/平板）才在图标旁边带文字。手机竖屏 360 宽塞六个按钮会挤成一团，
  // 图标-only 更省地方；PC 窗口通常 1000+ 宽，纯图标反而不好认。
  private wide(): boolean {
    return this.areaW >= 640;
  }

  // 顶栏按钮：图标 +（宽屏时）文字。点击区高 40、最小宽 40，保证触屏也够按。
  @Builder
  barBtn(icon: string, label: string, color: string, onTap: () => void) {
    Row({ space: 6 }) {
      Text(icon)
        .fontSize(18)
        .fontColor(color)
      if (this.wide()) {
        Text(label)
          .fontSize(13)
          .fontColor(color)
          .maxLines(1)
      }
    }
    .height(40)
    .constraintSize({ minWidth: 40 })
    .padding({ left: this.wide() ? 10 : 0, right: this.wide() ? 10 : 0 })
    .justifyContent(FlexAlign.Center)
    .borderRadius(8)
    .onClick(() => { onTap(); })
  }

  @Builder
  topBar() {
    Row({ space: this.wide() ? 4 : 0 }) {
      Text('←')
        .fontSize(22)
        .fontColor('#FFFFFF')
        .width(40)
        .textAlign(TextAlign.Center)
        .onClick(() => { router.back(); })

      Column() {
        Text(this.peerId.length > 0 ? this.peerId : '会话')
          .fontSize(15)
          .fontColor('#FFFFFF')
          .maxLines(1)
        Text(this.statusText)
          .fontSize(11)
          .fontColor(this.connected ? '#4CD964' : '#8A94A6')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 4 })

      // 操作按钮全部收进底部工具栏 —— 与 Android 一致：remote_page.dart 的
      // getBottomAppBar() 把 ✕/显示器/键盘/模式/更多都放在底栏，顶栏不放操作。
      // 这里顶栏只保留返回与连接状态（鸿蒙的返回不像 Android 有系统返回键，
      // 必须给一个显式入口）。
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 8 })
    .backgroundColor('#CC0B1220')
  }

  // --- 底部工具栏 ---------------------------------------------------------
  //
  // 照 Android 的 getBottomAppBar()（remote_page.dart:602）做：一条 accent 色的
  // 底栏，左侧是操作图标，右侧是收起按钮。Android 那一条从左到右是
  // ✕关闭 / 📺显示器 / ⌨键盘 / 触摸-鼠标模式 / 💬聊天 / ⋮更多，右边 ⌄收起。
  // 这里按鸿蒙端实际打通的能力取舍：断开、显示器、键盘、滚动、CAD、刷新。
  @Builder
  bottomBar() {
    Row({ space: this.wide() ? 4 : 0 }) {
      this.barBtn('✕', '断开', '#FFFFFF', () => { this.disconnect(); })
      this.barBtn('▣', '显示器', '#FFFFFF', () => { this.openDisplayPicker(); })
      this.barBtn('⌨', '键盘', this.kbVisible ? '#FFD54F' : '#FFFFFF',
        () => { this.toggleKeyboard(); })
      this.barBtn('↕', '滚动', this.scrollMode ? '#FFD54F' : '#FFFFFF',
        () => { this.toggleScroll(); })
      this.barBtn('⌘', 'CAD', '#FFFFFF', () => { this.sendCtrlAltDel(); })
      this.barBtn('⋮', '更多', '#FFFFFF', () => { this.openMore(); })
      Blank()
      this.barBtn('⌄', '收起', '#FFFFFF', () => { this.barVisible = false; })
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 8 })
    .backgroundColor('#0071FF')  // MyTheme.accent，与 Android 的 BottomAppBar 同色
  }

  // 收起后留一个小把手，点一下把工具栏召回来。
  @Builder
  bottomBarArea() {
    Column() {
      if (this.barVisible) {
        this.bottomBar()
      } else {
        Row() {
          Text('⌃')
            .fontSize(16)
            .fontColor('#FFFFFF')
        }
        .width(72)
        .height(26)
        .justifyContent(FlexAlign.Center)
        .borderRadius(13)
        .backgroundColor('#990071FF')
        .margin({ bottom: 6 })
        .onClick(() => { this.barVisible = true; })
      }
    }
    .width('100%')
  }

  // 断开并回主页。注意顺序：先关会话再回退，否则会话还活着，
  // 下次连同一个 ID 时会被「已有会话」挡住。
  private disconnect(): void {
    RustDesk.closeSession();
    router.back();
  }

  // Android 点 📺 是弹出「显示器 / 视图」菜单让用户选（remote_page.dart:622
  // showOptions）。这里同样给列表而不是盲切：盲切在两台以上显示器时用户
  // 根本不知道当前切到了哪一台。只有一个显示器时直接说明。
  private openDisplayPicker(): void {
    const n: number = (RustDesk.state().displays ?? []).length;
    if (n <= 1) {
      promptAction.showToast({ message: '远端只有一个显示器' });
      return;
    }
    this.displayPickerVisible = true;
  }

  // 显示器列表每次现场从会话状态取：远端可能随时插拔屏幕，
  // 缓存一份反而会指着已经不存在的下标。
  private displayItems(): RemoteDisplay[] {
    return RustDesk.state().displays ?? [];
  }

  private pickDisplay(index: number): void {
    const rc: number = RustDesk.switchDisplay(index);
    if (rc !== 0) {
      promptAction.showToast({ message: `切换显示器失败（${rc}）` });
      return;
    }
    this.displayIndex = index;
    this.displayPickerVisible = false;
    promptAction.showToast({ message: `已切到显示器 ${index + 1}` });
  }

  private toggleKeyboard(): void {
    this.kbVisible = !this.kbVisible;
    this.kbText = '';
    if (this.kbVisible) {
      // 组件要等这一帧渲染出来才存在，抢焦点必须延后一拍。
      setTimeout(() => {
        this.getUIContext().getFocusController().requestFocus('rdKbInput');
      }, 80);
    }
  }

  private toggleScroll(): void {
    this.scrollMode = !this.scrollMode;
    this.scrollAccum = 0;
    promptAction.showToast({
      message: this.scrollMode ? '滚动模式：单指上下滑 = 滚轮' : '滚动模式已关闭'
    });
  }

  private sendCtrlAltDel(): void {
    const rc: number = RustDesk.ctrlAltDel();
    if (rc !== 0) {
      promptAction.showToast({ message: `发送 Ctrl+Alt+Del 失败（${rc}）` });
    }
  }

  // --- 「更多」菜单 --------------------------------------------------------
  //
  // 对齐 Android 的 showActions（remote_page.dart:821）+ toolbarControls
  // （common/widgets/toolbar.dart:447）。Android 是从底部弹一个 popup menu，
  // 这里做成底部面板 —— 鸿蒙上底部面板更好点，且能放输入框（OS 密码）。
  //
  // 只保留鸿蒙侧**真的接了 ABI** 的项。音量/电源这类没有 VK_ 名字的键走
  // HID usage（见 RustDesk.tapHidKey 的注释）。

  private openMore(): void {
    this.peerPlatform = RustDesk.peerPlatform();
    this.recording = RustDesk.isRecording();
    this.moreVisible = true;
  }

  // 菜单项在普通方法里拼：@Builder 内不允许写语句，且这样也更好读。
  private moreItems(): MoreItem[] {
    const out: MoreItem[] = [];
    const plat: string = this.peerPlatform;
    const isAndroid: boolean = plat === 'Android';
    const isWin: boolean = plat === 'Windows';
    const canRestart: boolean = isWin || plat === 'Linux' || plat === 'MacOS';

    if (isAndroid) {
      out.push(new MoreItem('返回', () => { this.mobileBack(); }));
      out.push(new MoreItem('主页', () => { this.mobileHome(); }));
      out.push(new MoreItem('最近任务', () => { this.mobileApps(); }));
      out.push(new MoreItem('音量 +', () => { RustDesk.tapHidKey(RustDesk.HID_VOLUME_UP); }));
      out.push(new MoreItem('音量 -', () => { RustDesk.tapHidKey(RustDesk.HID_VOLUME_DOWN); }));
      out.push(new MoreItem('静音', () => { RustDesk.tapHidKey(RustDesk.HID_MUTE); }));
      out.push(new MoreItem('电源', () => { RustDesk.tapHidKey(RustDesk.HID_POWER); }));
    }

    // OS 密码：远端停在 UAC / 锁屏登录框时用它把密码送过去。
    out.push(new MoreItem('OS 密码', () => {
      this.moreVisible = false;
      this.osPwdInput = '';
      this.osPwdVisible = true;
    }));
    out.push(new MoreItem('提升权限', () => { this.elevate(); }));
    // 发送剪贴板按键：把本机剪贴板文字整段打到远端。
    // Android 被控端没有物理键盘概念，上游也排除了它。
    if (!isAndroid) {
      out.push(new MoreItem('发送剪贴板按键', () => { this.sendClipboardKeystrokes(); }));
    }
    out.push(new MoreItem('重置画布', () => { this.resetCanvas(); }));
    out.push(new MoreItem('插入 Ctrl + Alt + Del', () => { this.sendCtrlAltDel(); }));
    out.push(new MoreItem('锁定屏幕', () => { this.lockScreen(); }));
    if (canRestart) {
      out.push(new MoreItem('重启远端设备', () => { this.restartRemote(); }, '', true));
    }
    out.push(new MoreItem('刷新画面', () => { RustDesk.refresh(0); }));
    out.push(new MoreItem(this.recording ? '停止会话录制' : '开始会话录制',
      () => { this.toggleRecord(); }, this.recording ? '录制中' : ''));
    out.push(new MoreItem('操作说明', () => {
      this.moreVisible = false;
      this.helpVisible = true;
    }));

    return out;
  }

  // Android 被控端的三个导航键。
  //
  // 上游 input_model.dart:2449 也是这么做的：Back = 鼠标「后退键」单击，
  // Home = 中键单击，最近任务 = 中键长按 500ms。它们本来就是被控端
  // 把鼠标侧键映射成了 Android 的系统导航。
  private mobileBack(): void {
    this.tapMouse(MouseButton.BACK);
  }

  // 中键在 RustDesk 协议里就是 WHEEL 这一位（0x04，见 common.rs:87 起那张表：
  // LEFT/RIGHT/WHEEL/BACK/FORWARD，没有单独的 middle）。上游
  // input_model.dart:2461 的 Home 也是发 MouseButtons.wheel。
  private mobileHome(): void {
    this.tapMouse(MouseButton.WHEEL);
  }

  private mobileApps(): void {
    const x: number = this.lastDispX;
    const y: number = this.lastDispY;
    RustDesk.mouse(mouseMask(MouseButton.WHEEL, MouseType.DOWN), x, y, this.mods);
    setTimeout(() => {
      RustDesk.mouse(mouseMask(MouseButton.WHEEL, MouseType.UP), x, y, this.mods);
    }, 500);
  }

  // 用某个鼠标键在**当前光标位置**点一下（按下+抬起）。
  // 坐标用 lastDisp 而不是重新换算：点导航键时手指并不在画面上。
  private tapMouse(btn: number): void {
    const x: number = this.lastDispX;
    const y: number = this.lastDispY;
    RustDesk.mouse(mouseMask(btn, MouseType.DOWN), x, y, this.mods);
    RustDesk.mouse(mouseMask(btn, MouseType.UP), x, y, this.mods);
  }

  private elevate(): void {
    const rc: number = RustDesk.elevateDirect();
    promptAction.showToast({ message: rc === 0 ? '已发送提权请求' : `提权失败（${rc}）` });
  }

  // 读本机剪贴板 → 整段打到远端。
  //
  // 走 RustDesk.text()（KeyEvent.seq 通道）而不是逐键：中文、符号都能发，
  // 而且不受两端键位布局影响。这也正是 Android 的
  // 「Send clipboard keystrokes」做的事（session_input_string）。
  private sendClipboardKeystrokes(): void {
    try {
      const pb: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      pb.getData((err: BusinessError, data: pasteboard.PasteData) => {
        if (err) {
          promptAction.showToast({ message: '读取剪贴板失败' });
          return;
        }
        let text: string = '';
        if (data.getPrimaryText() !== undefined) {
          text = data.getPrimaryText();
        }
        if (text.length === 0) {
          promptAction.showToast({ message: '剪贴板是空的' });
          return;
        }
        RustDesk.text(text);
        promptAction.showToast({ message: `已发送 ${text.length} 个字符` });
      });
    } catch (e) {
      promptAction.showToast({ message: '读取剪贴板失败' });
    }
  }

  // 重置画布：把画面重新拉一帧关键帧。
  //
  // 鸿蒙端的画面是按远端分辨率等比居中的，没有上游那套滚动/缩放偏移，
  // 所以「重置」实际等价于请求关键帧。
  private resetCanvas(): void {
    RustDesk.refresh(0);
    promptAction.showToast({ message: '画布已重置' });
  }

  private lockScreen(): void {
    const rc: number = RustDesk.lockScreen();
    promptAction.showToast({ message: rc === 0 ? '已发送锁屏' : `锁屏失败（${rc}）` });
  }

  private restartRemote(): void {
    const rc: number = RustDesk.restartRemote();
    if (rc === 0) {
      promptAction.showToast({ message: '已发送重启指令' });
      this.moreVisible = false;
    } else {
      promptAction.showToast({ message: `重启失败（${rc}）` });
    }
  }

  private toggleRecord(): void {
    const next: boolean = !this.recording;
    const rc: number = RustDesk.recordScreen(next);
    if (rc !== 0) {
      promptAction.showToast({ message: `录屏操作失败（${rc}）` });
      return;
    }
    this.recording = next;
    promptAction.showToast({ message: next ? '开始录制' : '停止录制' });
  }

  // OS 密码弹窗的两个按钮：只填进去 / 填完回车。
  private submitOsPassword(activate: boolean): void {
    const pw: string = this.osPwdInput;
    if (pw.length === 0) {
      promptAction.showToast({ message: '请输入密码' });
      return;
    }
    const rc: number = RustDesk.inputOsPassword(pw, activate);
    if (rc !== 0) {
      promptAction.showToast({ message: `发送失败（${rc}）` });
      return;
    }
    this.osPwdVisible = false;
    this.osPwdInput = '';
    promptAction.showToast({ message: activate ? '已发送并回车' : '已发送' });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 黑底：XComponent 按视频比例居中后，两侧/上下留的就是这个颜色。
      Column().width('100%').height('100%').backgroundColor('#000000')

      if (this.remoteW > 0 && this.remoteH > 0) {
        XComponent({
          id: 'rdSurface',
          // 试过换成 TEXTURE（渲染到 GPU 纹理由 ArkUI 合成，不占独立图层）：
          // 画面照常显示，但点击照样把指针甩出窗口 —— 合成路径不是原因。
          // 保留 SURFACE：走显示子系统（DSS）合成，比 TEXTURE 的 GPU 合成省电。
          type: XComponentType.SURFACE,
          libraryname: 'entry'
        })
          .width(this.displayW())
          .height(this.displayH())
          // 试过给它加 .hitTestBehavior(HitTestMode.None) 想让画面层退出命中
          // 测试：无效。Surface 类型的 XComponent 是独立图层，不吃 ArkUI 的
          // hitTestBehavior。要影响命中只能从上层浮层那侧改（见浮层的注释）。
      }

      // 质量监视器：左上角小字，显示 网速 / FPS / 延迟 / 编解码格式（含 4:4:4）。
      // 开关来自设置页「显示质量监视器」，数据来自 Rust 的 quality_status 事件。
      // position 挂在 Stack 坐标系上，y=64 让它落在 topBar（高 56）下方。
      if (this.qmVisible && this.connected && this.qmText().length > 0) {
        Text(this.qmText())
          .fontSize(11)
          .fontColor('#FFFFFF')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('#99000000')
          .borderRadius(4)
          .position({ x: 8, y: 64 })
      }

      // 远程光标：只有对端光标**没有**内嵌进视频帧时才本地画（内嵌时画面里
      // 已经有指针，再画一个就重影）。白色圆点黑描边，保证任何背景下可见。
      if (this.showRemoteCursor && !this.cursorEmbedded && this.remoteCursorX >= 0) {
        Column()
          .width(14)
          .height(14)
          .borderRadius(7)
          .backgroundColor('#FFFFFF')
          .border({ width: 2, color: '#1A1A1A' })
          .position({ x: this.remoteCursorX - 7, y: this.remoteCursorY - 7 })
      }

      // 浮层：顶部状态栏 + 底部提示 + 密码弹窗
      Column() {
        this.topBar()
        Blank()
        // 画面没出来之前一直显示进度/状态；图片一旦渲染就收起，
        // 避免遮住远端桌面。
        if (!this.connected || this.remoteW === 0) {
          Row() {
            Text(this.statusText)
              .fontSize(14)
              .fontColor(this.failed ? '#FF6B6B' : '#FFFFFF')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor('#CC161E2E')
              .borderRadius(20)
          }
          .margin({ bottom: 48 })
        }

        // 底部工具栏（Android 的 BottomAppBar）。放在软键盘条**上面**：
        // 输入法弹出时软键盘条要贴着输入法，工具栏不该插在中间。
        this.bottomBarArea()

        // 软键盘条：只有按下 ⌨ 才出现。放在浮层最底部，输入法弹出时
        // 这整条会被顶到输入法上方，正好接住用户的手指。
        if (this.kbVisible) {
          Row({ space: 6 }) {
            TextInput({ text: this.kbText, placeholder: '输入到远端…' })
              .id('rdKbInput')
              .layoutWeight(1)
              .height(40)
              .fontSize(14)
              .fontColor('#FFFFFF')
              .placeholderColor('#8A94A6')
              .backgroundColor('#33FFFFFF')
              .borderRadius(8)
              .caretColor('#4CD964')
              .enterKeyType(EnterKeyType.Send)
              .onChange((v: string) => { this.onKbChange(v); })
              .onSubmit((_: EnterKeyType) => {
                // 回车单独发：远端对话框、终端、登录框都靠它。
                RustDesk.key('VK_RETURN', true, this.mods);
                this.kbText = '';
              })
            // 软键盘上没有 Esc / Tab，但远端经常需要（关对话框、切换焦点）。
            Text('Esc')
              .fontSize(13)
              .fontColor('#FFFFFF')
              .height(40)
              .padding({ left: 10, right: 10 })
              .backgroundColor('#33FFFFFF')
              .borderRadius(8)
              .textAlign(TextAlign.Center)
              .onClick(() => { RustDesk.key('VK_ESCAPE', true, this.mods); })
            Text('Tab')
              .fontSize(13)
              .fontColor('#FFFFFF')
              .height(40)
              .padding({ left: 10, right: 10 })
              .backgroundColor('#33FFFFFF')
              .borderRadius(8)
              .textAlign(TextAlign.Center)
              .onClick(() => { RustDesk.key('VK_TAB', true, this.mods); })
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .backgroundColor('#CC0B1220')
        }
      }
      .width('100%')
      .height('100%')
      // 命中模式：Transparent = 自身和子节点都响应，但**不阻塞兄弟节点**，
      // 事件因此还能穿到下层 XComponent。这是当前唯一「触控点击可用」的组合 ——
      // 改过 Default（阻塞兄弟、不让事件碰 Surface），结果抬手事件整个断流，
      // 单击反而彻底失效。默认值 Default 会导致「画面在动、点哪儿都没反应」
      // 是当年 onTouch 还挂在 XComponent 上的旧结构，现在挂在最外层 Stack 上，
      // 两种模式都收得到；别再轻易改这一个枚举。
      .hitTestBehavior(HitTestMode.Transparent)

      if (this.showPasswordDialog) {
        this.passwordDialog()
      }

      if (this.showInsecureDialog) {
        this.insecureDialog()
      }

      if (this.moreVisible) {
        this.moreMenu()
      }

      if (this.osPwdVisible) {
        this.osPasswordDialog()
      }

      if (this.helpVisible) {
        this.helpSheet()
      }

      if (this.displayPickerVisible) {
        this.displayPicker()
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const w: number = newArea.width as number;
      const h: number = newArea.height as number;
      // 2in1 拉窗口 / 旋转 / 分屏都会走到这里。画面尺寸 displayW()/displayH()
      // 完全由它推导，所以这条日志是排查「画面不跟随窗口」的第一现场。
      hilog.info(DOMAIN, TAG, 'area %{public}d x %{public}d -> %{public}d x %{public}d',
        Math.round(oldArea.width as number), Math.round(oldArea.height as number),
        Math.round(w), Math.round(h));
      this.areaW = w;
      this.areaH = h;
    })
    // 触摸/键盘统一挂在最外层 Stack 上。
    //
    // 为什么不挂在 XComponent 上：浮层（状态栏 + 提示）铺满全屏且在上层，
    // XComponent 的 onTouch 一条都收不到（实测日志里没有任何触摸事件）。
    // 挂在 Stack 上最稳，坐标换算时再减掉画面居中的黑边偏移即可。
    .onTouch((ev: TouchEvent) => { this.handleTouch(ev); })
    // 鼠标通道：只对「真实 PC / 平板」注册，模拟器不注册。原因见文件头
    // isRealDesktopDevice 的注释 —— 模拟器把 guest 指针位置回写本机光标时
    // 缩放方向反了（实测放大 ~3.3 倍），一注册就把指针甩到窗口外。
    // 真机（2in1 笔记本 Window / 平板接鼠标）走这条通道最准：hover 移动、
    // 左右中侧键、拖拽 mask 都按远端协议映射好了。
    .attributeModifier(this.mouseMod)
    // 滚轮：轴事件与 onMouse 是两条独立通道，注册它不会触发上面的回写 bug，
    // 所以无条件挂载 —— 手机接鼠标、PC 触控板都能滚。
    .onAxisEvent((ev: AxisEvent) => { this.handleAxis(ev); })
    .onKeyEvent((ev: KeyEvent) => { this.handleKey(ev); })
    // 键盘事件只发给有焦点的节点；桌面形态（2in1）尤其如此。
    .focusable(true)
    .defaultFocus(true)
  }

  // --- 「更多」菜单面板 ----------------------------------------------------
  //
  // 底部面板，占屏高的 62%，列表可滚。Android 是从底部弹 popup menu，
  // 鸿蒙上做成面板更好点（条目多、要放得下 OS 密码的输入框）。
  @Builder
  moreRow(it: MoreItem) {
    Row() {
      Text(it.label)
        .fontSize(15)
        .fontColor(it.danger ? '#FF6B6B' : '#FFFFFF')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (it.hint.length > 0) {
        Text(it.hint)
          .fontSize(12)
          .fontColor('#FFC53D')
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 18, right: 18 })
    .onClick(() => { it.act(); })
  }

  @Builder
  moreMenu() {
    Column() {
      // 上半部分是遮罩，点一下关闭（与底部弹层的习惯一致）。
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => { this.moreVisible = false; })

      Column() {
        Row() {
          Text('更多操作')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
          if (this.peerPlatform.length > 0) {
            Text(this.peerPlatform)
              .fontSize(12)
              .fontColor('#8A94A6')
              .margin({ left: 8 })
          }
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor('#8A94A6')
            .onClick(() => { this.moreVisible = false; })
        }
        .width('100%')
        .height(48)
        .padding({ left: 18, right: 18 })

        Divider()
          .color('#1F2A3D')

        List() {
          ForEach(this.moreItems(), (it: MoreItem) => {
            ListItem() {
              this.moreRow(it);
            }
          }, (it: MoreItem) => it.label)
        }
        .width('100%')
        .layoutWeight(1)
        .divider({ strokeWidth: 1, color: '#16202F', startMargin: 18, endMargin: 18 })
      }
      .width('100%')
      .height('62%')
      .backgroundColor('#0F1726')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
  }

  // --- 手势说明 ------------------------------------------------------------
  //
  // 对应 Android 的 KeyHelpTools / _showGestureHelp（remote_page.dart 里由
  // 底栏的模式按钮切换）。Android 用一行小字贴在画面底部，这里做成面板：
  // 条目多（含滚动模式），一行放不下，而且从「更多」里进来更自然。

  @Builder
  helpLine(gesture: string, effect: string) {
    Row() {
      Text(gesture)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width(120)
        .textAlign(TextAlign.Start)
      Text(effect)
        .fontSize(13)
        .fontColor('#8A94A6')
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  helpSheet() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => { this.helpVisible = false; })

      Column() {
        Row() {
          Text('操作说明')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor('#8A94A6')
            .onClick(() => { this.helpVisible = false; })
        }
        .width('100%')
        .height(48)
        .padding({ left: 18, right: 18 })

        Divider()
          .color('#1F2A3D')

        Scroll() {
          Column() {
            this.helpLine('单指点击', '左键单击')
            this.helpLine('单指长按', '右键单击（约 0.5 秒）')
            this.helpLine('单指拖动', '按住左键拖动')
            this.helpLine('双指上下滑', '滚轮滚动')
            this.helpLine('滚动模式', '底栏 ↕ 打开后，单指上下滑就是滚轮，且不会误触点击')
            this.helpLine('鼠标滚轮', '滚轮滚动（接鼠标 / 触控板时）')
            this.helpLine('物理键盘', '直接发到远端（2in1 / 外接键盘）')

            Text('本机 UI 不发给远端')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#2F81F7')
              .width('100%')
              .margin({ top: 16, bottom: 6 })
            Text('画面顶部 56vp（顶栏）与底部 56vp（工具栏）属于本机界面，'
              + '在这两处操作不会在远端产生点击。')
              .fontSize(12)
              .fontColor('#5A6478')
              .lineHeight(18)
              .width('100%')
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 12, bottom: 18 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('62%')
      .backgroundColor('#0F1726')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
  }

  // 显示器选择：把远端每个屏按分辨率列出来让用户点。
  @Builder
  displayPicker() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => { this.displayPickerVisible = false; })

      Column() {
        Row() {
          Text('选择显示器')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor('#8A94A6')
            .onClick(() => { this.displayPickerVisible = false; })
        }
        .width('100%')
        .height(48)
        .padding({ left: 18, right: 18 })

        Divider()
          .color('#1F2A3D')

        List() {
          ForEach(this.displayItems(), (d: RemoteDisplay, idx: number) => {
            ListItem() {
              Row() {
                Text(`显示器 ${idx + 1}`)
                  .fontSize(15)
                  .fontColor(idx === this.displayIndex ? '#2F81F7' : '#FFFFFF')
                  .layoutWeight(1)
                Text(`${d.width}×${d.height}`)
                  .fontSize(12)
                  .fontColor('#5A6478')
                if (idx === this.displayIndex) {
                  Text('当前')
                    .fontSize(12)
                    .fontColor('#FFC53D')
                    .margin({ left: 8 })
                }
              }
              .width('100%')
              .height(52)
              .padding({ left: 18, right: 18 })
              .onClick(() => { this.pickDisplay(idx); })
            }
          }, (d: RemoteDisplay, idx: number) => idx.toString())
        }
        .width('100%')
        .divider({ strokeWidth: 1, color: '#16202F', startMargin: 18, endMargin: 18 })
      }
      .width('100%')
      .backgroundColor('#0F1726')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
  }

  // OS 密码弹窗：远端停在 UAC / 锁屏登录框时把密码送过去。
  //
  // 两个按钮对应上游的两个动作（toolbar.dart:487）：
  //   「发送」= input_os_password(activate=false)
  //   「发送并回车」= 填完直接提交，省一次操作
  @Builder
  osPasswordDialog() {
    Column() {
      Column() {
        Text('OS 密码')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .margin({ bottom: 8 })

        Text('发送到远端的系统登录界面（UAC、锁屏登录框）。')
          .fontSize(13)
          .fontColor('#8A94A6')
          .width('100%')
          .margin({ bottom: 14 })

        TextInput({ placeholder: '远端系统账号的密码', text: this.osPwdInput })
          .type(InputType.Password)
          .height(48)
          .fontSize(16)
          .backgroundColor('#161E2E')
          .fontColor('#FFFFFF')
          .placeholderColor('#5A6478')
          .borderRadius(10)
          .onChange((v: string) => { this.osPwdInput = v; })
          .margin({ bottom: 18 })

        Row() {
          Button('取消')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .backgroundColor('#1B2536')
            .fontColor('#C7D0E0')
            .borderRadius(10)
            .margin({ right: 8 })
            .onClick(() => {
              this.osPwdVisible = false;
              this.osPwdInput = '';
            })

          Button('发送')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .backgroundColor('#1B2536')
            .fontColor('#C7D0E0')
            .borderRadius(10)
            .margin({ right: 8 })
            .onClick(() => { this.submitOsPassword(false); })

          Button('发送并回车')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#2F81F7')
            .borderRadius(10)
            .onClick(() => { this.submitOsPassword(true); })
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .backgroundColor('#0F1726')
      .borderRadius(16)
      .border({ width: 1, color: '#1E2A3F' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  passwordDialog() {
    // 半透明遮罩 + 居中卡片。不用 promptAction.showDialog：那没法放输入框。
    Column() {
      Column() {
        Text('需要密码')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .margin({ bottom: 8 })

        Text(this.passwordHint)
          .fontSize(13)
          .fontColor('#8A94A6')
          .width('100%')
          .margin({ bottom: 14 })

        TextInput({ placeholder: '访问密码', text: this.passwordInput })
          .type(InputType.Password)
          .height(48)
          .fontSize(16)
          .backgroundColor('#161E2E')
          .fontColor('#FFFFFF')
          .placeholderColor('#5A6478')
          .borderRadius(10)
          .onChange((v: string) => { this.passwordInput = v; })
          .onSubmit(() => { this.submitPassword(); })
          .margin({ bottom: 12 })

        Row() {
          Toggle({ type: ToggleType.Checkbox, isOn: this.rememberPassword })
            .onChange((isOn: boolean) => { this.rememberPassword = isOn; })
          Text('记住密码（下次自动登录）')
            .fontSize(13)
            .fontColor('#C7D0E0')
          Blank()
        }
        .width('100%')
        .margin({ bottom: 18 })

        Row() {
          Button('取消')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .backgroundColor('#1B2536')
            .fontColor('#C7D0E0')
            .borderRadius(10)
            .margin({ right: 10 })
            .onClick(() => { this.cancelPassword(); })

          Button('确定')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#2F81F7')
            .borderRadius(10)
            .onClick(() => { this.submitPassword(); })
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .backgroundColor('#0F1726')
      .borderRadius(16)
      .border({ width: 1, color: '#1E2A3F' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  insecureDialog() {
    Column() {
      Column() {
        Text('此连接未加密')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFC857')
          .margin({ bottom: 10 })

        Text('未与对端建立端到端加密。继续连接时，画面和键鼠操作只能依赖中继链路保护。')
          .fontSize(13)
          .fontColor('#C7D0E0')
          .lineHeight(20)
          .width('100%')
          .margin({ bottom: 8 })

        Text('如果这是你自己的服务器，请先在「设置」里填入服务器公钥（id_ed25519.pub 的内容），再重连就不会出现此提示。')
          .fontSize(12)
          .fontColor('#8A94A6')
          .lineHeight(18)
          .width('100%')
          .margin({ bottom: 18 })

        Row() {
          Button('取消')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .backgroundColor('#1B2536')
            .fontColor('#C7D0E0')
            .borderRadius(10)
            .margin({ right: 10 })
            .onClick(() => { this.answerInsecure(false); })

          Button('仍然继续')
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#B8860B')
            .borderRadius(10)
            .onClick(() => { this.answerInsecure(true); })
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .backgroundColor('#0F1726')
      .borderRadius(16)
      .border({ width: 1, color: '#3A2E14' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
  }
}
