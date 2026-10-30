import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import {
  RustDesk, UiEvent, DisplayEventData, ConnectedEventData, CloseEventData,
  BlockInputEventData, SessionState, Modifiers, MouseType, MouseButton, mouseMask
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

const LONG_PRESS_MS: number = 500;
const MOVE_THRESHOLD_PX: number = 6;
// 双指滚动：累计到这个像素数才发一次滚轮，避免一次滑动刷出几十个事件。
const WHEEL_STEP_PX: number = 32;

@Entry
@Component
struct SessionPage {
  @State peerId: string = '';
  @State statusText: string = '连接中…';
  @State connected: boolean = false;
  @State failed: boolean = false;
  // 远端画面分辨率（来自 display 事件）
  @State remoteW: number = 0;
  @State remoteH: number = 0;
  // 可用区域（来自 onAreaChange）
  @State areaW: number = 0;
  @State areaH: number = 0;

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

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null && params['peerId'] !== undefined) {
      this.peerId = params['peerId'] as string;
    }
    RustDesk.on(this.onCoreEvent);

    // 页面可能是在会话已建立之后才重建的（切后台再回来），
    // 所以先读一次状态快照，不能只依赖事件。
    const st: SessionState = RustDesk.state();
    this.applyState(st);
  }

  aboutToDisappear(): void {
    RustDesk.off(this.onCoreEvent);
    this.clearLongPress();
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
        }
        break;
      }
      case 'connected': {
        const d: ConnectedEventData = ev.data as ConnectedEventData;
        this.connected = true;
        this.statusText = '已连接';
        break;
      }
      case 'connection_type': {
        this.statusText = '已连接';
        break;
      }
      case 'close': {
        const d: CloseEventData = ev.data as CloseEventData;
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
      case 'msgbox': {
        // M1 只提示，不做完整对话框（密码重试在 M2 补）。
        promptAction.showToast({ message: '远端弹出了提示框' });
        break;
      }
      default:
        // rgba 事件由 C++ 渲染线程自己拉帧，ArkTS 不需要处理。
        break;
    }
  }

  // --- 坐标换算 -----------------------------------------------------------
  // XComponent 的尺寸按远端宽高比设置（见 build 里的 displayW/displayH），
  // 所以这里就是纯线性映射，没有黑边偏移。
  private displayW(): number {
    if (this.areaW <= 0 || this.areaH <= 0 || this.remoteW <= 0 || this.remoteH <= 0) {
      return this.areaW;
    }
    const s: number = Math.min(this.areaW / this.remoteW, this.areaH / this.remoteH);
    return this.remoteW * s;
  }

  private displayH(): number {
    if (this.areaW <= 0 || this.areaH <= 0 || this.remoteW <= 0 || this.remoteH <= 0) {
      return this.areaH;
    }
    const s: number = Math.min(this.areaW / this.remoteW, this.areaH / this.remoteH);
    return this.remoteH * s;
  }

  private toRemote(lx: number, ly: number): Position {
    const dw: number = this.displayW();
    const dh: number = this.displayH();
    if (dw <= 0 || dh <= 0) {
      return new Position(0, 0);
    }
    return new Position(
      Math.round(lx * this.remoteW / dw),
      Math.round(ly * this.remoteH / dh)
    );
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
    // 先把之前按下的左键松掉，否则远端会认为左键一直按着。
    const p: Position = this.toRemote(this.pressStartX, this.pressStartY);
    if (this.moved) {
      return;  // 已经开始拖动了，不是长按
    }
    this.longPressFired = true;
    RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.UP), p.x, p.y, this.mods);
    RustDesk.mouse(mouseMask(MouseButton.RIGHT, MouseType.DOWN), p.x, p.y, this.mods);
    RustDesk.mouse(mouseMask(MouseButton.RIGHT, MouseType.UP), p.x, p.y, this.mods);
  };

  private handleTouch(ev: TouchEvent): void {
    if (!this.connected) {
      return;
    }
    const ts: TouchObject[] = ev.touches;

    // --- 双指：滚动 ------------------------------------------------------
    if (ts.length >= 2) {
      this.clearLongPress();
      if (!this.moved && this.pressStartX !== 0) {
        // 从单指切到双指：先补一个左键抬起，否则远端左键会粘住。
        const p: Position = this.toRemote(this.pressStartX, this.pressStartY);
        RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.UP), p.x, p.y, this.mods);
        this.moved = true;
      }
      const midY: number = (ts[0].y + ts[1].y) / 2;
      if (!this.twoFingerActive) {
        this.twoFingerActive = true;
        this.twoFingerY = midY;
        this.wheelAccum = 0;
        return;
      }
      const dy: number = midY - this.twoFingerY;
      this.twoFingerY = midY;
      this.wheelAccum += dy;
      if (Math.abs(this.wheelAccum) >= WHEEL_STEP_PX) {
        // 向上滑（dy < 0）在桌面上是「内容上移」= 滚轮向下。
        // RustDesk 的 wheel 用 y 的正负表示方向，向上滚为正。
        const steps: number = this.wheelAccum < 0 ? 1 : -1;
        const p: Position = this.toRemote(ts[0].x, ts[0].y);
        RustDesk.mouse(mouseMask(MouseButton.WHEEL, MouseType.WHEEL), p.x, steps, this.mods);
        this.wheelAccum = 0;
      }
      return;
    }

    this.twoFingerActive = false;

    const changed: TouchObject[] = ev.changedTouches;
    if (changed.length === 0) {
      return;
    }
    const t: TouchObject = changed[0];
    const p: Position = this.toRemote(t.x, t.y);

    switch (ev.type) {
      case TouchType.Down: {
        this.pressStartX = t.x;
        this.pressStartY = t.y;
        this.lastDispX = t.x;
        this.lastDispY = t.y;
        this.moved = false;
        this.longPressFired = false;
        RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.DOWN), p.x, p.y, this.mods);
        this.longPressTimer = setTimeout(this.fireLongPress, LONG_PRESS_MS);
        break;
      }
      case TouchType.Move: {
        const dx: number = t.x - this.pressStartX;
        const dy: number = t.y - this.pressStartY;
        if (!this.moved && dx * dx + dy * dy > MOVE_THRESHOLD_PX * MOVE_THRESHOLD_PX) {
          this.moved = true;
          this.clearLongPress();
        }
        if (this.moved && !this.longPressFired) {
          // 拖动时保持左键按下：mask 里带 LEFT 位。
          RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.MOVE), p.x, p.y, this.mods);
        }
        this.lastDispX = t.x;
        this.lastDispY = t.y;
        break;
      }
      case TouchType.Up:
      case TouchType.Cancel: {
        this.clearLongPress();
        if (!this.longPressFired) {
          // 单击 / 拖动结束都发一次左上抬。
          const end: Position = this.toRemote(this.lastDispX, this.lastDispY);
          RustDesk.mouse(mouseMask(MouseButton.LEFT, MouseType.UP), end.x, end.y, this.mods);
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
    if (!this.connected) {
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

  // --- UI -----------------------------------------------------------------

  @Builder
  topBar() {
    Row() {
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

      Text('⟳')
        .fontSize(20)
        .fontColor('#FFFFFF')
        .width(40)
        .textAlign(TextAlign.Center)
        .onClick(() => { RustDesk.refresh(0); })

      Text('⏻')
        .fontSize(18)
        .fontColor('#FF6B6B')
        .width(40)
        .textAlign(TextAlign.Center)
        .onClick(() => { router.back(); })
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 8 })
    .backgroundColor('#CC0B1220')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 黑底：XComponent 按视频比例居中后，两侧/上下留的就是这个颜色。
      Column().width('100%').height('100%').backgroundColor('#000000')

      if (this.remoteW > 0 && this.remoteH > 0) {
        XComponent({
          id: 'rdSurface',
          type: XComponentType.SURFACE,
          libraryname: 'entry'
        })
          .width(this.displayW())
          .height(this.displayH())
          .onTouch((ev: TouchEvent) => { this.handleTouch(ev); })
          .onKeyEvent((ev: KeyEvent) => { this.handleKey(ev); })
      }

      // 浮层：顶部状态栏 + 底部提示
      Column() {
        this.topBar()
        Blank()
        if (!this.connected) {
          Row() {
            Text(this.statusText)
              .fontSize(14)
              .fontColor('#FFFFFF')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor('#CC161E2E')
              .borderRadius(20)
          }
          .margin({ bottom: 48 })
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.areaW = newArea.width as number;
      this.areaH = newArea.height as number;
    })
  }
}
