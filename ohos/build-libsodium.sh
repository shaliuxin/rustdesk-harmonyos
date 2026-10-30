#!/bin/sh
# 交叉编译 libsodium（aarch64-linux-ohos）并安装到自建 sysroot。
#
# 为什么需要它：
#   `libsodium-sys 0.2.7` 的 build.rs 用 `cfg!(windows)` 判断平台 —— 那是**宿主**。
#   Windows 宿主交叉编译到 OHOS 时会去找 `msvc/x64/Debug/v142/libsodium.lib`，
#   于是报 `could not find native static library 'sodium'`。
#   正确做法：先用 NDK 编出 aarch64 的 libsodium.a，再通过
#   `SODIUM_LIB_DIR` / `SODIUM_STATIC=1` 指给 build.rs（见 scripts/ohos/build-core.sh）。
#
# 前置：
#   ohos/third_party/libsodium   源码（jedisct1/libsodium 1.0.20-RELEASE 的 git archive）
#   GNU make                    winget 的 ezwinports.make。注意 winget 的 `Links\make.exe`
#                               是个空壳 shim（退出码 0 但什么都不做），必须用 Packages 下的真实 exe
#   sh.exe                      Git for Windows 自带的即可（供递归 make 调用）
#
# 用法：sh ohos/build-libsodium.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/ohos/third_party/libsodium"
PREFIX="$ROOT/ohos/sysroot/aarch64"
NDK="C:/ohos-sdk/default/openharmony/native"

# --- 找真实的 make（跳过 winget 的 shim）-----------------------------------
if [ -z "${MAKE:-}" ]; then
    REAL_MAKE=$(ls "C:/Users/${USERNAME:-$USER}/AppData/Local/Microsoft/WinGet/Packages/"*/bin/make.exe 2>/dev/null | head -1 || true)
    [ -n "$REAL_MAKE" ] || REAL_MAKE=$(command -v make || true)
fi
[ -n "${REAL_MAKE:-}" ] || { echo "找不到 GNU make" >&2; exit 1; }

# 递归 make（`Making all in builds`）会通过 sh 再调用 `make`，
# 所以要把一个只转发到真实 make 的包装放进 PATH。
WRAP=$(mktemp -d)
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_MAKE" > "$WRAP/make"
chmod +x "$WRAP/make"
PATH="$WRAP:$PATH"
export PATH

SH_EXE=$(command -v sh)

if [ ! -f "$SRC/configure" ]; then
    echo "缺少源码：$SRC（解压 libsodium-1.0.20-RELEASE.tar.gz 到该目录）" >&2
    exit 1
fi

cd "$SRC"

# 可重入：清掉上次的配置产物
[ -f Makefile ] && make distclean >/dev/null 2>&1 || true
rm -f config.status config.log

# host 三元组用 aarch64-linux-musl 而不是 aarch64-linux-ohos：
#   libsodium 自带的 build-aux/config.sub 不认识 `ohos` 这个 OS
#   （`configure: error: OS 'ohos' not recognized`）。
#   这里只影响 configure 的特征探测与工具名前缀；真正的目标平台由
#   ohos/cc-ohos.sh 里的 `--target=aarch64-linux-ohos --sysroot=...` 决定。
#   OHOS 运行时本就是 musl + libc++，用 musl 作 host 与事实一致。
#
# LD 必须显式给：CC 是 shell 包装脚本，configure 无法从中推导出链接器，
# 否则报 `no acceptable ld found in $PATH`。
./configure \
    --host=aarch64-linux-musl \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    --with-pic \
    CC="$ROOT/ohos/cc-ohos.sh" \
    CXX="$ROOT/ohos/cxx-ohos.sh" \
    AR="$NDK/llvm/bin/llvm-ar.exe" \
    RANLIB="$NDK/llvm/bin/llvm-ranlib.exe" \
    LD="$NDK/llvm/bin/ld.lld.exe" \
    STRIP="$NDK/llvm/bin/llvm-strip.exe" \
    CFLAGS="-O2 -fPIC" \
    LDFLAGS=""

# libtool 的编译脚本要用 POSIX sh 执行
make -j8 SHELL="$SH_EXE"
make install SHELL="$SH_EXE"

rm -rf "$WRAP"

# configure 生成的 .pc 里 prefix 是 POSIX 路径（/c/Users/...），
# Windows 原生 pkgconf 解析不了，统一改成 C:/ 形式。
PC="$PREFIX/lib/pkgconfig/libsodium.pc"
if [ -f "$PC" ]; then
    WIN_PREFIX=$(cd "$PREFIX" && pwd -W 2>/dev/null || echo "$PREFIX")
    sed -i "s|^prefix=.*|prefix=$WIN_PREFIX|" "$PC"
fi

# 再放一份别名：`liblibsodium.a`。
#   libsodium-sys 0.2.7 的 build.rs 里 `cfg!(target_env = "msvc")` 判断的是**宿主**，
#   Windows 宿主交叉编译时会走到 msvc 分支，发出 `-l static=libsodium`。
#   rustc 对 static 的查找规则是 `lib<name>.a`，所以别名正好命中。
#   这样不用 fork 这个 crate，也不会影响宿主平台（那边照旧用 libsodium.a）。
cp "$PREFIX/lib/libsodium.a" "$PREFIX/lib/liblibsodium.a"

echo "---- 产物 ----"
ls -l "$PREFIX/lib/libsodium.a" "$PREFIX/lib/liblibsodium.a" "$PC"
