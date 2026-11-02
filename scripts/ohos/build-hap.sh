#!/usr/bin/env bash
# 打包 HarmonyOS HAP（ArkTS 应用层，依赖已构建好的核心静态库）。
#
# 用法：bash scripts/ohos/build-hap.sh
#
# 前置：先跑 build-core.sh（两架构核心库就位）。本脚本不编 Rust，只调 hvigorw。
# 产物：ohos-app/entry/build/default/outputs/default/entry-default-signed.hap
#
# 为什么需要本脚本：hvigorw 需要 JAVA_HOME / DEVECO_SDK_HOME 都在环境里，
# 少任何一个就报 00303217（找不到 SDK）。路径都是 DevEco 默认安装位置，
# 装在别处时用环境变量覆盖。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# PATH 里必须是 POSIX 风格（/c/...），Windows 风格条目会被 MSYS bash 忽略。
DEVECO_HOME="${DEVECO_HOME:-/c/Program Files/Huawei/DevEco Studio}"
DEV_POSIX="$DEVECO_HOME"
DEV_WIN="$(cygpath -w "$DEV_POSIX" 2>/dev/null || echo "$DEVECO_HOME")"
export JAVA_HOME="${JAVA_HOME:-$DEV_WIN/jbr}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEV_WIN/sdk}"
export PATH="$DEV_POSIX/tools/hvigor/bin:$DEV_POSIX/jbr/bin:$PATH"

cd "$ROOT/ohos-app"
hvigorw assembleHap --mode module -p product=default

ART="$ROOT/ohos-app/entry/build/default/outputs/default/entry-default-signed.hap"
if [[ -f "$ART" ]]; then
  ls -lh "$ART"
  echo "OK: $ART"
else
  echo "打包失败：未找到 signed HAP，请看上方 hvigorw 输出"
  exit 1
fi
