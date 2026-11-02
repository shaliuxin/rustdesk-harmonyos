#!/bin/bash
# 构建 x86_64（模拟器）目标的 C 依赖库，安装到 ohos/sysroot/x86_64。
#
# 与 aarch64 版的差异：
#   * aom/libyuv/opus 用 toolchain-x86_64-ohos.cmake 交叉编译
#   * libvpx 用 generic-gnu 目标（纯 C、无手写汇编，nasm 可用但没必要）
#   * libsodium 的 host 三元组用 x86_64-linux-musl
#
# 依赖：ohos/tools/{make.exe,nasm.exe}（见仓库内说明）
# 用法：bash ohos/build-libs-x64.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
NDK="C:/ohos-sdk/default/openharmony/native"
PREFIX="$ROOT/ohos/sysroot/x86_64"
CMAKE="$NDK/build-tools/cmake/bin/cmake.exe"
NINJA="$NDK/build-tools/cmake/bin/ninja.exe"
TOOLS="$ROOT/ohos/tools"

for t in "$TOOLS/make.exe" "$TOOLS/nasm.exe"; do
  [[ -f "$t" ]] || { echo "缺少 $t（见 ohos/tools/README 说明）" >&2; exit 1; }
done

# msys2 的 make 会把 /usr/bin/sh 解析到它自带运行时的根目录（perl-root）。
# 我们在那里装了 dash 伪装的 sh.exe（见 ohos/tools 说明）。
# 注意：msys2 make 对 POSIX 形式（/c/...）的 SHELL/程序路径 exec 会 ENOENT，
# 必须传 Windows 混合形式（C:/...）。
# TOOLS_WIN 必须在改 PATH 之前算好：PATH 里带上 perl-root/usr/bin 后，
# Git Bash 的 cygpath 会加载 perl-root 的 msys-2.0.dll，路径解析直接错乱。
TOOLS_WIN=$(cygpath -m "$TOOLS")
ROOT_WIN=$(cygpath -m "$ROOT")
SH_EXE="$TOOLS_WIN/perl-root/usr/bin/sh.exe"
[[ -f "$SH_EXE" ]] || SH_EXE=$(command -v sh)

# 核心命令显式走 /usr/bin：PATH 里既有 perl-root 版本（会破坏复制/建目录），
# 又有 WorkBuddy 的 safe-bin 垫片，裸名解析不可靠。
REAL_CP=/usr/bin/cp
REAL_FIND=/usr/bin/find
REAL_RM=/usr/bin/rm
REAL_MKDIR=/usr/bin/mkdir
# libsodium 的 make 必须用“默认” make + sh：perl-root 的 sh 会让 Windows 原生 clang
# 在编译 .S（需预处理）时报 “unable to make temporary file”，默认工具链无此问题。
REAL_MAKE=$(command -v make)
REAL_SH=$(command -v sh)

# nasm 进 PATH（aom x86_64 需要汇编器）；perl 进 PATH（aom rtcd 代码生成需要）。
# 注意：perl-root 必须追加在末尾，否则它的 cp/find/rm/mkdir 会破坏复制与建目录。
export PATH="$TOOLS:$PATH:$TOOLS/perl-root/usr/bin"

# 给 clang（Windows 原生程序）一个可用的临时目录：否则编译 .S（需预处理）时报
# "unable to make temporary file"。必须用正斜杠路径，与手工编译 .S 时的 TMPDIR 一致。
export TMPDIR="C:/Users/$USERNAME/AppData/Local/Temp"

"$REAL_MKDIR" -p "$PREFIX/lib" "$PREFIX/include"

# ONLY=yuv|opus|aom|vpx|sodium 只跑指定一步（调试用），默认 all
ONLY="${ONLY:-all}"
want() { [[ "$ONLY" == "all" || "$ONLY" == "$1" ]]; }

if want yuv; then
echo "==> [1/5] libyuv (cmake)"
"$CMAKE" -G Ninja -S ohos/third_party/libyuv -B ohos/build-x64/libyuv \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/ohos/toolchain-x86_64-ohos.cmake" \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" > /dev/null
"$CMAKE" --build ohos/build-x64/libyuv --target install > /dev/null
echo "    OK: $PREFIX/lib/libyuv.a"
fi

