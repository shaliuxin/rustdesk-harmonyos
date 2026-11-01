import { promptAction, router } from '@kit.ArkUI';
import { RustDesk, ServerConfig } from '../common/RustDesk';
import { isPhoneForm } from '../common/DeviceForm';

// 设置页。
//
// **分组与排列顺序严格对齐 Android**（flutter/lib/mobile/pages/settings_page.dart
// 的 build()，sections 依次是）：
//
//   1. Account        登录 / 注销
//   2. Settings       ID/Relay Server → Socks5/Http(s) Proxy → (Deploy) →
//                     Use WebSocket → Allow insecure TLS fallback → Disable UDP →
//                     Enable TCP hole punching → Enable UDP hole punching →
//                     Enable IPv6 P2P → Enable WebRTC P2P → Language → Theme →
//                     (Keyboard shortcuts) → (note at conn end) → Keep awake
//   3. Hardware Codec Enable hardware codec
//   4. Recording      Automatically record incoming / outgoing → Directory
//   5. 2FA            ……
//   6. Share screen   Deny LAN discovery → IP whitelist → ID whitelist →
//                     Adaptive bitrate → Enable recording session
//   7. Display        Display Settings（子页：View Style / Image Quality / Codec）
//   8. Enhancements   ……
//   9. About          Version → Build Date → (Fingerprint) → ID → Privacy Statement
//
// 三类差异是**刻意**的，不是漏做（每个都单独注释在对应位置）：
//   1. 账号相关（登录 / 2FA / 受信任设备）：依赖账号服务，鸿蒙版不接账号。
//   2. Android 系统能力（部署 / 悬浮窗 / 开机自启）：鸿蒙没有对应机制。
//   3. 入口形态：Android 上「ID/Relay Server」「Proxy」是弹窗、「Display Settings」
//      是跳子页，这里统一内联进同一个滚动列表 —— 手机上本就该一路滚到底。
//
// **不同设置项存在不同地方，别写错**：
//   • 全局 Config（RustDesk2.toml，会随配置漫游）：服务器四项、
//     allow-websocket / allow-insecure-tls-fallback / disable-udp /
//     enable-lan-discovery / enable-hwcodec / enable-abr /
//     enable-record-session / allow-auto-record-incoming
//   • 本地 LocalConfig（不漫游）：四个打洞开关、
//     allow-auto-record-outgoing / keep-awake-during-outgoing-sessions /
//     enable-check-update
//   • 代理独一份：Config2.socks（三个字段不在 options map 里）
//   • 视图样式 / 图像质量：PeerConfig 的**命名字段**，必须走
//     save_view_style / save_image_quality，塞 options map 没人读
// 判据是 `libs/base/src/config/keys.rs` 的 KEYS_SETTINGS / KEYS_LOCAL_SETTINGS
// 两个列表，以及各读取函数（`config.rs` 的 use_ws()、`common.rs` 的
// get_*_punch_enabled()）。放错位置的症状是「设置里改了、行为没变」。
//
// 作为主页底部「设置」tab 的内容使用（Home.ets 里 import SettingsPage），
// 所以这里不写 @Entry、也不带返回栏 —— 那套属于「独立路由页」的形态。

