// C++ 胶水层内部接口（不对外，不参与 C ABI 契约）。
//
// 这里只放三个编译单元之间互相要用的东西：
//   napi_bridge.cpp  →  renderer.cpp    （Surface 生命周期）
//   ohos_abi.cpp     →  napi_bridge.cpp （ui_event 派发）
//   napi_bridge.cpp  →  ohos_abi.cpp    （输入/采集能力查询）

#ifndef RUSTDESK_OHOS_BRIDGE_H
#define RUSTDESK_OHOS_BRIDGE_H

#include <cstdint>
#include <cstddef>

namespace rustdesk_ohos {

// --- ui_event 派发（napi_bridge.cpp 实现）-----------------------------------
//
// Rust 从任意 tokio worker 线程调用。实现要求：
//   1. 立刻拷贝字符串，不持有调用方的指针；
//   2. 入队后立即返回，绝不阻塞 Rust 线程；
//   3. 由 napi threadsafe function 切到 ArkTS 主线程再交给 JS。
// 返回 false 表示 bridge 还没初始化（早期日志阶段），消息被丢弃。
bool PostUiEvent(const char* json);

// --- 渲染（renderer.cpp 实现）-----------------------------------------------
//
// XComponent 的 Surface 就绪 / 销毁时由 napi_bridge 调用。
// surface 是 OHNativeWindow*，用 void* 传递避免在本头文件里拖进 native_window 依赖。
void OnSurfaceCreated(void* nativeWindow, int32_t width, int32_t height);
void OnSurfaceChanged(int32_t width, int32_t height);
void OnSurfaceDestroyed();

// ArkTS 显式控制渲染循环（切后台时停，回到前台时开）。
void SetRenderActive(bool active);

// --- 采集能力（ohos_abi.cpp 实现）-------------------------------------------
bool Is2in1();

}  // namespace rustdesk_ohos

#endif  // RUSTDESK_OHOS_BRIDGE_H
