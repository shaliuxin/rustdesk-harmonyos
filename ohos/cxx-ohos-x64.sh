#!/bin/sh
# OHOS x86_64 clang++ 包装（同 cc-ohos-x64.sh）
NDK="C:/ohos-sdk/default/openharmony/native"
exec "$NDK/llvm/bin/clang++.exe" --target=x86_64-linux-ohos --sysroot="$NDK/sysroot" -D__MUSL__ "$@"