class ViewOption {
  readonly value: string;
  readonly label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

// 视图样式：对应上游 kRemoteViewStyleOriginal / kRemoteViewStyleAdaptive。
const VIEW_STYLES: ViewOption[] = [
  new ViewOption('', '跟随系统默认'),
  new ViewOption('original', '原始大小'),
  new ViewOption('adaptive', '自适应窗口'),
];

// 图像质量：对应上游 kRemoteImageQualityBest / Balanced / Low。
// 上游还有 `custom`（自定义码率），需要再存 custom_image_quality 数组，暂不开放。
const IMAGE_QUALITIES: ViewOption[] = [
  new ViewOption('', '默认（均衡）'),
  new ViewOption('best', '最佳画质'),
  new ViewOption('balanced', '均衡'),
  new ViewOption('low', '流畅优先'),
];

// 编解码偏好：与上游 _DisplayPage 的 codecList 一致。
// H264 / H265 是否可用取决于设备硬解能力，这里全列，连不上时自动回退。
const CODECS: ViewOption[] = [
  new ViewOption('auto', '自动'),
  new ViewOption('vp8', 'VP8'),
  new ViewOption('vp9', 'VP9'),
  new ViewOption('av1', 'AV1'),
  new ViewOption('h264', 'H264'),
  new ViewOption('h265', 'H265'),
];

// 与 AppScope/app.json5 的 versionName 保持一致。About.ets 里也有一份，
// 改版本号时两处都要动（这里和 About.ets）。跟随上游 RustDesk 版本（Cargo.toml）。
const APP_VERSION: string = '1.5.1 鸿蒙版 by 刘馨';

// 颜色：与 MyTheme / 其他页面保持一致
const C_BG: string = '#0B1220';
const C_CARD: string = '#101827';
const C_FIELD: string = '#161E2E';
const C_TEXT: string = '#E6EDF7';
const C_DIM: string = '#8A94A6';
const C_HINT: string = '#5A6478';
const C_ACCENT: string = '#2F81F7';
const C_DIVIDER: string = '#1F2A3D';

// ID 服务器状态圆点。三个色值与 `RustDesk.SERVER_STATUS_*` 常量一一对应。
const DOT_READY: string = '#22C55E';      // 绿：已正常连接
const DOT_CONNECTING: string = '#F5A524';  // 黄：正在连接
const DOT_FAILED: string = '#EF4444';     // 红：连接失败

@Component
export struct SettingsPage {
  // --- 服务器 ---
  @State idServer: string = '';
  @State relayServer: string = '';
  @State apiServer: string = '';
  @State serverKey: string = '';
  @State effectiveServer: string = '';
  // ID 服务器连接状态，取值见 RustDesk.SERVER_STATUS_*。由定时器刷新。
  @State serverStatus: number = RustDesk.SERVER_STATUS_CONNECTING;
  // --- 代理 ---
  @State proxyUrl: string = '';
  @State proxyUser: string = '';
  @State proxyPwd: string = '';
  // --- 显示设置 ---
  @State viewStyleIndex: number = 0;
  @State imageQualityIndex: number = 0;
  @State codecIndex: number = 0;
  // --- 其他默认选项 ---
  @State showRemoteCursor: boolean = false;
  @State followRemoteCursor: boolean = false;
  @State followRemoteWindow: boolean = false;
  @State showQualityMonitor: boolean = false;
  @State viewOnly: boolean = false;
  @State i444: boolean = false;
  @State reverseMouseWheel: boolean = false;
  @State swapLeftRightMouse: boolean = false;
  @State disableClipboard: boolean = false;
  @State lockAfterSessionEnd: boolean = false;
  @State privacyMode: boolean = false;
  @State disableAudio: boolean = false;
  @State forceAlwaysRelay: boolean = false;
  // --- 网络 / 打洞 ---
  @State disableUdp: boolean = false;
  @State enableTcpPunch: boolean = true;
  @State enableUdpPunch: boolean = true;
  @State enableIpv6Punch: boolean = true;
  @State enableWebrtc: boolean = true;
  @State allowWebsocket: boolean = true;
  @State allowInsecureTls: boolean = false;
  // --- 硬件编解码 ---
  @State enableHwcodec: boolean = true;
  // --- 录制 ---
  @State autoRecordIncoming: boolean = false;
  @State autoRecordOutgoing: boolean = false;
  @State recordDir: string = '';
  // --- 共享屏幕 ---
  @State enableLanDiscovery: boolean = true;
  @State whitelist: string = '';
  @State idWhitelist: string = '';
  // 条数是「显示用」的派生值。ArkTS 的 builder 里不能写普通语句、也不宜
  // 内联调用工具函数（10905204 / 10905209），所以在 load() 与 onChange 里
  // 算好存起来，builder 只负责读。
  @State whitelistCount: number = 0;
  @State idWhitelistCount: number = 0;
  @State showWhitelistEditor: boolean = false;
  @State showIdWhitelistEditor: boolean = false;
  @State enableAbr: boolean = true;
  @State enableRecordSession: boolean = false;
  // --- 增强 ---
  @State keepAwake: boolean = true;
  @State checkUpdate: boolean = true;
  @State saving: boolean = false;
  // ID 服务器连接状态的轮询定时器；-1 表示没在跑。
  private statusTimer: number = -1;
  // 手机形态：隐藏「共享屏幕」（被控端）相关设置
  @State isPhone: boolean = false;

  aboutToAppear(): void {
    // 手机上没有「共享屏幕」页，被控端的策略项跟着一起隐藏。
    this.isPhone = isPhoneForm();
    this.load();
    // 后台看门狗每 3 秒探测一次，这里 1 秒读一次结果即可 —— 与上游
    // `server_model.dart` 里 1 秒的 timerCallback 节奏一致。
    this.refreshServerStatus();
    this.statusTimer = setInterval(this.refreshServerStatus, 1000);
  }

