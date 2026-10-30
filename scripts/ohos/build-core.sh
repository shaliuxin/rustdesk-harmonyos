#!/usr/bin/env bash
# 构建 HarmonyOS 目标的核心静态库。
# 用法：bash scripts/ohos/build-core.sh [debug|release]
set -euo pipefail

MODE="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TARGET="${OHOS_TARGET:-aarch64-unknown-linux-ohos}"

echo "==> [1/4] 施加生成式 cfg 补丁（Tier-2，不进入 git）"
python scripts/ohos/apply-mobile-cfg.py

echo "==> [2/4] 检查 Rust 目标是否安装"
if ! rustup target list --installed | grep -q "^${TARGET}$"; then
  echo "未安装目标 ${TARGET}，请先执行：rustup target add ${TARGET}"
  exit 1
fi

# --- libsodium 的宿主/目标双份链接 -------------------------------------------
# `libsodium-sys 0.2.7` 的 build.rs 有三处用**宿主**的 cfg 判断平台：
#   cfg!(windows)            → Windows 宿主永远不会走「从源码编译」分支
#   cfg!(target_env="msvc")  → 链接名取 `libsodium` 而不是 `sodium`
# 而 SODIUM_LIB_DIR 是所有构建共享的一个环境变量，无法按目标区分。
# 更麻烦的是：rustdesk 的 build script 依赖 hbb_common（宿主版），
# 宿主版 hbb_common 也要链 libsodium —— 于是同一个 SODIUM_LIB_DIR
# 必须同时满足「aarch64 目标」和「x86_64 宿主」两种架构。
#
# 做法：准备一个专用目录，放进两种命名、两种架构的库。
#   目标侧：rustc 对 `-l static=libsodium` 查找 `liblibsodium.a`
#   宿主侧：link.exe 接受 `libsodium.lib`
SODIUM_DIR="$ROOT/ohos/sodium-link"
mkdir -p "$SODIUM_DIR"

if [[ ! -f "$ROOT/ohos/sysroot/aarch64/lib/libsodium.a" ]]; then
  echo "缺少 ohos/sysroot/aarch64/lib/libsodium.a，请先执行：sh ohos/build-libsodium.sh"
  exit 1
fi
cp -f "$ROOT/ohos/sysroot/aarch64/lib/libsodium.a" "$SODIUM_DIR/libsodium.a"
cp -f "$ROOT/ohos/sysroot/aarch64/lib/libsodium.a" "$SODIUM_DIR/liblibsodium.a"

# 宿主侧用 libsodium-sys 自带的 msvc 预编译库（与本 crate 版本绑定）
HOST_SODIUM=$(ls "$HOME"/.cargo/registry/src/*/libsodium-sys-0.2.7/msvc/x64/Debug/v142/libsodium.lib 2>/dev/null | head -1)
if [[ -z "$HOST_SODIUM" ]]; then
  echo "找不到宿主用 libsodium.lib（libsodium-sys-0.2.7/msvc/x64/Debug/v142/）"
  exit 1
fi
cp -f "$HOST_SODIUM" "$SODIUM_DIR/libsodium.lib"

export SODIUM_LIB_DIR="$SODIUM_DIR"
# 不要设 SODIUM_STATIC：0.2.7 已把它标为 deprecated，设了直接 panic。

echo "==> [3/4] 编译 ${TARGET} (${MODE})"
if [[ "$MODE" == "debug" ]]; then
  cargo build --target "$TARGET" --lib
else
  cargo build --target "$TARGET" --lib --release
fi

echo "==> [4/4] 产物"
ART="target/${TARGET}/${MODE}/liblibrustdesk.a"
if [[ -f "$ART" ]]; then
  ls -lh "$ART"
  echo "OK: $ART"
else
  echo "预期产物不存在，列出候选："
  ls -lh "target/${TARGET}/${MODE}/"*.a 2>/dev/null || true
  exit 1
fi
