#!/usr/bin/env bash
# 同步上游：merge → 重新施加生成式补丁 → 编译验证。
# 用法：bash scripts/ohos/sync-upstream.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "==> 当前分支：$(git branch --show-current)"
[[ "$(git branch --show-current)" == "ohos/main" ]] || { echo "请先切到 ohos/main"; exit 1; }

echo "==> 抓取上游"
git fetch origin

BEFORE=$(git rev-parse HEAD)
echo "==> 合并 origin/master（预期无冲突）"
if ! git merge --no-commit --no-ff origin/master; then
  echo
  echo "!! 出现冲突。按 docs/ohos/ARCHITECTURE.md §7 处理："
  echo "   1) Tier-1 文件冲突 → 重命名我们的模块目录"
  echo "   2) Tier-3 两处冲突 → 按 docs/ohos/PATCH_INVENTORY.md 意图重打"
  echo "   3) 上游函数签名变化 → 只改 src/platform/ohos/ 或 src/ohos/"
  exit 1
fi

echo "==> 校验补丁面（应只有 PATCH_INVENTORY 的 2 项）"
git diff --cached --stat origin/master -- src libs Cargo.toml .cargo || true

echo "==> 重新施加生成式补丁"
python scripts/ohos/apply-mobile-cfg.py

echo "==> 编译验证"
bash scripts/ohos/build-core.sh "${1:-release}"

echo "==> 提交合并"
git add -A
git commit -m "chore(ohos): merge upstream $(git rev-parse --short origin/master)" || echo "无改动可提交"
echo "完成：$BEFORE -> $(git rev-parse --short HEAD)"
