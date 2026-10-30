#!/bin/sh
# OHOS clang 包装：libvpx 的 configure 不接受带参数的 CC，必须用一层包装补 --target/--sysroot。
NDK="C:/ohos-sdk/default/openharmony/native"
exec "$NDK/llvm/bin/clang.exe" --target=aarch64-linux-ohos --sysroot="$NDK/sysroot" -D__MUSL__ "$@"
