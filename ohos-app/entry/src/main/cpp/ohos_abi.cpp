// Rust ←→ C++：Rust 调用的 12 个 ohos_*（另 7 个见文件末尾的补充实现）。
//
// 设计约定（与 ohos/include/rustdesk_ohos.h 对齐）：
//
//   1. **本文件所有函数必须线程安全**。Rust 从 tokio worker 线程调用，
//      甚至可能并发（例如剪贴板与显示器同时被读）。
//   2. **返回的字符串用 malloc 分配**，因为 Rust 侧统一用 libc free 释放
//      （见 ffi.rs 的 take_string → ohos_free_string）。绝不能返回字面量。
//   3. **不做阻塞操作**。系统 API 慢的（display manager 要跨进程）就要缓存。
//   4. **能力查询返回 0/1，动作返回 0 成功 / 负数失败**，与 Rust 侧判断一致。
//
// 这里刻意不做「假装成功」：拿不到的能力一律如实返回失败，让 Rust 侧
// 走降级分支（例如鸿蒙手机不能注入键鼠，就该老老实实拒绝被控）。

#include "rustdesk_ohos.h"
#include "bridge.h"

#include <deviceinfo.h>
#include <hilog/log.h>
#include <multimodalinput/oh_input_manager.h>
#include <window_manager/oh_display_info.h>
#include <window_manager/oh_display_manager.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "RustDesk"

namespace {

// --- 字符串分配 ------------------------------------------------------------
// Rust 侧拿到后会用 ohos_free_string 释放，所以必须走 malloc。
char* DupString(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p == nullptr) return nullptr;
    std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}

// --- 设备形态 --------------------------------------------------------------
// OH_GetDeviceType 返回 "phone" / "tablet" / "2in1" / "tv" / "wearable" ...
// 缓存一次：它是进程内常量，而 Rust 会频繁问（每次会话初始化都问）。
int g_device_type = -1;
std::once_flag g_device_type_once;

int ResolveDeviceType() {
    const char* t = OH_GetDeviceType();
    if (t == nullptr) return 0;  // 拿不到就当手机，最保守
    if (std::strcmp(t, "2in1") == 0) return 2;
    if (std::strcmp(t, "tablet") == 0) return 1;
    return 0;
}

// --- 显示器缓存 ------------------------------------------------------------
// Rust 的调用顺序是「先 display_count 再逐个 display_info」
// （见 src/platform/ohos/ffi.rs 的 display_info_list）。
// 如果每次 info 都去 CreateAllDisplays，就是 O(n²) 次跨进程调用，
// 而且会重复 malloc/free。所以只在 count 时刷新，info 读缓存。
//
// 风险：两次调用之间显示器插拔会读到旧数据。可接受 —— Rust 只在
// rustdesk_ohos_displays_sync() 里用，那是显式的「重新读一遍」语义。
std::mutex g_display_mu;
std::vector<OhosDisplayInfo> g_displays;
bool g_displays_valid = false;

// 系统的 rotation 是枚举 0/1/2/3，Rust 侧要的是角度 0/90/180/270。
uint32_t RotationToDegrees(NativeDisplayManager_Rotation r) {
    switch (r) {
        case DISPLAY_MANAGER_ROTATION_90: return 90;
        case DISPLAY_MANAGER_ROTATION_180: return 180;
        case DISPLAY_MANAGER_ROTATION_270: return 270;
        default: return 0;
    }
}

void RefreshDisplaysLocked() {
    g_displays.clear();
    g_displays_valid = true;

    NativeDisplayManager_DisplaysInfo* all = nullptr;
    NativeDisplayManager_ErrorCode rc = OH_NativeDisplayManager_CreateAllDisplays(&all);
    if (rc != DISPLAY_MANAGER_OK || all == nullptr) {
        // 多屏接口失败时退回默认屏。API 12 的机器只有默认屏接口，
        // 而且就算 API 26，某些精简设备也可能不支持多屏查询。
        OhosDisplayInfo one{};
        int32_t w = 0, h = 0;
        if (OH_NativeDisplayManager_GetDefaultDisplayWidth(&w) == DISPLAY_MANAGER_OK &&
            OH_NativeDisplayManager_GetDefaultDisplayHeight(&h) == DISPLAY_MANAGER_OK) {
            uint64_t id = 0;
            OH_NativeDisplayManager_GetDefaultDisplayId(&id);
            float ratio = 1.0f;
            OH_NativeDisplayManager_GetDefaultDisplayVirtualPixelRatio(&ratio);
            NativeDisplayManager_Rotation rot = DISPLAY_MANAGER_ROTATION_0;
            OH_NativeDisplayManager_GetDefaultDisplayRotation(&rot);

            one.id = static_cast<uint32_t>(id);
            one.width = static_cast<uint32_t>(w > 0 ? w : 0);
            one.height = static_cast<uint32_t>(h > 0 ? h : 0);
            one.rotation = RotationToDegrees(rot);
            one.scale = static_cast<double>(ratio);
            std::snprintf(one.name, sizeof(one.name), "Display 0");
            g_displays.push_back(one);
        }
        return;
    }

    for (uint32_t i = 0; i < all->displaysLength; ++i) {
        const NativeDisplayManager_DisplayInfo& d = all->displaysInfo[i];
        if (!d.isAlive) continue;
        OhosDisplayInfo out{};
        out.id = d.id;
        out.width = static_cast<uint32_t>(d.width > 0 ? d.width : 0);
        out.height = static_cast<uint32_t>(d.height > 0 ? d.height : 0);
        out.rotation = RotationToDegrees(d.rotation);
        out.scale = static_cast<double>(d.densityPixels);
        // 系统 name 最长 32+1，我们的字段是 64，strncpy 后一定留 NUL。
        std::strncpy(out.name, d.name, sizeof(out.name) - 1);
        out.name[sizeof(out.name) - 1] = '\0';
        g_displays.push_back(out);
    }
    OH_NativeDisplayManager_DestroyAllDisplays(all);
}

