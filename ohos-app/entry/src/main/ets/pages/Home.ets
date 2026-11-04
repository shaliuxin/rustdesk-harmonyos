import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { RustDesk, PeerInfo, UiEvent, ChatEventData } from '../common/RustDesk';
import { isPhoneForm } from '../common/DeviceForm';
import { SettingsPage } from './Settings';

// 主页：AppBar + 底部三个 tab（连接 / 共享屏幕 / 设置）。
//
// 结构照 RustDesk Android 的 HomePage 来：`flutter/lib/mobile/pages/home_page.dart`
// 用 Scaffold + BottomNavigationBar，Android 上依次是 ConnectionPage、ChatPage、
// ServerPage、SettingsPage。这里用 ArkUI 的 Tabs（barPosition = End）对应。
//
// 唯独**没有** ChatPage：安卓那一页列的是「RustDesk 账号的好友/会话列表」，
// 而自建服务器根本没有账号体系，页面永远是空壳（原先是「聊天暂未启用」）。
// 点对点聊天在两个真正需要它的地方：主控端在会话页底栏 💬，被控端在连接页
// 顶部的「正在被远程控制」横幅里，都不依赖账号。
//
// 配色取上游 MyTheme 的深色值（flutter/lib/common.dart）：
//   accent #0071FF、idColor #00B6F0、button #2C8CFF、darkGray #949494。
// 背景沿用本项目已有的深色体系（#0B1220 / #101827 / #161E2E）。
//
// ArkTS 的两个坑，都踩过一次：
//   1. 状态别叫 `tabIndex` —— CustomComponent 基类上已经有一个同名属性
//      （无障碍焦点顺序），重名会导致类型不兼容的编译错误。这里叫 currentTab。
//   2. @Builder 里**只能写 UI 组件语法**：const/let/for 这些普通语句要挪到
//      普通方法里算好，builder 里直接用结果。

const C_BG: string = '#0B1220';
const C_CARD: string = '#101827';
const C_FIELD: string = '#161E2E';
const C_ACCENT: string = '#0071FF';
const C_ID: string = '#00B6F0';
const C_TEXT: string = '#E6EDF7';
const C_DIM: string = '#8A94A6';
const C_FAINT: string = '#5A6478';
const C_DANGER: string = '#FF6B6B';
const C_DIVIDER: string = '#1F2A3D';
// ID 服务器连接状态圆点（与 Settings.ets 同一套配色）
const DOT_READY: string = '#22C55E';      // 绿：已正常连接
const DOT_CONNECTING: string = '#F5A524'; // 黄：正在连接
const DOT_FAILED: string = '#EF4444';     // 红：连接失败

const DOMAIN: number = 0x3200;
const TAG: string = 'RustDeskHome';

// 隐私政策的同意状态。应用市场审核要求首次启动展示并取得同意，
// 只存一个布尔值，键名带版本号便于将来条款实质变更时重新征询。
const PRIVACY_STORE: string = 'app_prefs';
const PRIVACY_KEY: string = 'privacy_accepted_v1';

@Entry
@Component
struct Home {
  // 注意：不能叫 tabIndex，见文件头注释第 1 条。
  @State currentTab: number = 0;

  // --- 连接页 ---
  @State peerId: string = '';
  @State peers: PeerInfo[] = [];
  // 0 = 最近会话，1 = 收藏（对应 Android PeerTabPage 的两个页签）
  @State peersTab: number = 0;
  @State connecting: boolean = false;

  // 首次启动的隐私政策同意遮罩（见 privacyMask / checkPrivacy）。
  @State showPrivacy: boolean = false;

  // --- 共享屏幕页 ---
  @State myId: string = '';
  @State myPassword: string = '';
  @State effectiveServer: string = '';
  @State permPwdEditing: boolean = false;
  @State permPwd: string = '';
  // ID 服务器连接状态（0=连接中 1=已连接 2=失败，见 RustDesk.SERVER_STATUS_*）。
  @State serverStatus: number = RustDesk.SERVER_STATUS_CONNECTING;
  // 轮询定时器；-1 表示没在跑。
  private statusTimer: number = -1;
  // 一次性密码被用掉后会在 Rust 侧自动更换，这里轮询把它同步到界面上，
  // 避免用户照着旧密码去念给对方听。
  private pwTimer: number = -1;
  // 被控状态轮询：开关之后注入授权与主机状态都是异步变化的。
  private hostTimer: number = -1;

