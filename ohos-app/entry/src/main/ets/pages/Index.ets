import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { RustDesk } from '../common/RustDesk';

// 连接页：输入远端 ID / 密码，然后进会话页。
//
// 这一页刻意不显示「最近连接列表」——那需要持久化，属于 M2。
// M1 的目标是「能连上、能看到画面、能操作」。

@Entry
@Component
struct Index {
  @State peerId: string = '';
  @State password: string = '';
  @State showPassword: boolean = false;
  @State connecting: boolean = false;
  // 实际生效的 ID 服务器。放在首页是因为「连不上」最常见的原因就是
  // 地址还指着默认公共服务器，让它在连接按钮旁边一直可见，比藏在设置里好。
  @State serverLabel: string = '';

  aboutToAppear(): void {
    this.refreshServer();
  }

  // 从设置页返回时也要刷新（页面不会重建，只有 onPageShow 会触发）。
  onPageShow(): void {
    this.refreshServer();
  }

  private refreshServer(): void {
    this.serverLabel = RustDesk.getConfig().effectiveServer;
  }

  private openSettings(): void {
    router.pushUrl({ url: 'pages/Settings' }).catch((e: Error) => {
      promptAction.showToast({ message: `打开设置失败：${e.message}` });
    });
  }

  private onConnect(): void {
    const id: string = this.peerId.trim();
    if (id.length === 0) {
      promptAction.showToast({ message: '请输入远端 ID' });
      return;
    }
    if (!RustDesk.isInitialized()) {
      promptAction.showToast({ message: `核心未初始化：${RustDesk.getLastError()}` });
      return;
    }

    this.connecting = true;
    const rc: number = RustDesk.startSession(id, this.password, false);
    if (rc !== 0) {
      this.connecting = false;
      promptAction.showToast({ message: `发起连接失败（${rc}）：${RustDesk.getLastError()}` });
      return;
    }

    // startSession 是「发起」不是「完成」：真正的连接结果由会话页通过
    // connected / close 事件上报。所以这里立刻跳转，会话页负责显示进度。
    router.pushUrl({
      url: 'pages/SessionPage',
      params: { peerId: id }
    }).catch((e: Error) => {
      this.connecting = false;
      promptAction.showToast({ message: `打开会话页失败：${e.message}` });
    });
    this.connecting = false;
  }

  build() {
    Column() {
      Row() {
        Text('RustDesk')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Blank()
        // 设置入口。用文字而不是图标：media 目录里没有 gear 图标，
        // 引一个不存在的资源会在打包时才报错。
        Text('设置')
          .fontSize(16)
          .fontColor('#2F81F7')
          .padding({ left: 12, top: 8, bottom: 8 })
          .onClick(() => { this.openSettings(); })
      }
      .width('100%')
      .margin({ top: 72, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      Text('远程桌面 · 鸿蒙版')
        .fontSize(14)
        .fontColor('#8A94A6')

      Text(`服务器：${this.serverLabel.length > 0 ? this.serverLabel : '未初始化'}`)
        .fontSize(12)
        .fontColor('#5A6478')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 8, bottom: 40 })
        .onClick(() => { this.openSettings(); })

      TextInput({ placeholder: '远端 ID，例如 123456789', text: this.peerId })
        .type(InputType.Number)
        .height(52)
        .fontSize(17)
        .backgroundColor('#161E2E')
        .fontColor('#FFFFFF')
        .placeholderColor('#5A6478')
        .borderRadius(12)
        .onChange((v: string) => { this.peerId = v; })
        .margin({ bottom: 12 })

      if (this.showPassword) {
        TextInput({ placeholder: '密码（可留空，连接后再输入）', text: this.password })
          .type(InputType.Password)
          .height(52)
          .fontSize(17)
          .backgroundColor('#161E2E')
          .fontColor('#FFFFFF')
          .placeholderColor('#5A6478')
          .borderRadius(12)
          .onChange((v: string) => { this.password = v; })
          .margin({ bottom: 12 })
      }

      Button(this.connecting ? '连接中…' : '连接')
        .width('100%')
        .height(52)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .backgroundColor('#2F81F7')
        .borderRadius(12)
        .enabled(!this.connecting)
        .onClick(() => { this.onConnect(); })
        .margin({ top: 12 })

      Row() {
        Text(this.showPassword ? '隐藏密码输入' : '预设密码')
          .fontSize(14)
          .fontColor('#2F81F7')
          .onClick(() => { this.showPassword = !this.showPassword; })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .margin({ top: 16 })

      Blank()

      Text('M1 · 主控链路')
        .fontSize(12)
        .fontColor('#4A5468')
        .margin({ bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor('#0B1220')
  }
}
