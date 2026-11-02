import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';

// 应用内隐私政策页。
//
// 应用市场审核（AGC）明确要求「用户能在应用内查看隐私政策」，指向外部
// 网页在离线、未装浏览器、链接失效时等于没有，因此这里放一份完整正文。
// 底部再给上游在线版链接，作为长期维护的补充。
//
// 内容必须与实际行为一致 —— 审核会比对「声明的权限/数据行为」和「真实
// 功能」。改功能时（例如接入统计、崩溃上报）务必同步改这里的条款。

const C_BG: string = '#0B1220';
const C_CARD: string = '#101827';
const C_TEXT: string = '#E6EDF7';
const C_DIM: string = '#8A94A6';
const C_FAINT: string = '#5A6478';
const C_ACCENT: string = '#0071FF';
const C_DIVIDER: string = '#1F2A3D';

const URL_PRIVACY_ONLINE: string = 'https://rustdesk.com/privacy.html';
const POLICY_DATE: string = '2026 年 11 月 2 日';

class Section {
  title: string;
  body: string;

  constructor(title: string, body: string) {
    this.title = title;
    this.body = body;
  }
}

const SECTIONS: Section[] = [
  new Section('一、我们收集哪些信息',
    '本应用不收集、不上传任何个人身份信息，也不含广告、统计分析或崩溃上报 SDK。\n\n'
    + '应用运行时产生的全部数据（服务器配置、连接记录、收藏、密钥）都保存在你设备的应用私有目录中，'
    + '只有你自己能访问。卸载应用即随之删除。'),
  new Section('二、设备 ID 与连接信息',
    '应用会生成一个随机的设备 ID（由 RustDesk 协议规定），并注册到你自行配置的 ID 服务器，'
    + '用于让其他设备找到你。该 ID 是随机字符串，不含你的姓名、手机号或账号信息。\n\n'
    + '建立远程连接时，对端设备可以看到你的设备 ID、主机名和操作系统类型 —— 这是完成连接所必需的信息。'
    + '如果你不希望暴露主机名，可在系统设置中修改设备名称。'),
  new Section('三、权限使用说明',
    '· 网络访问（ohos.permission.INTERNET）：用于连接远程设备、传输屏幕画面与文件。\n\n'
    + '· 获取网络信息（ohos.permission.GET_NETWORK_INFO）：用于判断当前网络环境，'
    + '以选择直连或中继线路，提升连接成功率。\n\n'
    + '除上述两项外，本应用不申请通讯录、位置、相册、麦克风、摄像头等任何其他权限。'),
  new Section('四、屏幕画面与键鼠输入',
    '远程会话中的屏幕画面、鼠标键盘输入只在你与被控设备之间传输。传输采用端到端加密'
    + '（NaCl 加密 + 密钥交换），中继服务器只转发加密后的数据流，无法解密其内容。\n\n'
    + '画面不会被录制、截屏留存或上传到任何第三方。'),
  new Section('五、文件传输',
    '文件传输只在你主动选择文件并点击上传/下载时发生，传输路径为设备之间（直连或经你配置的中继服务器）。'
    + '应用本身不留存、不转存任何传输内容。\n\n'
    + '接收到的文件保存在你指定的目录中；下载过程中的临时文件（同名 .download / .digest）会在完成后自动清理。'),
  new Section('六、剪贴板',
    '远程会话期间，剪贴板内容会在你与被控设备之间同步，以便复制粘贴文本。'
    + '该同步仅在会话进行中生效，会话结束后立即停止，内容不做任何留存。'),
  new Section('七、第三方服务',
    '本应用是开源项目 RustDesk 的鸿蒙衍生客户端。ID 服务器与中继服务器地址由你自行填写：\n\n'
    + '· 使用你自建的服务器时，数据仅经过你自己的服务器；\n'
    + '· 使用第三方公共服务器时，该服务器的运营方可能记录连接元数据（IP、设备 ID、连接时间），'
    + '其行为受该服务方的隐私政策约束，与本应用无关。\n\n'
    + '本应用不内置任何第三方统计、推送或广告服务。'),
  new Section('八、未成年人保护',
    '本应用为远程桌面工具，不面向未成年人设计，也不会主动收集未成年人的任何信息。'
    + '未成年人应在监护人指导下使用。'),
  new Section('九、你的权利',
    '你可以随时：\n\n'
    + '· 在「设置」中清除服务器配置、收藏与连接记录；\n'
    + '· 卸载应用，一次性删除全部本地数据；\n'
    + '· 停止使用，无需任何申请流程。\n\n'
    + '由于本应用不收集服务器侧的个人数据，因此不存在需要向开发者申请导出或删除的账户数据。'),
  new Section('十、政策更新',
    '本政策可能随功能变化而更新，最新版本随应用一起发布，'
    + '并在本页顶部标注生效日期。若涉及数据收集范围的实质性变化，会在应用内显著提示。'),
  new Section('十一、联系我们',
    '对本政策有任何疑问，可通过项目仓库提交 Issue：\n'
    + 'github.com/shaliuxin/rustdesk-harmonyos'),
];

@Entry
@Component
struct Privacy {
  private openUrl(url: string): void {
    try {
      const ctx: common.UIAbilityContext =
        getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url,
      };
      ctx.startAbility(want).catch(() => {
        this.copy(url);
        promptAction.showToast({ message: '无法打开浏览器，网址已复制' });
      });
    } catch (e) {
      this.copy(url);
      promptAction.showToast({ message: '无法打开浏览器，网址已复制' });
    }
  }

  private copy(text: string): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '已复制' });
      }).catch(() => {
        promptAction.showToast({ message: '复制失败' });
      });
    } catch (e) {
      promptAction.showToast({ message: '复制失败' });
    }
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
        Text('隐私政策')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        // 右侧等宽占位，标题才真的居中。
        Text('')
          .width(40)
      }
      .width('100%')
      .height(56)
      .padding({ left: 8, right: 8 })

      Scroll() {
        Column() {
          Column() {
            Text('RemoteDesk 隐私政策')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(C_TEXT)
              .margin({ bottom: 8 })
            Text(`生效日期：${POLICY_DATE}`)
              .fontSize(12)
              .fontColor(C_FAINT)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 8, bottom: 20 })

          // 一句话摘要，审核和用户都先看到这句。
          Text('简单说：本应用不收集你的任何个人信息，所有数据只留在你的设备上。')
            .fontSize(14)
            .fontColor(C_ACCENT)
            .lineHeight(22)
            .width('100%')
            .padding(14)
            .backgroundColor(C_CARD)
            .borderRadius(12)
            .margin({ bottom: 20 })

          ForEach(SECTIONS, (s: Section) => {
            Column() {
              Text(s.title)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(C_TEXT)
                .width('100%')
                .margin({ bottom: 8 })
              Text(s.body)
                .fontSize(13)
                .fontColor(C_DIM)
                .lineHeight(22)
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(C_CARD)
            .borderRadius(12)
            .margin({ bottom: 12 })
          }, (s: Section) => s.title)

          // 上游在线版：条款的长期维护版本在这里。
          Row() {
            Text('查看 RustDesk 上游隐私政策')
              .fontSize(13)
              .fontColor(C_ACCENT)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .onClick(() => { this.openUrl(URL_PRIVACY_ONLINE); })

          Divider().color(C_DIVIDER).margin({ bottom: 14 })

          Text('本应用基于开源项目 RustDesk（AGPL-3.0）构建，\n'
            + '与 RustDesk 官方无隶属关系。')
            .fontSize(11)
            .fontColor(C_FAINT)
            .lineHeight(17)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 32 })
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .enableScrollWithMouse(true)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
