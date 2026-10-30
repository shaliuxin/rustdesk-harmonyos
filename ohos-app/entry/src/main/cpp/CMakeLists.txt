# RustDesk HarmonyOS —— C++ 胶水层构建脚本
#
# 这个工程只做三件事：
#   1. 把 Rust 静态库（librustdesk.a）链进来
#   2. 实现 Rust 需要的 19 个 ohos_*（见 ohos/include/rustdesk_ohos.h）
#   3. 在 XComponent 的 Surface 上直接写帧（不经过 ArkTS，避免 8MB 拷贝）
#
# Rust 静态库由 scripts/ohos/build-app.sh 先构建，路径可通过
# -DRUSTDESK_LIB=... 覆盖（例如改成 release 目录）。

cmake_minimum_required(VERSION 3.5.0)
project(rustdesk_ohos)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# Rust 静态库
# ---------------------------------------------------------------------------
# 仓库根目录：ohos-app/entry/src/main/cpp → 上 5 层
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)

# 默认用 release：debug 的 .a 有 648MB，DevEco 链接会跑到内存爆掉。
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(_rust_profile "debug")
else()
    set(_rust_profile "release")
endif()

if(NOT DEFINED RUSTDESK_LIB)
    set(RUSTDESK_LIB
        "${REPO_ROOT}/target/aarch64-unknown-linux-ohos/${_rust_profile}/liblibrustdesk.a")
endif()

if(NOT EXISTS "${RUSTDESK_LIB}")
    message(FATAL_ERROR
        "找不到 Rust 静态库：${RUSTDESK_LIB}\n"
        "请先执行：bash scripts/ohos/build-app.sh ${_rust_profile}\n"
        "或用 -DRUSTDESK_LIB=/abs/path/liblibrustdesk.a 指定。")
endif()

add_library(rustdesk_core STATIC IMPORTED)
set_target_properties(rustdesk_core PROPERTIES IMPORTED_LOCATION "${RUSTDESK_LIB}")

# ---------------------------------------------------------------------------
# 源文件
# ---------------------------------------------------------------------------
add_library(entry SHARED
    napi_bridge.cpp     # napi 导出 + threadsafe function 派发
    ohos_abi.cpp        # 19 个 ohos_*（Rust → C++）
    renderer.cpp        # XComponent Surface 渲染循环
)

target_include_directories(entry PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    # C ABI 契约头文件放在仓库的 ohos/include 下，与 Rust 侧共享同一份
    ${REPO_ROOT}/ohos/include
)

# ---------------------------------------------------------------------------
# 链接
# ---------------------------------------------------------------------------
# Rust 静态库必须用 --start-group 包住：rustc 产出的 .a 里各 CGU 之间
# 有循环引用（std 与 alloc/core），单趟扫描会漏符号。
target_link_libraries(entry PUBLIC
    -Wl,--start-group
    ${RUSTDESK_LIB}
    -Wl,--end-group
)

target_link_libraries(entry PUBLIC
    libace_napi.z.so            # napi
    libace_ndk.z.so             # OH_NativeXComponent
    libhilog_ndk.z.so           # OH_LOG_*
    libnative_window.so         # OH_NativeWindow_*（帧写入）
    libnative_display_manager.so # OH_NativeDisplayManager_*
    libdeviceinfo_ndk.z.so      # OH_GetDeviceType
    libohinput.so               # OH_Input_*(2in1 键鼠注入)
    libc++_shared.so
    libdl.so
    libm.so
)

# 帧是 RGBA8888 直写 Surface，没有中间层，所以不需要 libnative_image / pixelmap。
