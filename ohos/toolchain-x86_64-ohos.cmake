# OpenHarmony (x86_64，模拟器) 交叉编译工具链
#
# 与 toolchain-aarch64-ohos.cmake 唯一的区别是三元组与处理器架构。
# 用法：
#   cmake -G Ninja -S <src> -B <build> \
#         -DCMAKE_TOOLCHAIN_FILE=ohos/toolchain-x86_64-ohos.cmake \
#         -DCMAKE_INSTALL_PREFIX=ohos/sysroot/x86_64

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

if(NOT DEFINED OHOS_SDK)
  set(OHOS_SDK "C:/ohos-sdk/default/openharmony/native")
endif()

set(OHOS_TRIPLE "x86_64-linux-ohos")
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

set(CMAKE_FIND_ROOT_PATH "${OHOS_SYSROOT}" "${CMAKE_INSTALL_PREFIX}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_CROSSCOMPILING_EMULATOR "")