if want opus; then
echo "==> [2/5] opus (cmake)"
"$CMAKE" -G Ninja -S ohos/third_party/opus -B ohos/build-x64/opus \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/ohos/toolchain-x86_64-ohos.cmake" \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" > /dev/null
"$CMAKE" --build ohos/build-x64/opus --target install > /dev/null
echo "    OK: $PREFIX/lib/libopus.a"
fi

if want aom; then
echo "==> [3/5] libaom (cmake，需 nasm)"
"$CMAKE" -G Ninja -S ohos/third_party/aom -B ohos/build-x64/aom \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/ohos/toolchain-x86_64-ohos.cmake" \
  -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 -DENABLE_DOCS=0 -DENABLE_TOOLS=0 > /dev/null
"$CMAKE" --build ohos/build-x64/aom --target install > /dev/null
echo "    OK: $PREFIX/lib/libaom.a"
fi

if want vpx; then
echo "==> [4/5] libvpx (干净副本里 in-source configure + make)"
# 两条路都走不通，所以这样做：
#  * 不能在源码树里编：那里留着 aarch64 时代的 .o / *_rtcd.h，VPATH 会复用，
#    链接报 "is incompatible with elf_x86_64" 或 undefined symbol: *_neon。
#  * 不能用 out-of-tree：这套 msys2/dash 组合下 configure 生成的 config.mk 缺
#    TOOLCHAIN / ALL_TARGETS，也不产出 $(target)-$(toolchain).mk，make 直接空转。
#  * 解法：把源码拷一份干净的（排除 .o/.a/*_rtcd.h/config.mk）到 ohos/build-x64/，
#    在副本里 configure + make，产物再拷到 sysroot。
VPXBUILD="$ROOT/ohos/build-x64/libvpx-src"
"$REAL_RM" -rf "$VPXBUILD"; "$REAL_MKDIR" -p "$VPXBUILD"
# 逐项拷贝，跳过隐藏项（.git 在源树里权限异常；.docs 之类的空文件正常拷为文件）
for e in ohos/third_party/libvpx/*; do
    b=$(basename "$e")
    case $b in .*) continue;; esac
    "$REAL_CP" -r "$e" "$VPXBUILD/"
done
# 删掉旧构建产物（.o / *.a / *_rtcd.h / config.mk）
"$REAL_RM" -rf "$VPXBUILD/.git"
"$REAL_FIND" "$VPXBUILD" -name "*.o" -delete
"$REAL_FIND" "$VPXBUILD" -name "*.a" -delete
"$REAL_FIND" "$VPXBUILD" -name "*_rtcd.h" -delete
"$REAL_RM" -f "$VPXBUILD"/Makefile "$VPXBUILD"/config.mk "$VPXBUILD"/vp_config.h
( cd "$VPXBUILD"
  env -u CODEBUDDY_SESSION_ID -u CLAUDE_SESSION_ID \
    CC="$ROOT_WIN/ohos/cc-ohos-x64.sh" CXX="$ROOT_WIN/ohos/cxx-ohos-x64.sh" \
    AR="$NDK/llvm/bin/llvm-ar.exe" LD="$NDK/llvm/bin/ld.lld.exe" \
    STRIP="$NDK/llvm/bin/llvm-strip.exe" \
    ./configure --target=generic-gnu --prefix="$PREFIX" \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests \
      --enable-pic --disable-install-docs
  env -u CODEBUDDY_SESSION_ID -u CLAUDE_SESSION_ID \
    "$TOOLS_WIN/make.exe" -j8 SHELL="$SH_EXE"
  "$REAL_CP" -f libvpx.a "$PREFIX/lib/libvpx.a" )
echo "    OK: $PREFIX/lib/libvpx.a"
fi

if want sodium; then
echo "==> [5/5] libsodium (干净副本里 in-source 构建，必须开汇编)"
# 三个坑（均在此环境实测）：
#  1. out-of-tree configure 在 aux 文件（ltmain.sh/install-sh/...）上直接报错；
#  2. --disable-asm 会缺 stream_salsa20_xmm6 / crypto_scalarmult_curve25519_sandy2x_ladder
#     等符号 —— librustdesk.a 里的运行时分发会引用它们，必须启用汇编；
#  3. libtool 的 CPPAS 规则在本环境写不了临时文件，7 个 .S 全部手工用 clang 编，
#     再写带 libtool 头的 .lo 桩（pic_object 指 .libs/*.o，non_pic_object 指同目录 .o）。
SODIUMBUILD="$ROOT/ohos/build-x64/libsodium-src"
"$REAL_RM" -rf "$SODIUMBUILD"; "$REAL_MKDIR" -p "$SODIUMBUILD"
# 逐项拷贝，跳过隐藏项（.git 权限异常；.libs 是旧构建产物，下面会清）
for e in ohos/third_party/libsodium/*; do
    b=$(basename "$e")
    case $b in .*) continue;; esac
    "$REAL_CP" -r "$e" "$SODIUMBUILD/"
done
"$REAL_RM" -rf "$SODIUMBUILD/.git"
"$REAL_FIND" "$SODIUMBUILD" -name "*.o" -delete
"$REAL_FIND" "$SODIUMBUILD" -name "*.lo" -delete
"$REAL_FIND" "$SODIUMBUILD" -name "*.a" -delete
"$REAL_FIND" "$SODIUMBUILD" -type d -name ".libs" -exec "$REAL_RM" -rf {} + 2>/dev/null || true
"$REAL_RM" -f "$SODIUMBUILD"/Makefile "$SODIUMBUILD"/config.status "$SODIUMBUILD"/config.log
( cd "$SODIUMBUILD"
  env -u CODEBUDDY_SESSION_ID -u CLAUDE_SESSION_ID sh ./configure \
    --host=x86_64-linux-musl --prefix="$PREFIX" --disable-shared --enable-static --with-pic \
    CC="$ROOT_WIN/ohos/cc-ohos-x64.sh" CXX="$ROOT_WIN/ohos/cxx-ohos-x64.sh" \
    AR="$NDK/llvm/bin/llvm-ar.exe" RANLIB="$NDK/llvm/bin/llvm-ranlib.exe" \
    LD="$NDK/llvm/bin/ld.lld.exe" STRIP="$NDK/llvm/bin/llvm-strip.exe" \
    CFLAGS="-O2 -fPIC"

  # 手工编译汇编（-DHAVE_AMD64_ASM 不能少，否则 .S 全是 #ifdef 空文件）
  cd src/libsodium
  for s in $("$REAL_FIND" . -name "*.S"); do
    d=$(dirname "$s"); b=$(basename "$s" .S)
    "$REAL_MKDIR" -p "$d/.libs"
    TMPDIR="C:/Users/$USERNAME/AppData/Local/Temp" \
      "$ROOT_WIN/ohos/cc-ohos-x64.sh" -I. -I./include/sodium \
      -DHAVE_AMD64_ASM=1 -DHAVE_AVX_ASM=1 -DASM_HIDE_SYMBOL=.hidden \
      -O2 -fPIC -c "$s" -o "$d/.libs/libsodium_la-$b.o"
    "$REAL_CP" -f "$d/.libs/libsodium_la-$b.o" "$d/libsodium_la-$b.o"
    printf "# libsodium_la-%s.lo - a libtool object file\n# Generated by libtool (GNU libtool) 2.4.6 for libsodium\n#\n# Name of the PIC object.\npic_object='.libs/libsodium_la-%s.o'\n\n# Name of the non-PIC object\nnon_pic_object='libsodium_la-%s.o'\n" \
      "$b" "$b" "$b" > "$d/libsodium_la-$b.lo"
  done

  # 后续 make/rm/cp 必须留在 src/libsodium 内：libsodium.la 与 .libs/libsodium.a
  # 都产在这里，构建根目录的 Makefile 没有 libsodium.la 这个 target。
  env -u CODEBUDDY_SESSION_ID -u CLAUDE_SESSION_ID \
    "$REAL_MAKE" -j8
  # 归档时 .la 存在会导致 make 认为已完成，先删掉强制重建
  "$REAL_RM" -f libsodium.la .libs/libsodium.a
  env -u CODEBUDDY_SESSION_ID -u CLAUDE_SESSION_ID \
    "$REAL_MAKE" libsodium.la
  "$REAL_CP" -f .libs/libsodium.a "$PREFIX/lib/libsodium.a" )
echo "    OK: $PREFIX/lib/libsodium.a"
fi
