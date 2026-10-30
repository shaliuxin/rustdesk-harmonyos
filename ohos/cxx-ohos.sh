#!/bin/sh
# OHOS clang++ 包装（libvpx configure 用）
NDK="C:/ohos-sdk/default/openharmony/native"
exec "$NDK/llvm/bin/clang++.exe" --target=aarch64-linux-ohos --sysroot="$NDK/sysroot" -D__MUSL__ "$@"
