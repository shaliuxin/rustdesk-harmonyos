import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { buffer } from '@kit.ArkTS';
import { RustDesk, ServerConfig } from '../common/RustDesk';

// 扫码 / 导入配置。
//
// 对应 Android 的 ScanPage（flutter/lib/mobile/pages/scan_page.dart），
// Android 上用 qr_code_scanner 扫一个 `config=<base64url 反转>` 的二维码，
// 扫出来直接落到服务器设置上。
//
// 鸿蒙这边**做不了相机扫码**，原因是硬性的：
//   1. 当前用的是 OpenHarmony public SDK（API 26），里面没有 ScanKit
//      （@kit.ScanKit 是华为商用 SDK 才有）；
//   2. CameraKit 只能给到预览帧，解码还得自己来 —— 而 Rust 侧目前只有
//      qrcode-generator（**生成**二维码），没有任何解码库。
// 所以这里把同一条链路的「后半段」做成可用的：粘贴/导入 config 串。
// 自建服务器的用户本来就是从 rustdesk-server 的二维码或导出的字符串拿到它，
// 粘贴和扫码在这个场景下等价。
//
// 编码格式（与上游 ServerConfig.decode / encode 逐字对齐，见
// flutter/lib/common.dart:2938）：
//   明文 JSON {"host":..,"relay":..,"api":..,"key":..}
//   → base64url 编码（无 padding）
//   → 整串反转
//   → 前面拼 "config="
// 上游还兼容「直接就是 JSON 明文」的旧格式，这里同样先试 JSON、再试反转 base64。

const C_BG: string = '#0B1220';
const C_CARD: string = '#101827';
const C_FIELD: string = '#161E2E';
const C_TEXT: string = '#E6EDF7';
const C_DIM: string = '#8A94A6';
const C_FAINT: string = '#5A6478';
const C_ACCENT: string = '#0071FF';
const C_WARN: string = '#FFC857';
const C_DIVIDER: string = '#1F2A3D';

const PREFIX: string = 'config=';

class ServerConf {
  idServer: string = '';
  relayServer: string = '';
  apiServer: string = '';
  key: string = '';
}

@Entry
@Component
struct Scan {
  @State input: string = '';
  @State parsed: ServerConf | null = null;
  @State parseError: string = '';

  private reverse(s: string): string {
    let out: string = '';
    for (let i: number = s.length - 1; i >= 0; i--) {
      out += s[i];
    }
    return out;
  }

  // base64url → base64：换字母表 + 补 padding。
  // 不用 'base64url' 字面量是因为不确定 @ohos.buffer 在所有版本上都认它，
  // 换算成标准 base64 是永远安全的那一档。
  private normalizeBase64(s: string): string {
    let out: string = '';
    for (let i: number = 0; i < s.length; i++) {
      const c: string = s[i];
      if (c === '-') {
        out += '+';
      } else if (c === '_') {
        out += '/';
      } else {
        out += c;
      }
    }
    const rem: number = out.length % 4;
    if (rem === 2) {
      out += '==';
    } else if (rem === 3) {
      out += '=';
    }
    return out;
  }

  // 解析 config 串。失败返回 null 并填 parseError。
  private decode(raw: string): ServerConf | null {
    let s: string = raw.trim();
    if (s.length === 0) {
      this.parseError = '内容是空的';
      return null;
    }
    if (s.startsWith(PREFIX)) {
      s = s.substring(PREFIX.length);
    }

    let json: string = '';
    try {
      // 先按「反转过的 base64url」解；解出来不是合法 UTF-8 JSON 再试明文。
      const b64: string = this.normalizeBase64(this.reverse(s));
      json = buffer.from(b64, 'base64').toString('utf-8');
    } catch (e) {
      json = '';
    }
    if (json.length === 0 || json[0] !== '{') {
      // 上游的 back compatible 分支：直接就是 JSON 明文。
      json = s;
    }

    try {
      const obj: object = JSON.parse(json) as object;
      const c: ServerConf = new ServerConf();
      const rec: Record<string, string> = obj as Record<string, string>;
      c.idServer = (rec['host'] ?? '').trim();
      c.relayServer = (rec['relay'] ?? '').trim();
      c.apiServer = (rec['api'] ?? '').trim();
      c.key = (rec['key'] ?? '').trim();
      this.parseError = '';
      return c;
    } catch (e) {
      this.parseError = '解析失败：不是有效的 config 串';
      return null;
    }
  }

  private onParse(): void {
    this.parsed = this.decode(this.input);
    if (this.parsed === null) {
      promptAction.showToast({ message: this.parseError });
    }
  }