// --- 采集 ----------------------------------------------------------------
// 被控端（M3）。帧回调由 Rust 注册，C++ 编码完 H.264/H.265 后回调回去。
ohos_frame_cb g_frame_cb = nullptr;
std::mutex g_capture_mu;
bool g_capture_running = false;

}  // namespace

namespace rustdesk_ohos {

// 形态判断要走 call_once 缓存，所以放在 extern "C" 外面 ——
// linkage specification 里不能定义 namespace。
bool Is2in1() {
    std::call_once(g_device_type_once, [] { g_device_type = ResolveDeviceType(); });
    return g_device_type == 2;
}

}  // namespace rustdesk_ohos

extern "C" {

// ===========================================================================
// 设备与账号
// ===========================================================================

int32_t ohos_device_type(void) {
    std::call_once(g_device_type_once, [] { g_device_type = ResolveDeviceType(); });
    return g_device_type;
}

// 用户名/用户 ID：OHOS 没有给普通应用读「当前登录账号名」的 NDK 接口
// （account 子系统是系统 API）。RustDesk 用它们只是为了在远端的
// 「已连接用户」里显示，拿不到就给空串，不影响任何功能。
char* ohos_get_active_user_name(void) { return DupString(""); }
char* ohos_get_active_user_id(void) { return DupString(""); }

// 锁屏状态：同上，属于系统 API。恒报「未锁定」是安全的选择吗？
// 不是 —— 但如果这里报 true，RustDesk 会拒绝发起被控连接；报 false
// 只是少了一层「锁屏时不接受连接」的保护。手机形态本来就不做被控
// （见 ohos_input_can_inject），所以这个偏差只在 2in1 上有意义。
// 后续接 @ohos.screenLock（系统 API，需 ACL）时再补。
int32_t ohos_is_locked(void) { return 0; }

int32_t ohos_lock_screen(void) { return -1; }  // 不支持，如实返回

// ===========================================================================
// 输入注入（仅 2in1）
// ===========================================================================

// 手机/平板没有鼠标指针，注入键鼠没有意义；2in1 才有。
// 这里只判断形态，不判断「用户是否授权」——OHOS 的 OH_Input_Inject*
// 需要 ohos.permission.INJECT_INPUT_EVENT（system_basic，要 ACL）。
// 真上线时应该在 Ability 里申请，并把结果回填到这里。
int32_t ohos_input_can_inject(void) {
    return rustdesk_ohos::Is2in1() ? 1 : 0;
}

int32_t ohos_input_request_authorization(void) { return -1; }

void ohos_input_block(int32_t block) {
    // RustDesk 的「屏蔽本机输入」在桌面上靠 grab 实现。OHOS 没有等价的
    // 全局输入拦截 NDK 接口，只能记下状态，实际不生效。
    OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                 "input_block(%{public}d) requested, not supported on OHOS", block);
}

// ===========================================================================
// 屏幕采集（被控端，M3）
// ===========================================================================

// ArkTS 侧用 AVScreenCapture 采集，编码后把 packet 交给
// rustdesk_ohos_capture_push_frame（未编码 RGBA 路径）。
// 这个能力开关留给 M3 接上 AVScreenCapture 后再返回 1。
int32_t ohos_capture_can_start(void) { return 0; }

int32_t ohos_capture_start(uint32_t display_id) {
    (void)display_id;
    return -1;
}

int32_t ohos_capture_stop(void) {
    std::lock_guard<std::mutex> lk(g_capture_mu);
    g_capture_running = false;
    return 0;
}

void ohos_capture_set_frame_callback(ohos_frame_cb cb) {
    std::lock_guard<std::mutex> lk(g_capture_mu);
    g_frame_cb = cb;
}