  aboutToDisappear(): void {
    if (this.statusTimer !== -1) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  /// 从 Rust 侧读一次 ID 服务器状态。不阻塞，可以放心放在定时器里。
  //
  // 写成**箭头函数属性**而不是普通方法：普通方法作为回调传出去时 `this`
  // 会丢掉，运行期直接 TypeError（"Obj is not a Valid object"）——
  // SessionPage 的 fireAutoUp 用的是同一套写法。
  private refreshServerStatus = (): void => {
    this.serverStatus = RustDesk.serverStatus();
  }

  /// 状态圆点颜色：绿=已连接、黄=正在连接、红=连接失败。
  private serverStatusColor(): string {
    if (this.serverStatus === RustDesk.SERVER_STATUS_READY) {
      return DOT_READY;
    }
    if (this.serverStatus === RustDesk.SERVER_STATUS_FAILED) {
      return DOT_FAILED;
    }
    return DOT_CONNECTING;
  }

  private load(): void {
    const cfg: ServerConfig = RustDesk.getConfig();
    this.idServer = cfg.idServer;
    this.relayServer = cfg.relayServer;
    this.apiServer = cfg.apiServer;
    this.serverKey = cfg.key;
    this.effectiveServer = cfg.effectiveServer;
    this.viewStyleIndex = this.indexOf(VIEW_STYLES, cfg.viewStyle);
    this.imageQualityIndex = this.indexOf(IMAGE_QUALITIES, cfg.imageQuality);
    this.showRemoteCursor = cfg.showRemoteCursor;
    this.disableAudio = cfg.disableAudio;
    this.forceAlwaysRelay = cfg.forceAlwaysRelay;
    this.disableUdp = cfg.disableUdp;
    this.allowWebsocket = cfg.allowWebsocket;

    // 代理存在 Config2.socks，不走 options map，所以用专用接口。
    const p: Record<string, string> = RustDesk.proxy();
    this.proxyUrl = p['proxy'] ?? '';
    this.proxyUser = p['username'] ?? '';
    this.proxyPwd = p['password'] ?? '';

    // 其余散项走通用 option 接口，键名与 Flutter consts.dart 逐字一致。
    this.codecIndex = this.indexOf(CODECS, RustDesk.optionGet('codec-preference'));
    this.followRemoteCursor = RustDesk.optionGetBool('follow_remote_cursor');
    this.followRemoteWindow = RustDesk.optionGetBool('follow_remote_window');
    this.showQualityMonitor = RustDesk.optionGetBool('show_quality_monitor');
    this.viewOnly = RustDesk.optionGetBool('view_only');
    this.i444 = RustDesk.optionGetBool('i444');
    this.reverseMouseWheel = RustDesk.optionGetBool('reverse_mouse_wheel');
    this.swapLeftRightMouse = RustDesk.optionGetBool('swap-left-right-mouse');
    this.disableClipboard = RustDesk.optionGetBool('disable_clipboard');
    this.lockAfterSessionEnd = RustDesk.optionGetBool('lock_after_session_end');
    this.privacyMode = RustDesk.optionGetBool('privacy_mode');
    this.enableHwcodec = RustDesk.optionGetBool('enable-hwcodec');
    this.autoRecordIncoming = RustDesk.optionGetBool('allow-auto-record-incoming');
    // 传出录制与打洞开关都走 LocalConfig。
    this.autoRecordOutgoing = RustDesk.localOptionGetBool('allow-auto-record-outgoing', false);
    this.recordDir = RustDesk.optionGet('video-save-directory');
    this.allowInsecureTls = RustDesk.optionGetBool('allow-insecure-tls-fallback');
    this.enableLanDiscovery = RustDesk.optionGetBool('enable-lan-discovery');
    this.whitelist = RustDesk.optionGet('whitelist');
    this.idWhitelist = RustDesk.optionGet('id-whitelist');
    this.recountWhitelist();
    this.enableAbr = RustDesk.optionGetBool('enable-abr');
    this.enableRecordSession = RustDesk.optionGetBool('enable-record-session');
    this.enableTcpPunch = RustDesk.localOptionGetBool('enable-tcp-punch', true);
    this.enableUdpPunch = RustDesk.localOptionGetBool('enable-udp-punch', true);
    this.enableIpv6Punch = RustDesk.localOptionGetBool('enable-ipv6-punch', true);
    this.enableWebrtc = RustDesk.localOptionGetBool('enable-webrtc', true);
    this.keepAwake = RustDesk.localOptionGetBool('keep-awake-during-outgoing-sessions', true);
    this.checkUpdate = RustDesk.localOptionGetBool('enable-check-update', true);
  }

  private indexOf(options: ViewOption[], value: string): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) {
        return i;
      }
    }
    return 0;
  }

  // 统计白名单里的条目数（空行不算）。
  private recountWhitelist(): void {
    this.whitelistCount = this.countNonEmpty(this.whitelist);
    this.idWhitelistCount = this.countNonEmpty(this.idWhitelist);
  }

  private countNonEmpty(s: string): number {
    if (s.trim().length === 0) {
      return 0;
    }
    let n: number = 0;
    const parts: string[] = s.split('\n');
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].trim().length > 0) {
        n += 1;
      }
    }
    return n;
  }

  // 白名单的显示文案：没设置时给「未设置」，否则给条数。
  private whitelistLabel(): string {
    return this.whitelistCount > 0 ? `${this.whitelistCount} 条` : '未设置';
  }

  private idWhitelistLabel(): string {
    return this.idWhitelistCount > 0 ? `${this.idWhitelistCount} 条` : '未设置';
  }

  private onSave(): void {
    // 写入分两路：
    //   • 结构化配置（服务器四项 + 视图/画质默认值 + 开关型默认项）走 configSet；
    //   • 其余散项走通用 option 接口 / 代理专用接口。
    // 两者都直接落到 Config，不会互相覆盖。
    const cfg: ServerConfig = new ServerConfig();
    cfg.idServer = this.idServer;
    cfg.relayServer = this.relayServer;
    cfg.apiServer = this.apiServer;
    cfg.key = this.serverKey;
    cfg.viewStyle = VIEW_STYLES[this.viewStyleIndex].value;
    cfg.imageQuality = IMAGE_QUALITIES[this.imageQualityIndex].value;
    cfg.showRemoteCursor = this.showRemoteCursor;
    cfg.disableAudio = this.disableAudio;
    cfg.forceAlwaysRelay = this.forceAlwaysRelay;
    cfg.disableUdp = this.disableUdp;
    cfg.allowWebsocket = this.allowWebsocket;

    this.saving = true;
    const rc: number = RustDesk.saveConfig(cfg);
    this.saving = false;

    if (rc !== 0) {
      promptAction.showToast({ message: `保存失败（${rc}）：${RustDesk.getLastError()}` });
      return;
    }

    RustDesk.setProxy(this.proxyUrl, this.proxyUser, this.proxyPwd);
    RustDesk.optionSet('codec-preference', CODECS[this.codecIndex].value);
    RustDesk.optionSetBool('follow_remote_cursor', this.followRemoteCursor);
    RustDesk.optionSetBool('follow_remote_window', this.followRemoteWindow);
    RustDesk.optionSetBool('show_quality_monitor', this.showQualityMonitor);
    RustDesk.optionSetBool('view_only', this.viewOnly);
    RustDesk.optionSetBool('i444', this.i444);
    RustDesk.optionSetBool('reverse_mouse_wheel', this.reverseMouseWheel);
    RustDesk.optionSetBool('swap-left-right-mouse', this.swapLeftRightMouse);
    RustDesk.optionSetBool('disable_clipboard', this.disableClipboard);
    RustDesk.optionSetBool('lock_after_session_end', this.lockAfterSessionEnd);
    RustDesk.optionSetBool('privacy_mode', this.privacyMode);
    RustDesk.optionSetBool('enable-hwcodec', this.enableHwcodec);
    RustDesk.optionSetBool('allow-auto-record-incoming', this.autoRecordIncoming);
    RustDesk.localOptionSetBool('allow-auto-record-outgoing', this.autoRecordOutgoing);
    RustDesk.optionSetBool('allow-insecure-tls-fallback', this.allowInsecureTls);
    RustDesk.optionSetBool('enable-lan-discovery', this.enableLanDiscovery);
    RustDesk.optionSet('whitelist', this.whitelist);
    RustDesk.optionSet('id-whitelist', this.idWhitelist);
    RustDesk.optionSetBool('enable-abr', this.enableAbr);
    RustDesk.optionSetBool('enable-record-session', this.enableRecordSession);
    RustDesk.localOptionSetBool('keep-awake-during-outgoing-sessions', this.keepAwake);
    RustDesk.localOptionSetBool('enable-check-update', this.checkUpdate);
    RustDesk.localOptionSetBool('enable-tcp-punch', this.enableTcpPunch);
    RustDesk.localOptionSetBool('enable-udp-punch', this.enableUdpPunch);
    RustDesk.localOptionSetBool('enable-ipv6-punch', this.enableIpv6Punch);
    RustDesk.localOptionSetBool('enable-webrtc', this.enableWebrtc);

    // 保存后立刻回读：Rust 侧会拒绝被安装包内嵌配置锁住的键，
    // 直接信任「写成功」会让用户以为改好了。
    const after: ServerConfig = RustDesk.getConfig();
    this.effectiveServer = after.effectiveServer;
    if (after.idServer !== this.idServer.trim()) {
      promptAction.showToast({ message: 'ID 服务器未能保存：可能被安装包内嵌配置覆盖' });
      return;
    }

    this.load();
    promptAction.showToast({ message: '已保存，下次连接生效' });
  }

  @Builder
  fieldLabel(text: string, hint: string) {
    Row() {
      Text(text)
        .fontSize(14)
        .fontColor(C_DIM)
      Text(hint)
        .fontSize(12)
        .fontColor(C_HINT)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .margin({ bottom: 6 })
  }

  // 大分组标题（对齐 Android 的 SettingsSection title）
  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .fontColor(C_ACCENT)
      .width('100%')
      .margin({ top: 14, bottom: 12 })
  }

  // 组内小标题：Android 把服务器和代理做成弹窗入口，这里内联显示，
  // 加个小标题让层次清楚（顺序仍与 Android 一致）。
  @Builder
  subTitle(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor(C_DIM)
      .width('100%')
      .margin({ top: 6, bottom: 8 })
  }

  // 一行「点进去」的设置项：左边标题、右边当前值 + ›。
  // 对应 Android 设置页里那些 navigate 型 tile（语言、关于…）。
  @Builder
  linkRow(label: string, value: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(C_TEXT)
      Blank()
      Text(value)
        .fontSize(13)
        .fontColor(C_HINT)
      Text('›')
        .fontSize(14)
        .fontColor(C_HINT)
        .margin({ left: 4 })
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .onClick(() => { onTap(); })
  }

  @Builder
  toggleRow(label: string, description: string, isOn: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(label)
          .fontSize(14)
          .fontColor(C_TEXT)
        if (description.length > 0) {
          Text(description)
            .fontSize(12)
            .fontColor(C_HINT)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(C_ACCENT)
        .onChange((v: boolean) => { onChange(v); })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(C_CARD)
    .borderRadius(12)
    .margin({ bottom: 10 })
  }

  // 下拉选择：label + 当前值。Android 上是弹单选对话框，这里用 Select。
  @Builder
  selectRow(label: string, hint: string, options: ViewOption[], index: number, onSelect: (i: number) => void) {
    Column() {
      this.fieldLabel(label, hint)
      Select(options.map((o: ViewOption): SelectOption => {
        return { value: o.label } as SelectOption;
      }))
        .selected(index)
        .value(options[index].label)
        .fontColor(C_TEXT)
        .font({ size: 15 })
        .optionFontColor(C_TEXT)
        .optionBgColor(C_FIELD)
        .selectedOptionBgColor('#1B2536')
        .backgroundColor(C_FIELD)
        .borderRadius(12)
        .width('100%')
        .onSelect((i: number) => { onSelect(i); })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(C_CARD)
    .borderRadius(12)
    .margin({ bottom: 10 })
  }

  @Builder
  textField(label: string, hint: string, placeholder: string, value: string,
    onChange: (v: string) => void, secret: boolean) {
    Column() {
      this.fieldLabel(label, hint)
      TextInput({ placeholder: placeholder, text: value })
        .height(50)
        .fontSize(16)
        .type(secret ? InputType.Password : InputType.Normal)
        .backgroundColor(C_FIELD)
        .fontColor('#FFFFFF')
        .placeholderColor(C_HINT)
        .borderRadius(12)
        .onChange((v: string) => { onChange(v); })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(C_CARD)
    .borderRadius(12)
    .margin({ bottom: 10 })
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          // ==================== 1. Account ====================
          // Android 这一组依赖账号服务（OIDC + userModel），鸿蒙版不接账号，
          // 摆上去只是点了没反应的按钮，所以整组不显示。
          // this.sectionTitle('账户')

          // ==================== 2. Settings ====================
          this.sectionTitle('设置')

          // Android 在设置页右上角放扫码按钮（ScanButton）。
          // 相机扫码在鸿蒙上不可行，进去是「粘贴 config 串」的等价通路。
          SettingCard() {
            this.linkRow('扫码 / 导入配置', '粘贴 config 串', () => {
              router.pushUrl({ url: 'pages/Scan' }).catch(() => {
                promptAction.showToast({ message: '打开失败' });
            });
            })
          }

          // --- ID/Relay Server（Android 是弹窗，这里内联）---
          this.subTitle('ID / 中继服务器')

          this.textField('ID 服务器', '自建 hbbs 的地址', '例如 192.168.1.10 或 rd.example.com:21116',
            this.idServer, (v: string) => { this.idServer = v; }, false)

          this.textField('中继服务器', '留空＝用服务器下发的', '例如 192.168.1.10:21117',
            this.relayServer, (v: string) => { this.relayServer = v; }, false)

          this.textField('API 服务器', '地址簿 / 在线状态', '留空则用 http://<ID服务器>:21114',
            this.apiServer, (v: string) => { this.apiServer = v; }, false)

          // 公钥本身就是 `cat id_ed25519.pub` 出来的一行字符串，原来用 96 高的
          // 多行 TextArea 既空荡又和上下三项不齐；改成同样的单行 TextInput，
          // 超长内容由输入框自身横向滚动。
          this.textField('服务器公钥 Key', 'id_ed25519.pub 的内容',
            'hbbs 主机上 cat id_ed25519.pub 的一行字符串',
            this.serverKey, (v: string) => { this.serverKey = v; }, false)

          // 生效地址：Rust 侧算出来的真实目标，可能来自安装包内嵌配置
          // 而不是上面填的值 —— 连接报错时先看这一行。
          //
          // 前面的圆点是「这台服务器现在连不连得上」，绿=已连接 / 黄=正在连接 /
          // 红=连接失败。状态来自 Rust 侧的看门狗线程（它每 3 秒对服务器端口做
          // 一次带超时的 TCP 探测），这里只做一次廉价读，不阻塞 UI。
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
          .borderRadius(12)
          .margin({ bottom: 16 })

          // --- Socks5/Http(s) Proxy（Android 是弹窗，这里内联）---
          this.subTitle('Socks5 / Http(s) 代理')

          this.textField('代理地址', '留空则直连', '例如 socks5://127.0.0.1:1080',
            this.proxyUrl, (v: string) => { this.proxyUrl = v; }, false)

          this.textField('用户名', '可留空', '可留空',
            this.proxyUser, (v: string) => { this.proxyUser = v; }, false)

          this.textField('密码', '可留空', '可留空',
            this.proxyPwd, (v: string) => { this.proxyPwd = v; }, true)

          // --- Use WebSocket / TLS fallback / Disable UDP ---
          this.subTitle('连接方式')

          this.toggleRow('使用 WebSocket', '中继不可达时退化到 WebSocket 隧道',
            this.allowWebsocket, (v: boolean) => { this.allowWebsocket = v; })

          this.toggleRow('允许不安全的 TLS 回退', '自建服务器证书有问题时才开',
            this.allowInsecureTls, (v: boolean) => { this.allowInsecureTls = v; })

          this.toggleRow('禁用 UDP', '完全不走 UDP（排查网络问题用，平时别开）',
            this.disableUdp, (v: boolean) => { this.disableUdp = v; })

          this.toggleRow('强制中继', '跳过直连打洞，一律走中继（NAT 严格时用）',
            this.forceAlwaysRelay, (v: boolean) => { this.forceAlwaysRelay = v; })

          // --- Hole punching ---
          this.subTitle('直连打洞')

          this.toggleRow('UDP 打洞', '直连的主要手段，关掉后基本只能走中继',
            this.enableUdpPunch, (v: boolean) => { this.enableUdpPunch = v; })

          this.toggleRow('TCP 打洞', 'UDP 不通时的备选直连方式',
            this.enableTcpPunch, (v: boolean) => { this.enableTcpPunch = v; })

          this.toggleRow('IPv6 P2P 连接', '两端都有 IPv6 时尝试直连',
            this.enableIpv6Punch, (v: boolean) => { this.enableIpv6Punch = v; })

          this.toggleRow('WebRTC P2P 连接', '用 WebRTC 建立 P2P（成功率取决于网络）',
            this.enableWebrtc, (v: boolean) => { this.enableWebrtc = v; })

          // --- Language / Theme / Keep awake ---
          // 「语言」「主题」在 Android 上是全 App 生效的选择器，鸿蒙版目前只
          // 随系统，这里做成只读展示，不给点了不生效的假开关。
          this.subTitle('界面')

          SettingCard() {
            this.linkRow('语言', '跟随系统', () => {
              promptAction.showToast({ message: '鸿蒙版目前跟随系统语言' });
            })
            Divider().color(C_DIVIDER)
            this.linkRow('主题', '跟随系统', () => {
              promptAction.showToast({ message: '鸿蒙版目前跟随系统深浅色' });
            })
          }

          this.toggleRow('外发会话期间保持唤醒', '主控时防止本机息屏',
            this.keepAwake, (v: boolean) => { this.keepAwake = v; })

          // ==================== 3. Hardware Codec ====================
          this.sectionTitle('硬件编解码')

          this.toggleRow('启用硬件编解码', '用设备硬解降低功耗与延迟；花屏时关掉',
            this.enableHwcodec, (v: boolean) => { this.enableHwcodec = v; })

          // ==================== 4. Recording ====================
          this.sectionTitle('录制')

          this.toggleRow('自动录制传入会话', '别人连我时自动开始录制',
            this.autoRecordIncoming, (v: boolean) => { this.autoRecordIncoming = v; })

          this.toggleRow('自动录制传出会话', '我连别人时自动开始录制',
            this.autoRecordOutgoing, (v: boolean) => { this.autoRecordOutgoing = v; })

          Column() {
            Text('录制文件目录')
              .fontSize(12)
              .fontColor(C_DIM)
              .width('100%')
            Text(this.recordDir.length > 0 ? this.recordDir : '（默认目录）')
              .fontSize(13)
              .fontColor(C_TEXT)
              .fontFamily('monospace')
              .width('100%')
              .margin({ top: 4 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(C_CARD)
          .borderRadius(12)
          .margin({ bottom: 16 })

          // ==================== 5. 2FA ====================
          // 依赖账号服务，鸿蒙版不接账号，整组不显示。

          // ==================== 6. Share screen ====================
          // 本端作为**被控端**时的策略，与主控设置分开放。
          // 手机形态没有被控能力，整组隐藏（否则是永远不生效的开关）。
          if (!this.isPhone) {
            this.sectionTitle('共享屏幕')

            this.toggleRow('拒绝局域网发现', '打开后同一网段内的设备搜不到本机',
              !this.enableLanDiscovery, (v: boolean) => { this.enableLanDiscovery = !v; })

            // 白名单：上游是弹一个可增删的列表对话框，这里折中为「点开就地编辑，
            // 一行一条」。功能等价，且省掉一个弹窗层级。
            SettingCard() {
              this.linkRow('使用 IP 白名单', this.whitelistLabel(), () => {
                this.showWhitelistEditor = !this.showWhitelistEditor;
              })
              if (this.showWhitelistEditor) {
                TextArea({ placeholder: '192.168.1.20\n192.168.1.21', text: this.whitelist })
                  .height(120)
                  .fontSize(14)
                  .backgroundColor(C_FIELD)
                  .fontColor('#FFFFFF')
                  .placeholderColor(C_HINT)
                  .borderRadius(12)
                  .margin({ bottom: 12 })
                  .onChange((v: string) => { this.whitelist = v; })
              }
              Divider().color(C_DIVIDER)
              this.linkRow('使用 ID 白名单', this.idWhitelistLabel(), () => {
                this.showIdWhitelistEditor = !this.showIdWhitelistEditor;
              })
              if (this.showIdWhitelistEditor) {
                TextArea({ placeholder: '123456789', text: this.idWhitelist })
                .height(120)
                .fontSize(14)
                .backgroundColor(C_FIELD)
                .fontColor('#FFFFFF')
                .placeholderColor(C_HINT)
                .borderRadius(12)
                .margin({ top: 12 })
                .onChange((v: string) => { this.idWhitelist = v; })
              }
            }

            this.toggleRow('自适应码率', '网络变差时自动降码率保流畅',
              this.enableAbr, (v: boolean) => { this.enableAbr = v; })

            this.toggleRow('启用会话录制', '对端能否录制本端屏幕',
              this.enableRecordSession, (v: boolean) => { this.enableRecordSession = v; })
          }

          // ==================== 7. Display Settings ====================
          // Android 是跳子页 _DisplayPage，里面是
          //   Default View Style → Default Image Quality → Default Codec。
          // 这里内联在同一列表里。
          this.sectionTitle('显示')

          this.selectRow('默认视图样式', '远端画面如何铺进屏幕', VIEW_STYLES, this.viewStyleIndex,
            (i: number) => { this.viewStyleIndex = i; })

          this.selectRow('默认图像质量', '清晰度与流畅度的取舍', IMAGE_QUALITIES, this.imageQualityIndex,
            (i: number) => { this.imageQualityIndex = i; })

          this.selectRow('默认编解码器', '一般保持自动即可', CODECS, this.codecIndex,
            (i: number) => { this.codecIndex = i; })

          // --- Other Default Options ---
          this.subTitle('其他默认选项')

          this.toggleRow('仅查看', '禁止向远端发送键鼠输入',
            this.viewOnly, (v: boolean) => { this.viewOnly = v; })

          this.toggleRow('显示远程光标', '显示被控机上的鼠标指针位置',
            this.showRemoteCursor, (v: boolean) => { this.showRemoteCursor = v; })

          this.toggleRow('跟随远程光标', '远端光标移动时自动滚动画面',
            this.followRemoteCursor, (v: boolean) => { this.followRemoteCursor = v; })

          this.toggleRow('跟随远程窗口焦点', '远端切换窗口时自动滚动到对应位置',
            this.followRemoteWindow, (v: boolean) => { this.followRemoteWindow = v; })

          this.toggleRow('显示质量监视器', '画面左上角显示码率 / 延迟',
            this.showQualityMonitor, (v: boolean) => { this.showQualityMonitor = v; })

          this.toggleRow('静音', '不传输远端声音',
            this.disableAudio, (v: boolean) => { this.disableAudio = v; })

          this.toggleRow('禁用剪贴板', '不与被控机同步剪贴板',
            this.disableClipboard, (v: boolean) => { this.disableClipboard = v; })

          this.toggleRow('会话结束后锁定', '断开后锁住远端屏幕',
            this.lockAfterSessionEnd, (v: boolean) => { this.lockAfterSessionEnd = v; })

          this.toggleRow('隐私模式', '连接时熄灭被控端屏幕',
            this.privacyMode, (v: boolean) => { this.privacyMode = v; })

          this.toggleRow('真彩（4:4:4）', '色彩更准，流量更大',
            this.i444, (v: boolean) => { this.i444 = v; })

          this.toggleRow('反向鼠标滚轮', '滚轮方向反过来的设备上打开',
            this.reverseMouseWheel, (v: boolean) => { this.reverseMouseWheel = v; })

          this.toggleRow('交换左右键', '左手习惯',
            this.swapLeftRightMouse, (v: boolean) => { this.swapLeftRightMouse = v; })

          // ==================== 8. Enhancements ====================
          // Android 这一组是系统能力（后台保活 / 开机自启 / 悬浮窗），
          // 鸿蒙没有对应机制，整组不显示。
          // 其中「启动时检查更新」在 Android 上也在这一组，同样跳过。

          // ==================== 9. About ====================
          this.sectionTitle('关于')

          SettingCard() {
            this.linkRow('版本', APP_VERSION, () => {
              router.pushUrl({ url: 'pages/About' }).catch(() => {
              promptAction.showToast({ message: '打开关于页失败' });
              });
            })
            Divider().color(C_DIVIDER)
            Row() {
              Text('显示 / 声音 / 网络选项').fontSize(13).fontColor(C_DIM)
              Blank()
              Text('下次连接生效').fontSize(13).fontColor(C_TEXT)
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
          }

          Button(this.saving ? '保存中…' : '保存')
            .width('100%')
            .height(50)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(C_ACCENT)
            .borderRadius(12)
            .enabled(!this.saving)
            .onClick(() => { this.onSave(); })
            .margin({ bottom: 32 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 12 })
    .backgroundColor(C_BG)
  }
}

// 卡片容器。
//
// 必须用 `@BuilderParam` 组件而不是「@Builder 函数接 lambda 参数」：ArkTS
// 不允许在 builder 里调用传入的普通函数，会报
// `10905204 does not meet UI component syntax`。
// 尾随 lambda（`SettingCard() { ... }`）才是 ArkUI 传 builder 的合法写法，
// 但也因此里面只能写 UI 组件语法，不能写普通语句。
@Component
struct SettingCard {
  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content();
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .backgroundColor(C_CARD)
    .borderRadius(12)
    .margin({ bottom: 12 })
  }
}
