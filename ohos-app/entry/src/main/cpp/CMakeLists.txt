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

# DevEco 的 OHOS_ARCH（arm64-v8a / x86_64）→ Rust target 与自建 sysroot 子目录
if(OHOS_ARCH STREQUAL "arm64-v8a")
    set(_rust_target "aarch64-unknown-linux-ohos")
    set(_sys_arch "aarch64")
elseif(OHOS_ARCH STREQUAL "x86_64")
    set(_rust_target "x86_64-unknown-linux-ohos")
    set(_sys_arch "x86_64")
else()
    message(FATAL_ERROR "不支持的 OHOS_ARCH：${OHOS_ARCH}")
endif()

# 默认用 release：debug 的 .a 有 648MB，DevEco 链接会跑到内存爆掉。
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(_rust_profile "debug")
else()
    set(_rust_profile "release")
endif()

if(NOT DEFINED RUSTDESK_LIB)
    set(RUSTDESK_LIB
        "${REPO_ROOT}/target/${_rust_target}/${_rust_profile}/liblibrustdesk.a")
endif()

if(NOT EXISTS "${RUSTDESK_LIB}")
    message(FATAL_ERROR
        "找不到 Rust 静态库：${RUSTDESK_LIB}\n"
        "请先执行：OHOS_TARGET=${_rust_target} bash scripts/ohos/build-core.sh ${_rust_profile}\n"
        "或用 -DRUSTDESK_LIB=/abs/path/liblibrustdesk.a 指定。")
endif()

add_library(rustdesk_core STATIC IMPORTED)
set_target_properties(rustdesk_core PROPERTIES IMPORTED_LOCATION "${RUSTDESK_LIB}")

# ---------------------------------------------------------------------------
# Rust 静态库的 C 依赖
# ---------------------------------------------------------------------------
# cargo build --lib 产出的 .a 只含 Rust 代码；build script 记录的
# cargo:rustc-link-lib 要到【最终链接】才生效 —— 也就是本文件的 C++ 链接。
# 缺了它们，ld.lld 会报 undefined symbol: opus_* / yuv_* / vpx_* / aom_* ...
set(CARGO_BUILD_DIR "${REPO_ROOT}/target/${_rust_target}/${_rust_profile}/build")
set(OHOS_SYSROOT_LIB "${REPO_ROOT}/ohos/sysroot/${_sys_arch}/lib")
set(OHOS_SODIUM_LIB "${REPO_ROOT}/ohos/sodium-link-${_sys_arch}")

set(_c_deps
    "${OHOS_SYSROOT_LIB}/libopus.a"      # magnum-opus（音频编解码）
    "${OHOS_SYSROOT_LIB}/libyuv.a"       # scrap（YUV 转换）
    "${OHOS_SYSROOT_LIB}/libvpx.a"       # scrap（VP8/VP9 编解码）
    "${OHOS_SYSROOT_LIB}/libaom.a"       # scrap（AV1 编解码）
    "${OHOS_SODIUM_LIB}/libsodium.a"     # hbb_common（加密握手）
)

# cargo build 输出目录按 hash 命名，用 GLOB 定位（升级依赖也不会失效）
file(GLOB _kcp_a  "${CARGO_BUILD_DIR}/kcp-sys-*/out/libkcp.a")
file(GLOB _ring_a "${CARGO_BUILD_DIR}/ring-*/out/libring_core_0_*.a")
file(GLOB _webm_a "${CARGO_BUILD_DIR}/webm-sys-*/out/libwebmadapter.a")
file(GLOB _zstd_a "${CARGO_BUILD_DIR}/zstd-sys-*/out/libzstd.a")
# ring 的 *_test.a 是自测用的，不能链进去
list(FILTER _ring_a EXCLUDE REGEX "_test\\.a$")
list(APPEND _c_deps ${_kcp_a} ${_ring_a} ${_webm_a} ${_zstd_a})

foreach(_dep ${_c_deps})
    if(NOT EXISTS "${_dep}")
        message(FATAL_ERROR "缺少 Rust 的 C 依赖：${_dep}\n请先执行 bash scripts/ohos/build-core.sh ${_rust_profile}")
    endif()
endforeach()

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
# 有循环引用（std 与 alloc/core），单趟扫描会漏符号。C 依赖同样放进组里，
# 因为 opus/yuv 等与 Rust 对象之间也是双向引用。
target_link_libraries(entry PUBLIC
    -Wl,--start-group
    ${RUSTDESK_LIB}
    ${_c_deps}
    -Wl,--end-group
    # libvpx 等部分 C 库没开 -fPIC，其 PC 相对重定位只有在符号不被
    # 抢占（preempt）时才合法；-Bsymbolic 让 .so 内符号全部本地绑定。
    -Wl,-Bsymbolic
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
