import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 形态判定：当前是否跑在手机（或手表）上。
 *
 * 为什么需要这个判断 —— 鸿蒙的「被控端」只在 2in1（PC/平板）形态下有可能实现：
 * 键鼠注入依赖 OH_Input_RequestInjection，手机形态平台根本没开这个接口；
 * 屏幕共享也要求每次会话用户手动授权。按产品口径，手机被控一律不做
 * （见 docs/ohos/ARCHITECTURE.md 的「红线」）。
 *
 * 因此手机上「共享屏幕」页与相关设置项全部隐藏，避免用户看到一个
 * 永远写着「服务未运行」的死页面。
 */
export function isPhoneForm(): boolean {
  let t: string = '';
  let phone: boolean = false;
  try {
    t = deviceInfo.deviceType;
    // deviceType 取值：phone / tablet / 2in1 / tv / wearable / car / default
    phone = t === 'phone' || t === 'wearable';
  } catch (e) {
    // 拿不到就按「非手机」处理：宁可多显示，也不要误把 PC 版的入口藏掉。
    phone = false;
  }
  hilog.info(0x3200, 'RustDeskForm', 'deviceType=%{public}s -> phone=%{public}b', t, phone);
  return phone;
}
