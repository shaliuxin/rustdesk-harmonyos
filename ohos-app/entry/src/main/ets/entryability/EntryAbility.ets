import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RustDesk } from '../common/RustDesk';

const DOMAIN: number = 0x3200;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Rust 核心的初始化必须在这里做，而且必须在任何页面加载之前 ——
    // 页面一 build 就会读 state()，晚初始化会拿到空状态。
    //
    // filesDir 是应用沙箱内的私有目录，Rust 会在下面建 RustDesk 的
    // config / 日志 / 密钥。不用 context.cacheDir：那里可能被系统清理，
    // 而 id/私钥丢了就意味着「换了设备」。
    const ok: boolean = RustDesk.init(this.context.filesDir);
    if (!ok) {
      hilog.error(DOMAIN, TAG, 'core init failed: %{public}s', RustDesk.getLastError());
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Home', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'content loaded');
    });
  }

  onForeground(): void {
    // 回到前台才继续拉帧。后台保持 30fps 会让系统把应用判成高耗电。
    RustDesk.setRenderActive(true);
  }

  onBackground(): void {
    RustDesk.setRenderActive(false);
  }

  onDestroy(): void {
    // 进程退出前主动断开会话：Rust 侧的 io_loop 是阻塞线程，
    // 不主动关的话对端要等心跳超时才释放。
    RustDesk.closeSession();
  }
}
