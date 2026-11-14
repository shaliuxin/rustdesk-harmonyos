/**
 * 版本号：唯一来源，直接跟随上游 RustDesk 发行版本。
 *
 * 规则（与 AppScope/app.json5 联动，改这里就要同步改那里）：
 *
 *   OHOS_APP_VERSION  直接等于上游 RustDesk 的发行版本号（如 1.5.3），
 *                     鸿蒙版不再另立自己的版本基数。上游一发新版
 *                     （1.5.4 / 1.6.0 …），在这里和 app.json5 同步改成同一个号。
 *   app.json5         versionName 写同一个号（应用市场包版本必须纯数字）；
 *                     versionCode 用 主*10000 + 次*100 + 修订，即
 *                     1.5.1 → 10501、1.5.3 → 10503、1.6.0 → 10600。
 *   核心版本           由 native.version() 从 Rust 核心读回（见 RustDesk.ets 的
 *                     coreVersion()），在「关于」页单独展示，不拼进应用版本串
 *                     （应用版本 == 核心版本，无需重复）。
 *
 * 最终展示形态：`1.5.3`（设置页「版本」行 / 关于页「应用版本」）。
 */
export const OHOS_APP_VERSION: string = '1.5.3';

/**
 * 应用内展示用的完整版本串。
 *
 * 现在应用版本直接等于上游版本，无需再拼核心版本括号或平台后缀。
 */
export function appVersionLabel(): string {
  return OHOS_APP_VERSION;
}
