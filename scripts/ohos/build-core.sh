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
# 目标架构 → 自建 sysroot 子目录（aarch64 / x86_64）
case "$TARGET" in
  aarch64-unknown-linux-ohos) SYS_ARCH="aarch64" ;;
  x86_64-unknown-linux-ohos)  SYS_ARCH="x86_64"  ;;
  *) echo "未知的 OHOS 目标：$TARGET"; exit 1 ;;
esac

# --- C 交叉编译工具链（build script 型依赖，如 ring/substring 需要）------------
# cc crate 按目标三元组查 `CC_<target>` 环境变量；不设则回落到宿主 cc，直接失败。
NDK="${OHOS_NDK:-C:/ohos-sdk/default/openharmony/native}"
case "$TARGET" in
  aarch64-unknown-linux-ohos) OHOS_TRIPLE="aarch64-linux-ohos" ;;
  x86_64-unknown-linux-ohos)  OHOS_TRIPLE="x86_64-linux-ohos"  ;;
esac
_TU="$(echo "$TARGET" | tr 'a-z-' 'A-Z_')"
export CC_${_TU}="$NDK/llvm/bin/clang.exe"
export CXX_${_TU}="$NDK/llvm/bin/clang++.exe"
export AR_${_TU}="$NDK/llvm/bin/llvm-ar.exe"
export CFLAGS_${_TU}="--target=${OHOS_TRIPLE} --sysroot=$NDK/sysroot -D__MUSL__"
export CXXFLAGS_${_TU}="--target=${OHOS_TRIPLE} --sysroot=$NDK/sysroot -D__MUSL__"
export RANLIB_${_TU}="$NDK/llvm/bin/llvm-ranlib.exe"

# sodium-link 目录按目标架构分开，避免两种架构互相覆盖
SODIUM_DIR="$ROOT/ohos/sodium-link-${SYS_ARCH}"
mkdir -p "$SODIUM_DIR"

if [[ ! -f "$ROOT/ohos/sysroot/${SYS_ARCH}/lib/libsodium.a" ]]; then
  echo "缺少 ohos/sysroot/${SYS_ARCH}/lib/libsodium.a，请先执行对应构建脚本："
  echo "  aarch64: sh ohos/build-libsodium.sh"
  echo "  x86_64:  bash ohos/build-libs-x64.sh"
  exit 1
fi
cp -f "$ROOT/ohos/sysroot/${SYS_ARCH}/lib/libsodium.a" "$SODIUM_DIR/libsodium.a"
cp -f "$ROOT/ohos/sysroot/${SYS_ARCH}/lib/libsodium.a" "$SODIUM_DIR/liblibsodium.a"

# 宿主侧用 libsodium-sys 自带的 msvc 预编译库（与本 crate 版本绑定）
HOST_SODIUM=$(ls "$HOME"/.cargo/registry/src/*/libsodium-sys-0.2.7/msvc/x64/Debug/v142/libsodium.lib 2>/dev/null | head -1)
if [[ -z "$HOST_SODIUM" ]]; then
  echo "找不到宿主用 libsodium.lib（libsodium-sys-0.2.7/msvc/x64/Debug/v142/）"
  exit 1
fi
cp -f "$HOST_SODIUM" "$SODIUM_DIR/libsodium.lib"

export SODIUM_LIB_DIR="$SODIUM_DIR"
# 不要设 SODIUM_STATIC：0.2.7 已把它标为 deprecated，设了直接 panic。

# pkg-config 按目标架构解析第三方 C 库（vpx/aom/opus/yuv）。
# .cargo/config.toml [env] 里的 PKG_CONFIG_PATH 是全局的（aarch64），
# 进程环境变量优先级更高，这里按 TARGET 覆盖。
export PKG_CONFIG_PATH="$ROOT/ohos/sysroot/${SYS_ARCH}/lib/pkgconfig"

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
