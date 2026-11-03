import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { common, Want } from '@kit.AbilityKit';
import { RustDesk } from '../common/RustDesk';
import { appVersionLabel } from '../common/Version';

// 关于页。
//
// 对应 Android 的 showAbout（flutter/lib/mobile/pages/settings_page.dart:1207）：
// 一个「版本 + 官网」的弹窗。鸿蒙版做成独立路由页，顺带把排障时最常问的
// 几项也放上来：本机 ID、核心版本、ABI 版本。
//
// 版本有三套，别混：
//   - 应用版本：AppScope/app.json5 的 versionName，安装包自己的；
//   - 核心版本：Rust 侧 crate::version::VERSION，协议与编解码跟着它走；
//   - ABI 版本：libentry.so 与 Rust 静态库之间的接口版本号（entry.rs ABI_VERSION）。
//     这两个数字对不上说明 .a 没重编，现象是 native 方法直接 undefined。

const C_BG: string = '#0B1220';
const C_CARD: string = '#101827';
const C_TEXT: string = '#E6EDF7';
const C_DIM: string = '#8A94A6';
const C_FAINT: string = '#5A6478';
const C_ACCENT: string = '#0071FF';
const C_DIVIDER: string = '#1F2A3D';

// 版本串由 common/Version.ets 统一生成：`0.1.0 (1.5.1) for HarmonyOS`。
// 前半段是鸿蒙版自己的版本基数，括号里是上游 RustDesk 的核心版本。

const URL_HOME: string = 'https://rustdesk.com/';
// 隐私政策走应用内页面（pages/Privacy.ets），不再指向外部网页 ——
// 应用市场要求应用内可查看，外链在离线/无浏览器时等于没有。
// 项目地址：GitHub 仓库就绪前先用 lx-soft.net 占位，仓库开好后替换成真实地址。
const URL_PROJECT: string = 'https://github.com/shaliuxin/rustdesk-harmonyos';
const PROJECT_URL_LABEL: string = 'github.com/shaliuxin/rustdesk-harmonyos';

@Entry
@Component
struct About {
  @State coreVersion: string = '';
  @State abiVersion: number = 0;
  @State myId: string = '';
  // 完整版本串，见 common/Version.ets
  @State appVersion: string = '';

  aboutToAppear(): void {
    this.appVersion = appVersionLabel();
    this.coreVersion = RustDesk.coreVersion();
    this.myId = RustDesk.getConfig().id;
  }

  private copy(text: string): void {
    if (text.length === 0) {
      return;
    }
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

  // 用系统浏览器打开外链。
  //
  // 走 want 的 viewData 而不是拉起某个具体应用：用户装了什么浏览器不确定，
  // 交给系统解析最稳。失败了就退回复制网址 —— 至少用户还能自己粘到浏览器里。
  private openUrl(url: string): void {
    try {
      const ctx: common.UIAbilityContext =
        getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url,
      };
      ctx.startAbility(want).then(() => {
        // 拉起成功，什么都不用做。
      }).catch(() => {
        this.copy(url);
        promptAction.showToast({ message: '无法打开浏览器，网址已复制' });
      });
    } catch (e) {
      this.copy(url);
      promptAction.showToast({ message: '无法打开浏览器，网址已复制' });
    }
  }

  @Builder
  infoRow(label: string, value: string, mono: boolean, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(C_DIM)
      Blank()
      Text(value.length > 0 ? value : '—')
        .fontSize(14)
        .fontColor(C_TEXT)
        .fontFamily(mono ? 'monospace' : 'HarmonyOS Sans')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(() => { onTap(); })
  }

  build() {
    Column() {
      // AppBar：Android 的独立页都是居中标题 + 左侧返回。
      Row() {
        Text('←')
          .fontSize(22)
          .fontColor('#FFFFFF')
          .width(40)
          .textAlign(TextAlign.Center)
          .onClick(() => { router.back(); })
        Text('关于')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_TEXT)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        // 右侧留一个等宽占位，标题才是真的居中。
        Text('')
          .width(40)
      }
      .width('100%')
      .height(56)
      .padding({ left: 8, right: 8 })

      Scroll() {
        Column() {
          // --- 品牌区 ---
          Column() {
            Text('RemoteDesk for HarmonyOS')
              .fontSize(28)
              .fontWeight(FontWeight.Bold)
              .fontColor(C_ACCENT)
              .margin({ bottom: 6 })
            Text('基于开源 RustDesk · 鸿蒙远程桌面')
              .fontSize(13)
              .fontColor(C_DIM)
          }
          .width('100%')
          .padding({ top: 24, bottom: 28 })
          .justifyContent(FlexAlign.Center)

          // --- 版本 ---
          Column() {
            this.infoRow('应用版本', this.appVersion, false, () => { this.copy(this.appVersion); })
            Divider().color(C_DIVIDER)
            this.infoRow('核心版本', this.coreVersion, false, () => { this.copy(this.coreVersion); })
            Divider().color(C_DIVIDER)
            this.infoRow('本机 ID', this.myId, true, () => { this.copy(this.myId); })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor(C_CARD)
          .borderRadius(13)
          .margin({ bottom: 20 })

          // --- 链接 ---
          Column() {
            Row() {
              Text('官网')
                .fontSize(14)
                .fontColor(C_TEXT)
              Blank()
              Text('rustdesk.com ›')
                .fontSize(13)
                .fontColor(C_ACCENT)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => { this.openUrl(URL_HOME); })

            Divider().color(C_DIVIDER)

            // 项目地址：仓库源码入口，点按跳转系统浏览器打开 GitHub 仓库。
            Row() {
              Text('项目地址')
                .fontSize(14)
                .fontColor(C_TEXT)
              Blank()
              Text(PROJECT_URL_LABEL + ' ›')
                .fontSize(13)
                .fontColor(C_ACCENT)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            .onClick(() => { this.openUrl(URL_PROJECT); })

            Divider().color(C_DIVIDER)

            Row() {
              Text('隐私政策')
                .fontSize(14)
                .fontColor(C_TEXT)
              Blank()
              Text('›')
                .fontSize(13)
                .fontColor(C_FAINT)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
            // 走应用内页面而不是外链：应用市场审核要求「应用内可查看隐私政策」，
            // 甩给浏览器在离线或未装浏览器时就等于没有。
            .onClick(() => { router.pushUrl({ url: 'pages/Privacy' }); })

            Divider().color(C_DIVIDER)

            Row() {
              Text('开源许可')
                .fontSize(14)
                .fontColor(C_TEXT)
              Blank()
              Text('AGPL-3.0')
                .fontSize(13)
                .fontColor(C_DIM)
            }
            .width('100%')
            .padding({ top: 14, bottom: 14 })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor(C_CARD)
          .borderRadius(13)
          .margin({ bottom: 20 })

          Text('RemoteDesk for HarmonyOS 是基于开源 RustDesk 的鸿蒙远程桌面客户端。\n'
            + '支持远程控制、文件传输与共享屏幕（平板/PC 形态）。')
            .fontSize(12)
            .fontColor(C_FAINT)
            .lineHeight(18)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 32 })
        }
        .width('100%')
        .padding({ left: 12, right: 12 })
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
