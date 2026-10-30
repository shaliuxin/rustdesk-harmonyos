# OpenHarmony (aarch64) 交叉编译工具链
#
# 用法：
#   cmake -G Ninja -S <src> -B <build> \
#         -DCMAKE_TOOLCHAIN_FILE=ohos/toolchain-aarch64-ohos.cmake \
#         -DCMAKE_INSTALL_PREFIX=ohos/sysroot/aarch64
#
# 注意：
#   * 不使用 CMAKE_SYSROOT，而是统一走 --target/--sysroot 编译选项。二者同时设置会被
#     clang 拼接两次 sysroot，重复路径在部分 -I 组合下会告警甚至失败。
#   * OHOS 运行时是 musl + libc++，C++ 必须静态链接 libc++（系统不提供 .so）。

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT DEFINED OHOS_SDK)
  # C:/ohos-sdk 是指向 DevEco Studio SDK 的目录联接（避免路径空格被 clang 拆参数）
  set(OHOS_SDK "C:/ohos-sdk/default/openharmony/native")
endif()

set(OHOS_TRIPLE "aarch64-linux-ohos")
set(OHOS_SYSROOT "${OHOS_SDK}/sysroot")
set(OHOS_TOOLCHAIN "${OHOS_SDK}/llvm/bin")

set(CMAKE_C_COMPILER   "${OHOS_TOOLCHAIN}/clang.exe")
set(CMAKE_CXX_COMPILER "${OHOS_TOOLCHAIN}/clang++.exe")
set(CMAKE_ASM_COMPILER "${OHOS_TOOLCHAIN}/clang.exe")
set(CMAKE_AR           "${OHOS_TOOLCHAIN}/llvm-ar.exe")
set(CMAKE_RANLIB       "${OHOS_TOOLCHAIN}/llvm-ranlib.exe")
set(CMAKE_STRIP        "${OHOS_TOOLCHAIN}/llvm-strip.exe")

set(OHOS_COMMON_FLAGS "--target=${OHOS_TRIPLE} --sysroot=${OHOS_SYSROOT} -D__MUSL__ -O2 -fPIC")

set(CMAKE_C_FLAGS_INIT   "${OHOS_COMMON_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${OHOS_COMMON_FLAGS} -std=c++17")
set(CMAKE_ASM_FLAGS_INIT "--target=${OHOS_TRIPLE} --sysroot=${OHOS_SYSROOT} -D__MUSL__")

set(CMAKE_EXE_LINKER_FLAGS_INIT    "--target=${OHOS_TRIPLE} --sysroot=${OHOS_SYSROOT} -fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "--target=${OHOS_TRIPLE} --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -lc++_static -lc++abi")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "--target=${OHOS_TRIPLE} --sysroot=${OHOS_SYSROOT} -fuse-ld=lld")

# 交叉编译时：程序用宿主机工具，头文件/库只从 sysroot 与 install 前缀找
set(CMAKE_FIND_ROOT_PATH "${OHOS_SYSROOT}" "${CMAKE_INSTALL_PREFIX}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# 避免 CMake 在宿主机上探测编译器能力时误判
set(CMAKE_CROSSCOMPILING_EMULATOR "")
