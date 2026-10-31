import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { RustDesk, ServerConfig } from '../common/RustDesk';

// 服务器设置页：自建服务器的四个配置项。
//
// 为什么必须有这一页：鸿蒙版目前只有主控链路，启动就直奔「输入 ID 连接」，
// 而默认地址是官方公共服务器 —— 自建服务器的用户不配这一项根本连不上。
// 四个键与上游桌面端「ID/中继服务器」设置页完全对应，配置也写在同一个
// config 文件里，所以两端可以互相对照排查。
//
// 留空的语义（与上游一致）：
//   中继服务器空 → 用 ID 服务器下发的地址（由服务端告知，通常是同机 21117）
//   API 服务器空 → http://<ID服务器>:21114
//   公钥空       → 不做服务端身份校验，连不上时优先怀疑这里

@Entry
@Component
struct Settings {
  @State idServer: string = '';
  @State relayServer: string = '';
  @State apiServer: string = '';
  @State serverKey: string = '';
  @State effectiveServer: string = '';
  @State saving: boolean = false;

  aboutToAppear(): void {
    const cfg: ServerConfig = RustDesk.getConfig();
    this.idServer = cfg.idServer;
    this.relayServer = cfg.relayServer;
    this.apiServer = cfg.apiServer;
    this.serverKey = cfg.key;
    this.effectiveServer = cfg.effectiveServer;
  }

  private onSave(): void {
    // 只提示不拦截：清空 ID 服务器是恢复「用公共服务器」的合法操作。
    const cfg: ServerConfig = new ServerConfig();
    cfg.idServer = this.idServer;
    cfg.relayServer = this.relayServer;
    cfg.apiServer = this.apiServer;
    cfg.key = this.serverKey;

    this.saving = true;
    const rc: number = RustDesk.saveConfig(cfg);
    this.saving = false;

    if (rc !== 0) {
      promptAction.showToast({ message: `保存失败（${rc}）：${RustDesk.getLastError()}` });
      return;
    }

    // 保存后立刻回读一次：Rust 侧会拒绝被安装包内嵌配置锁住的键，
    // 直接信任「写成功」会让用户以为改好了。
    const after: ServerConfig = RustDesk.getConfig();
    this.effectiveServer = after.effectiveServer;
    if (after.idServer !== this.idServer.trim()) {
      promptAction.showToast({ message: 'ID 服务器未能保存：可能被安装包内嵌配置覆盖' });
      return;
    }

    promptAction.showToast({ message: '已保存，连接时生效' });
    router.back();
  }

  @Builder
  fieldLabel(text: string, hint: string) {
    Row() {
      Text(text)
        .fontSize(14)
        .fontColor('#C7D0E0')
      Text(hint)
        .fontSize(12)
        .fontColor('#5A6478')
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .margin({ bottom: 6 })
  }

  build() {
    Column() {
      // --- 顶栏 ---
      Row() {
        Text('返回')
          .fontSize(16)
          .fontColor('#2F81F7')
          .onClick(() => { router.back(); })
        Blank()
        Text('服务器设置')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
        Blank()
        // 与左侧「返回」等宽的占位，保证标题真正居中
        Text('返回')
          .fontSize(16)
          .fontColor(Color.Transparent)
      }
      .width('100%')
      .margin({ top: 20, bottom: 24 })

      Scroll() {
        Column() {
          Text('自建服务器必填。留空表示使用默认值。')
            .fontSize(13)
            .fontColor('#8A94A6')
            .width('100%')
            .margin({ bottom: 20 })

          this.fieldLabel('ID 服务器', '自建 hbbs 的地址')
          TextInput({ placeholder: '例如 192.168.1.10 或 rd.example.com:21116', text: this.idServer })
            .height(50)
            .fontSize(16)
            .backgroundColor('#161E2E')
            .fontColor('#FFFFFF')
            .placeholderColor('#5A6478')
            .borderRadius(12)
            .onChange((v: string) => { this.idServer = v; })
            .margin({ bottom: 18 })

          this.fieldLabel('中继服务器', '留空＝用服务器下发的')
          TextInput({ placeholder: '例如 192.168.1.10:21117', text: this.relayServer })
            .height(50)
            .fontSize(16)
            .backgroundColor('#161E2E')
            .fontColor('#FFFFFF')
            .placeholderColor('#5A6478')
            .borderRadius(12)
            .onChange((v: string) => { this.relayServer = v; })
            .margin({ bottom: 18 })

          this.fieldLabel('API 服务器', '地址簿 / 在线状态')
          TextInput({ placeholder: '留空则用 http://<ID服务器>:21114', text: this.apiServer })
            .height(50)
            .fontSize(16)
            .backgroundColor('#161E2E')
            .fontColor('#FFFFFF')
            .placeholderColor('#5A6478')
            .borderRadius(12)
            .onChange((v: string) => { this.apiServer = v; })
            .margin({ bottom: 18 })

          this.fieldLabel('服务器公钥 Key', 'id_ed25519.pub 的内容')
          TextArea({ placeholder: 'hbbs 主机上 cat id_ed25519.pub 得到的一行字符串', text: this.serverKey })
            .height(96)
            .fontSize(14)
            .backgroundColor('#161E2E')
            .fontColor('#FFFFFF')
            .placeholderColor('#5A6478')
            .borderRadius(12)
            .onChange((v: string) => { this.serverKey = v; })
            .margin({ bottom: 18 })

          // 生效地址：Rust 侧算出来的真实目标，可能来自安装包内嵌配置而
          // 不是上面填的值 —— 连接报错时先看这一行。
          Column() {
            Text('当前生效的 ID 服务器')
              .fontSize(12)
              .fontColor('#8A94A6')
              .width('100%')
            Text(this.effectiveServer.length > 0 ? this.effectiveServer : '（未初始化）')
              .fontSize(14)
              .fontColor('#E6EDF7')
              .fontFamily('monospace')
              .width('100%')
              .margin({ top: 4 })
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#101827')
          .borderRadius(12)
          .margin({ bottom: 24 })

          Button(this.saving ? '保存中…' : '保存')
            .width('100%')
            .height(50)
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .backgroundColor('#2F81F7')
            .borderRadius(12)
            .enabled(!this.saving)
            .onClick(() => { this.onSave(); })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor('#0B1220')
  }
}
