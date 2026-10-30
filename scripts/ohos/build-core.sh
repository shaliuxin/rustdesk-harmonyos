#!/usr/bin/env bash
# 构建 HarmonyOS 目标的核心静态库。
# 用法：bash scripts/ohos/build-core.sh [debug|release]
set -euo pipefail

MODE="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TARGET="${OHOS_TARGET:-aarch64-unknown-linux-ohos}"

echo "==> [1/3] 施加生成式 cfg 补丁（Tier-2，不进入 git）"
python scripts/ohos/apply-mobile-cfg.py

echo "==> [2/3] 检查 Rust 目标是否安装"
if ! rustup target list --installed | grep -q "^${TARGET}$"; then
  echo "未安装目标 ${TARGET}，请先执行：rustup target add ${TARGET}"
  exit 1
fi

echo "==> [3/3] 编译 ${TARGET} (${MODE})"
if [[ "$MODE" == "debug" ]]; then
  cargo build --target "$TARGET" --lib
else
  cargo build --target "$TARGET" --lib --release
fi

ART="target/${TARGET}/${MODE}/librustdesk_core.a"
if [[ -f "$ART" ]]; then
  ls -lh "$ART"
  echo "OK: $ART"
else
  # 上游 crate 名可能变化，回退查找
  echo "预期产物不存在，列出候选："
  ls -lh "target/${TARGET}/${MODE}/"*.a 2>/dev/null || true
fi