// ===========================================================================
// 剪贴板
// ===========================================================================
//
// 有意留空，原因值得记下来：
//
//   OH_Pasteboard 的 NDK 接口（API 13+）走 UDMF 而不是纯文本：
//   读要 OH_Pasteboard_GetData → OH_UdmfData → 遍历 record 找 text/plain，
//   写要 OH_UdmfData_Create → OH_UdmfRecord → OH_Pasteboard_SetData。
//   而且 **读需要 ohos.permission.READ_PASTEBOARD**，这是 system_basic 级
//   受限权限，普通应用必须在签名 profile 里做 ACL 申请才能装。
//
//   在把这些搞清楚之前，返回「没有剪贴板」比返回半截数据安全 ——
//   RustDesk 的剪贴板是双向同步的，读错会让远端剪贴板被覆盖。
//
//   M2 再做，届时两条路可选：
//     a) NDK + ACL（一次到位，但要处理受限权限的签名流程）
//     b) ArkTS 侧 @ohos.pasteboard，C++ 通过 napi 回调取（权限模型相同，
//        但代码简单、能复用 UIAbility 的 context）
//   倾向 b)，因为权限申请本来就得在 Ability 里做。

char* ohos_clipboard_get_text(void) { return nullptr; }

void ohos_clipboard_set_text(const char* text) {
    (void)text;  // 不落任何东西，避免误导。
}

int32_t ohos_clipboard_update_multi(const uint8_t* data, size_t len) {
    (void)data;
    (void)len;
    return -1;
}

int32_t ohos_clipboard_get_multi(uint8_t** out, size_t* out_len) {
    if (out != nullptr) *out = nullptr;
    if (out_len != nullptr) *out_len = 0;
    return -1;
}

// ===========================================================================
// 显示器
// ===========================================================================

int32_t ohos_display_count(void) {
    std::lock_guard<std::mutex> lk(g_display_mu);
    RefreshDisplaysLocked();
    return static_cast<int32_t>(g_displays.size());
}

int32_t ohos_display_info(int32_t index, OhosDisplayInfo* out) {
    if (out == nullptr || index < 0) return -1;
    std::lock_guard<std::mutex> lk(g_display_mu);
    if (!g_displays_valid) RefreshDisplaysLocked();
    if (static_cast<size_t>(index) >= g_displays.size()) return -1;
    *out = g_displays[static_cast<size_t>(index)];
    return 0;
}

// ===========================================================================
// 指针位置
// ===========================================================================

// OHOS 没有「读全局指针坐标」的 NDK 接口（OH_Input_GetMouseEvent 是注入用的
// 输入事件构造器，不是状态查询）。返回 -1 让 Rust 侧走「不显示远端指针」。
int32_t ohos_cursor_pos(int32_t* out_x, int32_t* out_y) {
    if (out_x != nullptr) *out_x = 0;
    if (out_y != nullptr) *out_y = 0;
    return -1;
}

// ===========================================================================
// 内存与日志
// ===========================================================================

void ohos_free_string(char* s) { std::free(s); }

void ohos_free_bytes(uint8_t* p) { std::free(p); }

void ohos_log(int32_t level, const char* tag, const char* msg) {
    // Rust 的 level：0=debug 1=info 2=warn 3=error
    LogLevel lv = LOG_INFO;
    switch (level) {
        case 0: lv = LOG_DEBUG; break;
        case 1: lv = LOG_INFO; break;
        case 2: lv = LOG_WARN; break;
        case 3: lv = LOG_ERROR; break;
        default: lv = LOG_INFO; break;
    }
    OH_LOG_Print(LOG_APP, lv, LOG_DOMAIN, LOG_TAG, "%{public}s: %{public}s",
                 tag != nullptr ? tag : "rustdesk", msg != nullptr ? msg : "");
}

// ===========================================================================
// UI 事件（Rust → ArkTS）
// ===========================================================================

void ohos_ui_event(const char* json) {
    if (json == nullptr) return;

    // 丢掉 rgba 事件。
    //
    // Rust 的 ui_handler 在 on_rgba 里每帧发一条 {"event":"rgba",...}，那是
    // 「把帧交给 UI 去画」的模型。但这里帧是 renderer.cpp 的渲染线程自己
    // 从帧槽拉的（见 renderer.cpp 文件头），ArkTS 根本不需要这条通知。
    // 每帧一次跨线程切换 + JS 调用在 30fps 下是纯浪费，所以在最外面掐掉。
    //
    // 用子串搜索而不是前缀比较：serde_json 的 Map 默认是 BTreeMap，
    // key 会按字典序输出，"data" 会排在 "event" 前面。
    if (std::strstr(json, "\"event\":\"rgba\"") != nullptr) {
        return;
    }

    // 不在这里做任何解析：bridge 负责拷贝入队，解析交给 ArkTS。
    // Rust 的 json 一定是 NUL 结尾的合法 UTF-8（ffi.rs 用 CString 构造）。
    rustdesk_ohos::PostUiEvent(json);
}

}  // extern "C"