  // 手机形态：被控能力平台不支持，「共享屏幕」这一档整体不渲染。
  // 在 aboutToAppear 里赋值（早于首次 build），不会出现先闪一下再消失。
  @State isPhone: boolean = false;

  // --- 远程协助（被控端，仅 2in1）---
  // 不做常驻服务：用户在这里手动开启，关掉即全部拆除。
  @State hostSupported: boolean = false;
  @State hostRunning: boolean = false;
  // 0 未授权 / 1 授权中 / 2 已授权（注入键鼠的前置条件）
  @State injectStatus: number = 0;
  // 开关正在处理中，避免连点重复起停
  @State hostBusy: boolean = false;

  // --- 被控端：当前会话与聊天 ---
  // 主控连进来后，这里要能看见「有人在控制我」并且能回话。
  // 消息不落盘，会话结束即清（与上游一致：聊天只活在连接里）。
  @State hostSessions: number = 0;
  @State hostChatOpen: boolean = false;
  @State hostChatText: string = '';
  @State hostChatMsgs: HostChatMsg[] = [];
  @State hostChatUnread: number = 0;
  private nextChatId: number = 1;

  aboutToAppear(): void {
    this.isPhone = isPhoneForm();
    this.refresh();
    this.checkPrivacy();

    // 远程协助：只在支持的形态上初始化（2in1）
    this.hostSupported = !this.isPhone && RustDesk.hostSupported();
    this.refreshHostState();

    // 与设置页同一套：Rust 看门狗每 3 秒探测一次，这里 1 秒读一次结果。
    this.refreshServerStatus();
    this.statusTimer = setInterval(this.refreshServerStatus, 1000);
    // 密码与注入授权都是「异步变化」的：一次性密码用过即换，注入授权走系统
    // 弹窗回调，都在开关之后才落地，界面必须自己轮询，否则会一直停在旧文案。
    this.pwTimer = setInterval(this.refreshPassword, 2000);
    this.hostTimer = setInterval(this.refreshHostState, 2000);

    // 被控端聊天：主控发来的消息由 Rust 侧转成 'host_chat' 事件。
    // 会话页只在主控时注册，被控端一直停在首页，必须这里接。
    RustDesk.on(this.onHostEvent);
  }

  // --- 隐私政策同意 ---------------------------------------------------------
  //
  // 应用市场审核硬要求：首次启动必须能展示隐私政策并取得用户同意。
  // 同意状态存 Preferences，此后不再打扰；条款实质变更时把 PRIVACY_KEY
  // 的版本号提升，用户会再被征询一次。

  private checkPrivacy(): void {
    try {
      const ctx: common.UIAbilityContext =
        getContext(this) as common.UIAbilityContext;
      const p = preferences.getPreferencesSync(ctx, { name: PRIVACY_STORE });
      const accepted = p.getSync(PRIVACY_KEY, false) as boolean;
      this.showPrivacy = !accepted;
    } catch (e) {
      // 读不到（首次安装、存储异常）就当作未同意，宁可多问一次。
      this.showPrivacy = true;
    }
  }

