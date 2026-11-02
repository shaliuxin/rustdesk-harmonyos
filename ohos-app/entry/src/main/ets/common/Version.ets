import { RustDesk } from './RustDesk';

/**
 * 版本号：唯一来源。
 *
 * 规则（与 AppScope/app.json5 联动，改这里就要同步改那里）：
 *
 *   OHOS_APP_VERSION  鸿蒙版**自己的**版本基数，从 0.1.0 起，有改动就递增
 *                     （0.1.1 → 0.1.2 …；功能批次变大再进 0.2.0）。
 *   app.json5         versionName 写同一个数字（鸿蒙应用市场的包版本必须保持
 *                     纯数字，括号与后缀只在应用内展示），versionCode 用
 *                     主*10000 + 次*100 + 修订，即 0.1.0 → 100、0.1.1 → 101。
 *   括号里的数字       上游 RustDesk 的核心版本，取 `src/version.rs` 的 VERSION
 *                     常量（经 native.version() 读回），**不在这里手写** ——
 *                     上游一升级、重编，这里自动跟着变。
 *
 * 最终展示形态：`0.1.3 (1.5.1) for HarmonyOS`
 */
export const OHOS_APP_VERSION: string = '0.1.3';

/** 产品后缀，接在版本串末尾。 */
export const VERSION_SUFFIX: string = 'for HarmonyOS';

/**
 * 应用内展示用的完整版本串。
 *
 * 核心版本读不到时（例如 native 尚未加载）退化成 `0.1.1 for HarmonyOS`，
 * 不会显示一对空括号。
 */
export function appVersionLabel(): string {
  const core: string = RustDesk.coreVersion();
  if (core.length === 0) {
    return `${OHOS_APP_VERSION} ${VERSION_SUFFIX}`;
  }
  return `${OHOS_APP_VERSION} (${core}) ${VERSION_SUFFIX}`;
}
