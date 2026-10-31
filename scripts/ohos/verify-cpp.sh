#!/usr/bin/env bash
# 不依赖 DevEco 就验证 C++ 胶水层。
#
# 三层验证，逐层加严：
#   1. -fsyntax-only    语法/类型对不对（一秒）
#   2. 编译 .o          能不能出目标文件（几秒）
#   3. 链成 .so         和 Rust 静态库能不能真的链在一起（十几秒）
#
# 第 3 步是关键：它等价于 DevEco 最后那步链接。只要它过了，说明
#   - 19 个 rustdesk_ohos_* 都被 C++ 正确引用
#   - 19 个 ohos_* 都有实现（否则报 undefined reference）
#   - Rust 静态库自身的循环依赖被 --start-group 解决了
# 也就不会出现「在 DevEco 里等十分钟才看到链接错误」的情况。
#
# 为什么不检查符号表：本机 rustc 是 1.99（LLVM 23），而 OHOS NDK 的
# llvm-nm 是 15.0.4，读 release 的 .o 会报 "Unknown attribute kind"。
# 链接器反而没这个问题，所以直接用链接结果作为判据。
#
# 用法：
#   bash scripts/ohos/verify-cpp.sh
#   NDK=/path/to/openharmony/native bash scripts/ohos/verify-cpp.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

NDK="${NDK:-C:/ohos-sdk/default/openharmony/native}"
CLANG="$NDK/llvm/bin/clang++.exe"
[[ -x "$CLANG" ]] || CLANG="$NDK/llvm/bin/clang++"
if [[ ! -x "$CLANG" ]]; then
  echo "找不到 NDK 的 clang++：$CLANG"
  echo "用 NDK=/your/openharmony/native 指定"
  exit 1
fi

CPP_DIR="ohos-app/entry/src/main/cpp"
if [[ ! -d "$CPP_DIR" ]]; then
  echo "找不到 $CPP_DIR"
  exit 1
fi

CFLAGS=(--target=aarch64-linux-ohos --sysroot="$NDK/sysroot"
        -std=c++17 -fPIC -Wall -Wextra
        -I"$NDK/sysroot/usr/include" -I"ohos/include" -I"$CPP_DIR")

SRCS=(ohos_abi renderer napi_bridge)
FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== [1/3] 语法检查 =="
for f in "${SRCS[@]}"; do
  printf '  %-18s ' "$f.cpp"
  OUT=$("$CLANG" "${CFLAGS[@]}" -fsyntax-only "$CPP_DIR/$f.cpp" 2>&1)
  if [[ -z "$OUT" ]]; then
    echo "OK"
  else
    echo "FAIL"
    echo "$OUT" | head -30
    FAILED=$((FAILED + 1))
  fi
done

if [[ $FAILED -ne 0 ]]; then
  echo
  echo "FAILED（语法错误，后面的步骤跳过）"
  exit 1
fi

echo "== [2/3] 编译目标文件 =="
for f in "${SRCS[@]}"; do
  printf '  %-18s ' "$f.o"
  OUT=$("$CLANG" "${CFLAGS[@]}" -O2 -c "$CPP_DIR/$f.cpp" -o "$TMP/$f.o" 2>&1)
  if [[ -z "$OUT" && -f "$TMP/$f.o" ]]; then
    echo "OK"
  else
    echo "FAIL"
    echo "$OUT" | head -30
    FAILED=$((FAILED + 1))
  fi
done

if [[ $FAILED -ne 0 ]]; then
  echo
  echo "FAILED"
  exit 1
fi

echo "== [3/3] 链接测试（Rust .a + C 依赖 + C++ → .so）=="
LIB="target/aarch64-unknown-linux-ohos/release/liblibrustdesk.a"
[[ -f "$LIB" ]] || LIB="target/aarch64-unknown-linux-ohos/debug/liblibrustdesk.a"

if [[ ! -f "$LIB" ]]; then
  echo "  跳过：找不到 librustdesk.a"
  echo "  先执行 bash scripts/ohos/build-core.sh release"
  echo
  echo "PASS（仅语法与编译）"
  exit 0
fi

echo "  库：$LIB ($(du -h "$LIB" | cut -f1))"

# 按库路径推断目标架构（aarch64 / x86_64），C 依赖清单与 CMakeLists.txt 保持一致
case "$LIB" in
  */aarch64-unknown-linux-ohos/*) SYS_ARCH="aarch64" ;;
  */x86_64-unknown-linux-ohos/*)  SYS_ARCH="x86_64"  ;;
  *) echo "  无法从路径识别架构：$LIB"; exit 1 ;;
esac
PROFILE_DIR="$(dirname "$LIB")"
CARGO_BUILD="$PROFILE_DIR/build"

C_DEPS=(
  "ohos/sysroot/${SYS_ARCH}/lib/libopus.a"    # magnum-opus（音频编解码）
  "ohos/sysroot/${SYS_ARCH}/lib/libyuv.a"     # scrap（YUV 转换）
  "ohos/sysroot/${SYS_ARCH}/lib/libvpx.a"     # scrap（VP8/VP9 编解码）
  "ohos/sysroot/${SYS_ARCH}/lib/libaom.a"     # scrap（AV1 编解码）
  "ohos/sodium-link-${SYS_ARCH}/libsodium.a"  # hbb_common（加密握手）
)
MISSING=0
for f in "${C_DEPS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "  缺少 C 依赖：$f（请执行 bash scripts/ohos/build-core.sh release）"
    MISSING=1
  fi
done
[[ $MISSING -eq 0 ]] || exit 1

# cargo build 输出目录带 hash，用通配定位
for pat in "kcp-sys-*/out/libkcp.a" "ring-*/out/libring_core_0_*.a" \
           "webm-sys-*/out/libwebmadapter.a" "zstd-sys-*/out/libzstd.a"; do
  for f in "$CARGO_BUILD"/$pat; do
    [[ -f "$f" && "$f" != *_test.a ]] && C_DEPS+=("$f")
  done
done

echo "  C 依赖：${#C_DEPS[@]} 个"
LIBDIR="$NDK/sysroot/usr/lib/aarch64-linux-ohos"
OUT=$("$CLANG" --target=aarch64-linux-ohos --sysroot="$NDK/sysroot" \
      -shared -fPIC -O2 -o "$TMP/libentry.so" "$TMP"/*.o \
      -Wl,--start-group "$LIB" "${C_DEPS[@]}" -Wl,--end-group \
      -Wl,-Bsymbolic \
      -L"$LIBDIR" \
      -lace_napi.z -lace_ndk.z -lhilog_ndk.z -lnative_window \
      -lnative_display_manager -ldeviceinfo_ndk.z -lohinput \
      -lc++_shared -ldl -lm 2>&1)
if [[ -n "$OUT" ]]; then
  echo "  FAIL"
  echo "$OUT" | head -40
  FAILED=$((FAILED + 1))
else
  echo "  OK：$(du -h "$TMP/libentry.so" | cut -f1)"
fi

echo
if [[ $FAILED -eq 0 ]]; then
  echo "PASS"
else
  echo "FAILED ($FAILED 项)"
  exit 1
fi
