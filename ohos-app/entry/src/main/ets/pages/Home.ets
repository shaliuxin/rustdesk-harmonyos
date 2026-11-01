import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RustDesk, PeerInfo } from '../common/RustDesk';
import { isPhoneForm } from '../common/DeviceForm';
import { SettingsPage } from './Settings';

// 主页：AppBar + 底部四个 tab（连接 / 聊天 / 共享屏幕 / 设置）。
//
// 结构照 RustDesk Android 的 HomePage 来：`flutter/lib/mobile/pages/home_page.dart`
// 用 Scaffold + BottomNavigationBar，Android 上依次是 ConnectionPage、ChatPage、
// ServerPage、SettingsPage。这里用 ArkUI 的 Tabs（barPosition = End）对应。
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

  // 手机形态：被控能力平台不支持，「共享屏幕」这一档整体不渲染。
  // 在 aboutToAppear 里赋值（早于首次 build），不会出现先闪一下再消失。
  @State isPhone: boolean = false;

  aboutToAppear(): void {
    this.isPhone = isPhoneForm();
    this.refresh();
    // 与设置页同一套：Rust 看门狗每 3 秒探测一次，这里 1 秒读一次结果。
    this.refreshServerStatus();
    this.statusTimer = setInterval(this.refreshServerStatus, 1000);
  }

  aboutToDisappear(): void {
    if (this.statusTimer !== -1) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
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
        next.push({ id: this.peers[i].id, ts: this.peers[i].ts, fav: !this.peers[i].fav });
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
        Text(p.id)
          .fontSize(16)
          .fontColor(C_ID)
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.fmtTime(p.ts))
          .fontSize(12)
          .fontColor(C_FAINT)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(p.fav ? '★' : '☆')
        .fontSize(22)
        .fontColor(p.fav ? '#FFC53D' : C_FAINT)
        .padding({ left: 10, right: 4, top: 4, bottom: 4 })
        .onClick(() => { this.toggleFav(p); })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(C_CARD)
    .borderRadius(13)
    .margin({ bottom: 10 })
    .onClick(() => { this.connect(p.id); })
  }

  // ======================= tab 1：连接 =======================

  @Builder
  connectionTab() {
    Column() {
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

  // ======================= tab 2：聊天 =======================

  @Builder
  chatTab() {
    Column() {
      Text('💬')
        .fontSize(48)
        .margin({ bottom: 16 })
      Text('聊天暂未启用')
        .fontSize(17)
        .fontColor(C_TEXT)
        .margin({ bottom: 8 })
      Text('Android 版这一页依赖 RustDesk 账号登录后拉取会话列表。\n鸿蒙版目前打通的是主控链路，会话内的文字可在远程页用 ⌨ 输入。')
        .fontSize(13)
        .fontColor(C_DIM)
        .textAlign(TextAlign.Center)
        .lineHeight(20)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 32, right: 32 })
  }

  // ======================= tab 3：共享屏幕 =======================

  @Builder
  serverTab() {
    Scroll() {
      Column() {
        // 服务状态。鸿蒙版目前只做主控，被控端服务不可用 —— 如实说明，
        // 而不是摆一个点了没反应的按钮。
        Column() {
          Row() {
            Text('●')
              .fontSize(12)
              .fontColor(C_DANGER)
              .margin({ right: 8 })
            Text('服务未运行')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(C_TEXT)
          }
          .width('100%')
          Text('鸿蒙版当前只实现了主控（去连别人），被控端服务尚未启用。\n下面的 ID 供其它设备连入时备用。')
            .fontSize(13)
            .fontColor(C_DIM)
            .lineHeight(19)
            .width('100%')
            .margin({ top: 8 })
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
    .scrollBar(BarState.Off)
  }

  // ======================= 主体 =======================

  build() {
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

        TabContent() {
          this.chatTab();
        }
        .tabBar(this.tabItem(1, '💬', '聊天'))

        // 手机形态没有「共享屏幕」：被控端在手机上无法实现（平台无输入注入
        // 接口），留着只会是个永远「服务未运行」的死页面。
        if (!this.isPhone) {
          TabContent() {
            this.serverTab();
          }
          .tabBar(this.tabItem(2, '▣', '共享屏幕'))
        }

        TabContent() {
          SettingsPage();
        }
        // 手机上「设置」是第 3 档（索引 2），桌面/2in1 上是第 4 档（索引 3）。
        .tabBar(this.tabItem(this.isPhone ? 2 : 3, '⚙', '设置'))
      }
      .layoutWeight(1)
      .barBackgroundColor(C_BG)
      .barHeight(56)
      .onChange((index: number) => {
        this.currentTab = index;
        // 切回连接/共享时列表和 ID 可能已经变了。
        // 手机上索引 2 是「设置」，不需要刷新主控数据。
        if (index === 0 || (!this.isPhone && index === 2)) {
          this.refresh();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