  private acceptPrivacy(): void {
    try {
      const ctx: common.UIAbilityContext =
        getContext(this) as common.UIAbilityContext;
      const p = preferences.getPreferencesSync(ctx, { name: PRIVACY_STORE });
      p.putSync(PRIVACY_KEY, true);
      p.flush();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'save privacy ack failed');
    }
    this.showPrivacy = false;
  }

  // 不同意就退出：不进入任何功能，避免「不同意但仍在使用」的合规瑕疵。
  private rejectPrivacy(): void {
    try {
      const ctx: common.UIAbilityContext =
        getContext(this) as common.UIAbilityContext;
      ctx.terminateSelf();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'terminateSelf failed');
    }
  }

  @Builder
  privacyMask() {
    Column() {
      Column() {
        Text('隐私政策')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .width('100%')
          .margin({ bottom: 12 })
        Text('本应用是开源 RustDesk 的远程桌面工具。\n\n'
          + '我们不收集你的个人信息，也不向第三方提供任何数据。'
          + '设备 ID、服务器配置与连接记录只保存在本机；'
          + '远程画面与文件在设备之间端到端加密传输。\n\n'
          + '请阅读并同意《隐私政策》后继续使用。')
          .fontSize(14)
          .fontColor(C_DIM)
          .lineHeight(22)
          .width('100%')
        Text('查看完整隐私政策 ›')
          .fontSize(13)
          .fontColor(C_ACCENT)
          .width('100%')
          .textAlign(TextAlign.End)
          .padding({ top: 10, bottom: 4 })
          .onClick(() => { router.pushUrl({ url: 'pages/Privacy' }); })
        Row() {
          Button('不同意')
            .fontSize(15)
            .fontColor(C_DIM)
            .backgroundColor(C_FIELD)
            .layoutWeight(1)
            .height(44)
            .onClick(() => { this.rejectPrivacy(); })
          Button('同意并继续')
            .fontSize(15)
            .fontColor('#FFFFFF')
            .backgroundColor(C_ACCENT)
            .layoutWeight(1)
            .height(44)
            .margin({ left: 12 })
            .onClick(() => { this.acceptPrivacy(); })
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('86%')
      .padding(22)
      .backgroundColor(C_CARD)
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#CC000000')
  }

  // 只在值真的变了才写状态：@State 每次赋值都会触发重渲染。
  private refreshPassword = (): void => {
    const pw = RustDesk.getConfig().temporaryPassword;
    if (pw !== this.myPassword) {
      this.myPassword = pw;
    }
  }

  // --- 远程协助 -------------------------------------------------------------

  private refreshHostState = (): void => {
    if (!this.hostSupported) {
      return;
    }
    this.hostRunning = RustDesk.hostRunning();
    this.injectStatus = RustDesk.injectionStatus();
    const n: number = RustDesk.hostSessions();
    if (n !== this.hostSessions) {
      this.hostSessions = n;
      // 对方挂断后把聊天记录清掉：这些消息只属于那一次会话。
      if (n === 0) {
        this.hostChatMsgs = [];
        this.hostChatUnread = 0;
        this.hostChatOpen = false;
        this.hostChatText = '';
      }
    }
  }

  // 被控端事件：目前只关心聊天。
  private onHostEvent = (ev: UiEvent): void => {
    if (ev.event !== 'host_chat') {
      return;
    }
    const d: ChatEventData = ev.data as ChatEventData;
    if (d === undefined || d.text === undefined || d.text.length === 0) {
      return;
    }
    this.pushHostChat(d.text, false);
    if (this.hostChatOpen) {
      this.hostChatUnread = 0;
    } else {
      this.hostChatUnread += 1;
      promptAction.showToast({ message: `对方发来消息：${d.text}` });
    }
  }

  private pushHostChat(text: string, mine: boolean): void {
    const list: HostChatMsg[] = this.hostChatMsgs.slice();
    list.push(new HostChatMsg(this.nextChatId++, text, mine));
    this.hostChatMsgs = list;
  }

  private sendHostChat(): void {
    const t: string = this.hostChatText.trim();
    if (t.length === 0) {
      return;
    }
    if (!RustDesk.hostSendChat(t)) {
      promptAction.showToast({ message: '发送失败：当前没有活动连接' });
      return;
    }
    this.pushHostChat(t, true);
    this.hostChatText = '';
  }

  private openHostChat(): void {
    this.hostChatUnread = 0;
    this.hostChatOpen = true;
  }

  private setHostPower(on: boolean): void {
    if (this.hostBusy) {
      return;
    }
    this.hostBusy = true;
    try {
      if (on) {
        // 先要注入授权（系统弹窗，用户同意后回调才会变成已授权）；
        // 采集授权在 hostStart 里由 AVScreenCapture 自己弹。
        RustDesk.requestInjection();
        const rc = RustDesk.hostStart();
        if (rc !== 0) {
          promptAction.showToast({ message: RustDesk.getLastError() || '启动失败' });
        }
      } else {
        RustDesk.hostStop();
      }
    } finally {
      this.hostBusy = false;
      this.refreshHostState();
    }
  }

  private hostStateText(): string {
    if (!this.hostRunning) {
      return '未开启';
    }
    if (this.hostSessions > 0) {
      return `正在被远程控制（${this.hostSessions} 个会话）`;
    }
    if (this.injectStatus === 2) {
      return '已开启，等待远程连接';
    }
    return '已开启（键鼠注入未授权，对方只能看）';
  }

  aboutToDisappear(): void {
    RustDesk.off(this.onHostEvent);
    if (this.statusTimer !== -1) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    if (this.pwTimer !== -1) {
      clearInterval(this.pwTimer);
      this.pwTimer = -1;
    }
    if (this.hostTimer !== -1) {
      clearInterval(this.hostTimer);
      this.hostTimer = -1;
    }
  }

  // 必须是**箭头函数属性**：普通方法当回调传出去会丢 this，
  // 运行期直接 "Obj is not a Valid object"。
  private refreshServerStatus = (): void => {
    this.serverStatus = RustDesk.serverStatus();
  }

  // 状态圆点颜色：绿=已连接、黄=正在连接、红=连接失败。
  private serverStatusColor(): string {
    if (this.serverStatus === RustDesk.SERVER_STATUS_READY) {
      return DOT_READY;
    }
    if (this.serverStatus === RustDesk.SERVER_STATUS_FAILED) {
      return DOT_FAILED;
    }
    return DOT_CONNECTING;
  }

  // 从会话页返回时最近列表会多一条，必须刷新：页面不会重建，只有 onPageShow 会来。
  onPageShow(): void {
    this.refresh();
  }

  private refresh(): void {
    const cfg = RustDesk.getConfig();
    this.myId = cfg.id;
    this.myPassword = cfg.temporaryPassword;
    this.effectiveServer = cfg.effectiveServer;
    this.peers = RustDesk.peers();
    hilog.info(DOMAIN, TAG, 'refresh id=%{public}d peers=%{public}d',
      this.myId.length, this.peers.length);
  }

  // --- 动作 ---------------------------------------------------------------

  private copy(text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '已复制' });
      }).catch((e: Error) => {
        promptAction.showToast({ message: `复制失败：${e.message}` });
      });
    } catch (e) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  private connect(id: string): void {
    const target: string = id.trim();
    if (target.length === 0) {
      promptAction.showToast({ message: '请输入远端 ID' });
      return;
    }
    if (!RustDesk.isInitialized()) {
      promptAction.showToast({ message: `核心未初始化：${RustDesk.getLastError()}` });
      return;
    }
    this.connecting = true;
    // startSession 只是「发起」，结果由会话页通过 connected / msgbox 事件上报，
    // 所以这里立刻跳过去，进度交给会话页显示。
    const rc: number = RustDesk.startSession(target, '', false);
    if (rc !== 0) {
      this.connecting = false;
      promptAction.showToast({ message: `发起连接失败（${rc}）：${RustDesk.getLastError()}` });
      return;
    }
    router.pushUrl({ url: 'pages/SessionPage', params: { peerId: target } }).catch((e: Error) => {
      this.connecting = false;
      promptAction.showToast({ message: `打开会话页失败：${e.message}` });
    });
    this.connecting = false;
  }

  // 文件传输：与远程桌面是**两个会话类型**，所以走独立的页面。
  //
  // 这里不预先 startSession：文件传输页自己会 filesStart（内部会先关掉旧会话），
  // 否则会出现「先建了个桌面会话、又立刻被文件会话顶掉」的闪烁。
  private openFiles(id: string): void {
    const target: string = id.trim();
    if (target.length === 0) {
      promptAction.showToast({ message: '请输入远端 ID' });
      return;
    }
    if (!RustDesk.isInitialized()) {
      promptAction.showToast({ message: `核心未初始化：${RustDesk.getLastError()}` });
      return;
    }
    router.pushUrl({ url: 'pages/FilePage', params: { peerId: target } }).catch((e: Error) => {
      promptAction.showToast({ message: `打开文件传输页失败：${e.message}` });
    });
  }

  private toggleFav(p: PeerInfo): void {
    const favs: string[] = [];
    for (let i = 0; i < this.peers.length; i++) {
      // 点的是当前项就取反，其余保持原样。
      const isFav: boolean = this.peers[i].id === p.id ? !this.peers[i].fav : this.peers[i].fav;
      if (isFav) {
        favs.push(this.peers[i].id);
      }
    }
    const rc: number = RustDesk.storeFav(favs);
    if (rc !== 0) {
      promptAction.showToast({ message: `收藏失败（${rc}）` });
      return;
    }
    // 就地改状态，避免整列表重建导致闪烁。
    const next: PeerInfo[] = [];
    for (let i = 0; i < this.peers.length; i++) {
      if (this.peers[i].id === p.id) {
        next.push({
          id: this.peers[i].id,
          name: this.peers[i].name,
          ts: this.peers[i].ts,
          fav: !this.peers[i].fav
        });
      } else {
        next.push(this.peers[i]);
      }
    }
    this.peers = next;
  }

  private updateTempPassword(): void {
    RustDesk.updateTemporaryPassword();
    // 新密码写在 Rust 侧的配置里，回读一次才能拿到。
    this.myPassword = RustDesk.getConfig().temporaryPassword;
    promptAction.showToast({ message: '一次性密码已刷新' });
  }

  private savePermanentPassword(): void {
    const empty: boolean = this.permPwd.trim().length === 0;
    const rc: number = RustDesk.setPermanentPassword(this.permPwd.trim());
    if (rc !== 0) {
      promptAction.showToast({ message: `设置失败（${rc}）：${RustDesk.getLastError()}` });
      return;
    }
    this.permPwdEditing = false;
    this.permPwd = '';
    promptAction.showToast({ message: empty ? '已清除固定密码' : '固定密码已设置' });
  }

  private fmtTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts * 1000);
    const now: Date = new Date();
    const hm: string = `${this.p2(d.getHours())}:${this.p2(d.getMinutes())}`;
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() &&
        d.getDate() === now.getDate()) {
      return `今天 ${hm}`;
    }
    return `${d.getFullYear()}-${this.p2(d.getMonth() + 1)}-${this.p2(d.getDate())} ${hm}`;
  }

  private p2(n: number): string {
    return n < 10 ? '0' + n : '' + n;
  }

  // 当前页签要显示的列表（收藏页签只留收藏项）。
  // 过滤逻辑放这里而不是 @Builder 里：builder 内不允许写普通语句。
  private visiblePeers(): PeerInfo[] {
    if (this.peersTab === 0) {
      return this.peers;
    }
    const out: PeerInfo[] = [];
    for (let i = 0; i < this.peers.length; i++) {
      if (this.peers[i].fav) {
        out.push(this.peers[i]);
      }
    }
    return out;
  }

  // --- UI 片段 ------------------------------------------------------------

  @Builder
  tabItem(index: number, icon: string, label: string) {
    Column({ space: 2 }) {
      Text(icon)
        .fontSize(18)
        .fontColor(this.currentTab === index ? C_ACCENT : C_DIM)
      Text(label)
        .fontSize(11)
        .fontColor(this.currentTab === index ? C_ACCENT : C_DIM)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  smallBtn(text: string, onTap: () => void) {
    Text(text)
      .fontSize(13)
      .fontColor(C_ACCENT)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(8)
      .backgroundColor('#1B2536')
      .margin({ left: 6 })
      .onClick(() => { onTap(); })
  }

  @Builder
  peerRow(p: PeerInfo) {
    Row() {
      Column() {
        Text(p.name)
          .fontSize(16)
          .fontColor(C_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(p.id)
            .fontSize(12)
            .fontColor(C_ID)
            .fontFamily('monospace')
          Text('·')
            .fontSize(12)
            .fontColor(C_FAINT)
          Text(this.fmtTime(p.ts))
            .fontSize(12)
            .fontColor(C_FAINT)
        }
        .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 直达文件传输：长按菜单没人发现得了，文件传输是高频操作，
      // 必须在行上有个可见的入口（点行体仍然是直接远程控制）。
      Text('📁')
        .fontSize(18)
        .padding({ left: 10, right: 6, top: 4, bottom: 4 })
        .onClick(() => { this.openFiles(p.id); })

      Text(p.fav ? '★' : '☆')
        .fontSize(22)
        .fontColor(p.fav ? '#FFC53D' : C_FAINT)
        .padding({ left: 4, right: 4, top: 4, bottom: 4 })
        .onClick(() => { this.toggleFav(p); })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(C_CARD)
    .borderRadius(13)
    .margin({ bottom: 10 })
    .onClick(() => { this.connect(p.id); })
    // 长按出菜单是备用路径：远程控制 / 文件传输二选一。
    .gesture(LongPressGesture().onAction(() => {
      this.showPeerMenu(p.id);
    }))
  }

  private showPeerMenu(id: string): void {
    // 菜单项只能内联写：ArkTS 不允许把对象字面量拼成一个无类型数组再传
    // （arkts-no-untyped-obj-literals），所以这里用「先弹、再按 index 分发」。
    promptAction.showActionMenu({
      title: id,
      buttons: [
        { text: '远程控制', color: '#E6EDF7' },
        { text: '文件传输', color: '#E6EDF7' }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse) => {
      if (res.index === 0) {
        this.connect(id);
      } else if (res.index === 1) {
        this.openFiles(id);
      }
    }).catch(() => {});
  }

  // ======================= tab 1：连接 =======================

  // 被控时的横幅。放在「连接」tab 最上面：被控期间用户基本停在这一页，
  // 聊天入口必须在第一屏，不能藏在「共享屏幕」里。
  @Builder
  hostBanner() {
    Row({ space: 10 }) {
      Text('🖥')
        .fontSize(18)
      Column({ space: 2 }) {
        Text('正在被远程控制')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .width('100%')
        Text(this.hostSessions > 1 ? `${this.hostSessions} 个会话` : '本机屏幕正在共享')
          .fontSize(11)
          .fontColor('#D5E2FF')
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.hostChatUnread > 0 ? `💬 ${this.hostChatUnread}` : '💬 聊天')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#33FFFFFF')
        .borderRadius(9)
        .onClick(() => { this.openHostChat(); })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor('#1D4E9B')
    .borderRadius(12)
    .margin({ bottom: 10 })
  }

  // 被控端聊天面板（半模态）。
  @Builder
  hostChatSheet() {
    Column() {
      List({ space: 8 }) {
        ForEach(this.hostChatMsgs, (m: HostChatMsg) => {
          ListItem() {
            Row() {
              if (m.mine) {
                Blank()
              }
              Text(m.text)
                .fontSize(14)
                .fontColor(m.mine ? '#FFFFFF' : C_TEXT)
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .backgroundColor(m.mine ? C_ACCENT : C_CARD)
                .borderRadius(10)
                .constraintSize({ maxWidth: '78%' })
              if (!m.mine) {
                Blank()
              }
            }
            .width('100%')
          }
        }, (m: HostChatMsg) => m.id.toString())
      }
      .layoutWeight(1)
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ placeholder: '说点什么…', text: this.hostChatText })
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(C_TEXT)
          .placeholderColor(C_FAINT)
          .backgroundColor(C_CARD)
          .borderRadius(10)
          .onChange((v: string) => { this.hostChatText = v; })
          .onSubmit(() => { this.sendHostChat(); })
        Text('发送')
          .fontSize(15)
          .fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 11, bottom: 11 })
          .backgroundColor(C_ACCENT)
          .borderRadius(10)
          .onClick(() => { this.sendHostChat(); })
      }
      .width('100%')
      .padding({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor(C_BG)
  }

  @Builder
  connectionTab() {
    Column() {
      if (this.hostSessions > 0) {
        this.hostBanner()
      }
      // 对应 Android 的 _buildRemoteIDTextField：高 84 的卡片，左边输入、右边连接。
      Row() {
        TextInput({ placeholder: '输入远端 ID', text: this.peerId })
          .type(InputType.Number)
          .layoutWeight(1)
          .height(52)
          .fontSize(17)
          .fontColor(C_TEXT)
          .placeholderColor(C_FAINT)
          .backgroundColor(Color.Transparent)
          .onChange((v: string) => { this.peerId = v; })
          .onSubmit(() => { this.connect(this.peerId); })

        // 文件传输入口。放在「连接」左边而不是塞进菜单里：输入 ID 之后
        // 最常见的第二个动作就是传文件，多一次长按不划算。
        Text('📁')
          .fontSize(18)
          .padding({ left: 12, right: 12, top: 9, bottom: 9 })
          .borderRadius(10)
          .backgroundColor(C_FIELD)
          .margin({ left: 8 })
          .onClick(() => { this.openFiles(this.peerId); })

        Text(this.connecting ? '…' : '连接')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .borderRadius(10)
          .backgroundColor(C_ACCENT)
          .margin({ left: 8 })
          .onClick(() => { this.connect(this.peerId); })
      }
      .width('100%')
      .height(84)
      .padding({ left: 16, right: 8 })
      .backgroundColor(C_CARD)
      .borderRadius(13)
      .margin({ bottom: 12 })

      Row({ space: 8 }) {
        Text('最近会话')
          .fontSize(14)
          .fontColor(this.peersTab === 0 ? C_ACCENT : C_DIM)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor(this.peersTab === 0 ? '#1B2536' : Color.Transparent)
          .onClick(() => { this.peersTab = 0; })
        Text('收藏')
          .fontSize(14)
          .fontColor(this.peersTab === 1 ? C_ACCENT : C_DIM)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor(this.peersTab === 1 ? '#1B2536' : Color.Transparent)
          .onClick(() => { this.peersTab = 1; })
        Blank()
      }
      .width('100%')
      .margin({ bottom: 10 })

      if (this.visiblePeers().length === 0) {
        Column() {
          Text(this.peersTab === 1 ? '还没有收藏' : '还没有连接记录')
            .fontSize(14)
            .fontColor(C_FAINT)
            .margin({ top: 40 })
          Text('连接成功后会自动出现在这里')
            .fontSize(12)
            .fontColor(C_FAINT)
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        List() {
          ForEach(this.visiblePeers(), (p: PeerInfo) => {
            ListItem() {
              this.peerRow(p);
            }
          }, (p: PeerInfo) => p.id)
        }
        .width('100%')
        .layoutWeight(1)
        .divider({ strokeWidth: 0 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 10, right: 10, top: 10 })
  }

  // ======================= tab：共享屏幕 =======================

  @Builder
  serverTab() {
    Scroll() {
      Column() {
        // 远程协助（被控端）。不做常驻服务：开关打开才起采集 + 注册，
        // 关掉即拆。系统会在开启时弹两次授权（屏幕采集、键鼠注入）。
        Column() {
          Row() {
            Text('●')
              .fontSize(12)
              .fontColor(this.hostRunning
                ? (this.injectStatus === 2 ? DOT_READY : DOT_CONNECTING)
                : C_FAINT)
              .margin({ right: 8 })
            Column() {
              Text('远程协助（允许被控）')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(C_TEXT)
                .width('100%')
              Text(this.hostStateText())
                .fontSize(12)
                .fontColor(C_DIM)
                .width('100%')
                .margin({ top: 2 })
            }
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.hostRunning })
              .enabled(this.hostSupported && !this.hostBusy)
              .selectedColor(C_ACCENT)
              .onChange((isOn: boolean) => {
                if (isOn !== this.hostRunning) {
                  this.setHostPower(isOn);
                }
              })
          }
          .width('100%')

          Text(this.hostSupported
            ? '开启后本机临时进入被控状态：向 ID 服务器注册，别人用你的 ID 就能连进来。\n只在前台开启、随时可关；关闭后立即断开会话并停止采集。'
            : '当前设备形态不支持被控（仅 2in1 可用）。')
            .fontSize(13)
            .fontColor(C_DIM)
            .lineHeight(19)
            .width('100%')
            .margin({ top: 10 })
        }
        .width('100%')
        .padding(14)
        .backgroundColor(C_CARD)
        .borderRadius(13)
        .margin({ bottom: 14 })

        // 「你的设备」卡片：Android ServerPage 里 ID 与一次性密码同在一张卡上。
        Column() {
          Text('你的设备')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(C_TEXT)
            .width('100%')
            .margin({ bottom: 12 })

          Column() {
            Text('ID')
              .fontSize(12)
              .fontColor(C_DIM)
              .width('100%')
            Row() {
              Text(this.myId.length > 0 ? this.myId : '—')
                .fontSize(26)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.myId.length > 0 ? C_ID : C_FAINT)
                .fontFamily('monospace')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              this.smallBtn('复制', () => { this.copy(this.myId); })
            }
            .width('100%')
            .margin({ top: 4 })
          }
          .width('100%')

          Divider()
            .color(C_DIVIDER)
            .margin({ top: 12, bottom: 12 })

          Column() {
            Text('一次性密码')
              .fontSize(12)
              .fontColor(C_DIM)
              .width('100%')
            Row() {
              Text(this.myPassword.length > 0 ? this.myPassword : '—')
                .fontSize(26)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.myPassword.length > 0 ? C_TEXT : C_FAINT)
                .fontFamily('monospace')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              this.smallBtn('复制', () => { this.copy(this.myPassword); })
              this.smallBtn('刷新', () => { this.updateTempPassword(); })
            }
            .width('100%')
            .margin({ top: 4 })
            // 一次性密码的语义要说清楚：它只在一个会话里有效，被用掉就换新的
            // （换了之后这里的数字会自动跟着变，见 refreshPassword）。
            Text('一次有效，被连接使用后自动更换；需要断线后仍能用原密码重连，请设置固定密码。')
              .fontSize(11)
              .fontColor(C_FAINT)
              .width('100%')
              .margin({ top: 6 })
          }
          .width('100%')

          Divider()
            .color(C_DIVIDER)
            .margin({ top: 12, bottom: 12 })

          if (this.permPwdEditing) {
            Row() {
              TextInput({ placeholder: '新固定密码（留空＝清除）', text: this.permPwd })
                .type(InputType.Password)
                .layoutWeight(1)
                .height(44)
                .fontSize(15)
                .fontColor(C_TEXT)
                .placeholderColor(C_FAINT)
                .backgroundColor(C_FIELD)
                .borderRadius(10)
                .onChange((v: string) => { this.permPwd = v; })
              this.smallBtn('确定', () => { this.savePermanentPassword(); })
              this.smallBtn('取消', () => {
                this.permPwdEditing = false;
                this.permPwd = '';
              })
            }
            .width('100%')
          } else {
            Row() {
              Text('固定密码')
                .fontSize(13)
                .fontColor(C_DIM)
              Blank()
              this.smallBtn('设置', () => { this.permPwdEditing = true; })
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(C_CARD)
        .borderRadius(13)
        .margin({ bottom: 14 })

        // 生效服务器：连接排错时第一眼要看的就是它。
        // 地址前的圆点＝这台服务器此刻连不连得上（绿=已连接/黄=连接中/红=失败）。
        Column() {
          Text('当前生效的 ID 服务器')
            .fontSize(12)
            .fontColor(C_DIM)
            .width('100%')
          Row() {
            Circle({ width: 8, height: 8 })
              .fill(this.serverStatusColor())
              .margin({ right: 8 })
            Text(this.effectiveServer.length > 0 ? this.effectiveServer : '（未初始化）')
              .fontSize(14)
              .fontColor(C_TEXT)
              .fontFamily('monospace')
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .width('100%')
        .padding(14)
        .backgroundColor(C_CARD)
        .borderRadius(13)
        .margin({ bottom: 24 })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12 })
    }
    .width('100%')
    .height('100%')
    // 桌面形态给常驻滚动条 + 允许鼠标按住拖动滚动（与设置页一致）。
    .scrollBar(this.isPhone ? BarState.Off : BarState.On)
    .enableScrollWithMouse(true)
  }

  // ======================= 主体 =======================

  build() {
    // 外层 Stack 只为首次启动的隐私政策遮罩：它要盖在整个界面之上，
    // 且不参与 Tabs 布局（用 bindSheet 可被手势关闭，不适合强制同意）。
    Stack() {
    Column() {
      // AppBar：Android 是居中标题 + 右侧动作。这里放一个刷新（回读 ID/密码/列表）。
      Row() {
        Text('RustDesk')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('⟳')
          .fontSize(20)
          .fontColor(C_ACCENT)
          .width(40)
          .textAlign(TextAlign.Center)
          .onClick(() => { this.refresh(); })
      }
      .width('100%')
      .height(56)
      .padding({ left: 8, right: 8 })
      .backgroundColor(C_BG)

      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() {
          this.connectionTab();
        }
        .tabBar(this.tabItem(0, '⇄', '连接'))

        // 手机形态没有「共享屏幕」：被控端在手机上无法实现（平台无输入注入
        // 接口），留着只会是个永远「服务未运行」的死页面。
        if (!this.isPhone) {
          TabContent() {
            this.serverTab();
          }
          .tabBar(this.tabItem(1, '▣', '共享屏幕'))
        }

        TabContent() {
          SettingsPage();
        }
        // 手机上「设置」是第 2 档（索引 1），桌面/2in1 上是第 3 档（索引 2）。
        .tabBar(this.tabItem(this.isPhone ? 1 : 2, '⚙', '设置'))
      }
      .layoutWeight(1)
      .barBackgroundColor(C_BG)
      .barHeight(56)
      .onChange((index: number) => {
        this.currentTab = index;
        // 切回连接/共享时列表和 ID 可能已经变了。
        // 手机上索引 1 是「设置」，不需要刷新主控数据。
        if (index === 0 || (!this.isPhone && index === 1)) {
          this.refresh();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
    // 被控端聊天：下拉关闭时把状态同步回来，否则下次点不开。
    .bindSheet($$this.hostChatOpen, this.hostChatSheet(), {
      height: 420,
      dragBar: true,
      showClose: true,
      title: { title: '聊天' },
      onDisappear: () => { this.hostChatOpen = false; }
    })

      // 首次启动：未同意隐私政策前，遮罩挡在所有功能之上。
      if (this.showPrivacy) {
        this.privacyMask();
      }
    }
    .width('100%')
    .height('100%')
  }
}

// 被控端的一条聊天消息。ArkTS 不允许对象字面量当类型，必须显式建类。
class HostChatMsg {
  id: number = 0;
  text: string = '';
  mine: boolean = false;

  constructor(id: number, text: string, mine: boolean) {
    this.id = id;
    this.text = text;
    this.mine = mine;
  }
}
