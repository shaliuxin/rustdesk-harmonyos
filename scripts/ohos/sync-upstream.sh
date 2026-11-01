#!/usr/bin/env bash
# 同步上游：**只跟发行 tag**，不跟 master。
#
# 为什么只跟 tag：master 上是开发中的代码（翻译、CI 调整、未发布的重构），
# 跟着它走会引入与发版不一致的行为，也没法向用户说明"这到底是哪个版本"。
# 应用内版本串括号里的数字（`0.1.0 (1.5.1) for HarmonyOS`）就是这里选中的 tag ——
# 它来自 Rust 侧 `src/version.rs` 的 VERSION，合并后重编即自动更新，不用手改。
#
# 用法：
#   bash scripts/ohos/sync-upstream.sh              # 自动选最新的发行 tag
#   bash scripts/ohos/sync-upstream.sh 1.6.0        # 指定 tag
#   bash scripts/ohos/sync-upstream.sh 1.6.0 debug  # 指定 tag + 编译 profile
#
# 流程：定位 tag → merge → 重施加生成式补丁 → 编译验证 → 补丁面体检 → 提交
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TAG="${1:-}"
PROFILE="${2:-release}"

echo "==> 当前分支：$(git branch --show-current)"
[[ "$(git branch --show-current)" == "ohos/main" ]] || { echo "请先切到 ohos/main"; exit 1; }

# --- 1. 定位目标 tag -------------------------------------------------------
if [[ -z "$TAG" ]]; then
  echo "==> 查询上游最新的发行 tag"
  # 只认 x.y.z 形式的发行 tag；rc / beta / nightly 之类预发布不在候选里。
  # annotated tag 的 "^{}" 行会被这条正则自然过滤掉。
  TAG="$(git ls-remote --tags origin 'refs/tags/*' \
        | awk -F'/' '{print $NF}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V | tail -1)"
  [[ -n "$TAG" ]] || { echo "没找到任何发行 tag，检查网络或 origin 配置"; exit 1; }
fi
echo "==> 目标 tag：$TAG"

echo "==> 抓取该 tag"
git fetch origin "refs/tags/${TAG}:refs/tags/${TAG}" 2>/dev/null || git fetch --tags origin

if git merge-base --is-ancestor "$TAG" HEAD; then
  echo "==> $TAG 已经在当前分支里，无需同步。"
  exit 0
fi

echo "==> 上游新增 $(git rev-list --count "HEAD..${TAG}") 个提交："
git log --oneline "HEAD..${TAG}" | head -20

# --- 2. 合并 ---------------------------------------------------------------
echo "==> 合并 $TAG"
if ! git merge --no-commit --no-ff "$TAG"; then
  echo
  echo "!! 出现冲突。按 docs/ohos/ARCHITECTURE.md §7 的三条原则处理："
  echo "   1) Tier-1 新增文件冲突 → 上游在同名路径也加了文件，重命名我们的模块后保留两者"
  echo "   2) Tier-3 少数几处冲突 → 按 docs/ohos/PATCH_INVENTORY.md 的意图重打"
  echo "   3) 上游改了依赖函数签名 → 只改 src/platform/ohos/ 或 src/ohos/，不动上游"
  echo
  echo "   处理完执行 git merge --continue，再重跑本脚本的后续步骤。"
  exit 1
fi

# --- 3. 重新施加生成式补丁 -------------------------------------------------
echo "==> 重新施加生成式补丁（apply-mobile-cfg.py，幂等）"
python scripts/ohos/apply-mobile-cfg.py

# --- 4. 编译验证 -----------------------------------------------------------
echo "==> 编译验证（aarch64，profile=${PROFILE}）"
OHOS_TARGET=aarch64-unknown-linux-ohos bash scripts/ohos/build-core.sh "$PROFILE"

# --- 5. 补丁面体检（只报告，不拦截） ---------------------------------------
echo "==> 相对 $TAG 的补丁面（应只有 PATCH_INVENTORY 列出的 Tier-3 几处）"
git diff --cached --stat "$TAG" -- src libs Cargo.toml .cargo | tail -15 || true

echo "==> 上游本次是否动了关键依赖（动了就要重新 vendor，见 PATCH_INVENTORY §一）"
git diff "$(git merge-base HEAD "$TAG")" "$TAG" -- Cargo.toml \
  | grep -E '^[+-].*(nix|socket2|rdev|tokio-native-tls|scrap|hbb_common)' || echo "   （没有）"

# --- 6. 提交 ---------------------------------------------------------------
CORE_VERSION="$(grep -oE 'VERSION: &str = "[^"]+"' src/version.rs | head -1 \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
git add -A
git commit -m "chore(ohos): merge upstream ${TAG} (core ${CORE_VERSION})"
echo
echo "完成：已并入 $TAG，核心版本 ${CORE_VERSION:-未知}"
echo "别忘了："
echo "  1) app.json5 的 versionCode/versionName 与 common/Version.ets 的 OHOS_APP_VERSION 同步递增"
echo "  2) 重编 HAP 并做冒烟（应用内版本串的括号会自动变成 ${CORE_VERSION:-新核心版}）"