  private onPaste(): void {
    try {
      const pb: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      pb.getData((err: BusinessError, data: pasteboard.PasteData) => {
        if (err) {
          promptAction.showToast({ message: '读取剪贴板失败' });
          return;
        }
        const text: string = data.getPrimaryText() ?? '';
        if (text.length === 0) {
          promptAction.showToast({ message: '剪贴板是空的' });
          return;
        }
        this.input = text;
        this.onParse();
      });
    } catch (e) {
      promptAction.showToast({ message: '读取剪贴板失败' });
    }
  }

  // 把解析结果写进服务器设置。与设置页的保存同一条路径（RustDesk.saveConfig），
  // 所以同样受「安装包内嵌配置锁键」的影响 —— 写不进去会如实提示。
  private onApply(): void {
    const c: ServerConf | null = this.parsed;
    if (c === null) {
      promptAction.showToast({ message: '请先解析' });
      return;
    }
    const cfg: ServerConfig = new ServerConfig();
    cfg.idServer = c.idServer;
    cfg.relayServer = c.relayServer;
    cfg.apiServer = c.apiServer;
    cfg.key = c.key;
    const rc: number = RustDesk.saveConfig(cfg);
    if (rc !== 0) {
      promptAction.showToast({ message: `导入失败（${rc}）：${RustDesk.getLastError()}` });
      return;
    }
    promptAction.showToast({ message: '已导入，下次连接生效' });
    setTimeout(() => { router.back(); }, 600);
  }

  @Builder
  resultRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(C_DIM)
        .width(90)
      Text(value.length > 0 ? value : '（空）')
        .fontSize(13)
        .fontColor(value.length > 0 ? C_TEXT : C_FAINT)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(22)
          .fontColor('#FFFFFF')
          .width(40)
          .textAlign(TextAlign.Center)
          .onClick(() => { router.back(); })
        Text('导入配置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('')
          .width(40)
      }
      .width('100%')
      .height(56)
      .padding({ left: 8, right: 8 })

      Scroll() {
        Column() {
          // 为什么没有相机扫码，说清楚，别让用户对着空白页猜。
          Column() {
            Row() {
              Text('!')
                .fontSize(14)
                .fontColor(C_WARN)
                .margin({ right: 8 })
              Text('相机扫码暂不可用')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(C_WARN)
            }
            .width('100%')
            Text('当前鸿蒙 SDK 不含扫码能力，Rust 侧也没有二维码解码库。\n'
              + '请用下面这栏粘贴 rustdesk-server 生成的 config 串 —— 效果与扫码一致。')
              .fontSize(12)
              .fontColor(C_DIM)
              .lineHeight(18)
              .width('100%')
              .margin({ top: 6 })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(C_CARD)
          .borderRadius(13)
          .margin({ bottom: 16 })

          TextArea({ placeholder: '以 config= 开头的一串字符', text: this.input })
            .height(120)
            .fontSize(13)
            .fontColor(C_TEXT)
            .placeholderColor(C_FAINT)
            .backgroundColor(C_FIELD)
            .borderRadius(12)
            .onChange((v: string) => { this.input = v; })
            .margin({ bottom: 12 })

          Row() {
            Text('从剪贴板粘贴')
              .fontSize(14)
              .fontColor(C_ACCENT)
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .borderRadius(10)
              .backgroundColor('#1B2536')
              .onClick(() => { this.onPaste(); })

            Blank()

            Text('解析')
              .fontSize(14)
              .fontColor('#FFFFFF')
              .padding({ left: 20, right: 20, top: 10, bottom: 10 })
              .borderRadius(10)
              .backgroundColor(C_ACCENT)
              .onClick(() => { this.onParse(); })
          }
          .width('100%')
          .margin({ bottom: 16 })

          if (this.parsed !== null) {
            Column() {
              Text('解析结果')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(C_TEXT)
                .width('100%')
                .margin({ bottom: 4 })

              Divider().color(C_DIVIDER)
              this.resultRow('ID 服务器', (this.parsed as ServerConf).idServer)
              Divider().color(C_DIVIDER)
              this.resultRow('中继服务器', (this.parsed as ServerConf).relayServer)
              Divider().color(C_DIVIDER)
              this.resultRow('API 服务器', (this.parsed as ServerConf).apiServer)
              Divider().color(C_DIVIDER)
              this.resultRow('公钥 Key', (this.parsed as ServerConf).key)
            }
            .width('100%')
            .padding(14)
            .backgroundColor(C_CARD)
            .borderRadius(13)
            .margin({ bottom: 16 })

            Button('导入并保存')
              .width('100%')
              .height(50)
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .backgroundColor('#2F81F7')
              .borderRadius(12)
              .onClick(() => { this.onApply(); })
              .margin({ bottom: 32 })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8 })
      }
      .layoutWeight(1)
      // 滚动条常驻 + 允许左键拖动滚动（Scroll 默认不支持鼠标拖，见 Settings.ets 注释）。
      .scrollBar(BarState.Auto)
      .enableScrollWithMouse(true)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
