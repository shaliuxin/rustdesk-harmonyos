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
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <native_buffer/native_buffer.h>
#include <window_manager/oh_display_info.h>
#include <window_manager/oh_display_manager.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <unistd.h>
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
// 注入权限本身走「运行时由系统弹窗授权」那条路（OH_Input_RequestInjection，
// API 20+），普通应用拿不到 ohos.permission.INJECT_INPUT_EVENT（system_basic + ACL）。
int32_t ohos_input_can_inject(void) {
    return rustdesk_ohos::Is2in1() ? 1 : 0;
}

// --- 注入授权 --------------------------------------------------------------
//
// OH_Input_RequestInjection / OH_Input_QueryAuthorizedStatus 是 API 20 引入的，
// 而本应用的 minAPIVersion 是 12：直接调用会让老系统在加载 .so 时解析不到符号。
// 所以这两个函数用 dlsym 延迟绑定，拿不到就如实报告「系统不支持」。

namespace {

// 0=未授权 1=授权中 2=已授权；系统回调可能在任意线程写，故用 atomic。
std::atomic<int32_t> g_inject_auth{0};

void OnInjectAuthorized(int32_t status) {
    g_inject_auth.store(status, std::memory_order_release);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "inject authorize status -> %{public}d", status);
}

typedef int32_t (*FnRequestInjection)(void (*)(int32_t));
typedef int32_t (*FnQueryAuthorized)(int32_t*);

// 为什么不用 dlsym(RTLD_DEFAULT)：libohinput.so 虽然是本 .so 的 NEEDED 依赖，
// 但系统把它加载在**局部**符号作用域里，RTLD_DEFAULT 这条全局链上查不到它导出
// 的符号 —— 实测 dlsym(RTLD_DEFAULT, "OH_Input_RequestInjection") 恒为 null，
// 于是整个注入授权流程一直在走「系统不支持」的降级分支（日志里那句
// "unavailable (system < API 20)" 其实是假的，设备是 API 26）。
// 正确做法：对库本身取 handler 再查。库已加载，dlopen 只是引用计数 +1。
void* InputLibHandle() {
    static void* h = dlopen("libohinput.so", RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        const char* err = dlerror();
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "dlopen libohinput.so failed: %{public}s", err ? err : "?");
    }
    return h;
}

FnRequestInjection ResolveRequestInjection() {
    static FnRequestInjection fn = []() -> FnRequestInjection {
        void* h = InputLibHandle();
        return h ? reinterpret_cast<FnRequestInjection>(
                       dlsym(h, "OH_Input_RequestInjection"))
                 : nullptr;
    }();
    return fn;
}

FnQueryAuthorized ResolveQueryAuthorized() {
    static FnQueryAuthorized fn = []() -> FnQueryAuthorized {
        void* h = InputLibHandle();
        return h ? reinterpret_cast<FnQueryAuthorized>(
                       dlsym(h, "OH_Input_QueryAuthorizedStatus"))
                 : nullptr;
    }();
    return fn;
}

int64_t NowMicros() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

// 注入结果节流日志：rc 非 0 时必须立刻看见，0 也按 1/50 采样留痕，
// 用来确认「远端事件确实走到了 OH_Input」这一环。
void LogInjectResult(const char* what, int32_t rc, int32_t x, int32_t y) {
    static std::atomic<int32_t> seq{0};
    int32_t n = seq.fetch_add(1, std::memory_order_relaxed);
    if (rc != 0 || n % 50 == 0) {
        OH_LOG_Print(LOG_APP, rc != 0 ? LOG_ERROR : LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "inject %{public}s #%{public}d rc=%{public}d xy=%{public}d,%{public}d",
                     what, n, rc, x, y);
    }
}

}  // namespace

/// 触发系统授权弹窗。返回 0 表示「已在授权流程中」或「已授权」。
int32_t ohos_input_request_authorization(void) {
    if (!rustdesk_ohos::Is2in1()) {
        return -1;
    }
    FnRequestInjection fn = ResolveRequestInjection();
    if (fn == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                     "OH_Input_RequestInjection not found in libohinput.so");
        return -2;
    }
    int32_t rc = fn(OnInjectAuthorized);
    switch (rc) {
        case 0:                // INPUT_SUCCESS：等待用户在弹窗上确认
        case 3900007:          // 已授权
            if (rc == 3900007) {
                g_inject_auth.store(2);
            } else {
                g_inject_auth.store(1);
            }
            return 0;
        case 3900005:          // 正在授权中
            g_inject_auth.store(1);
            return 0;
        case 3900008:          // 授权给了别的应用
            g_inject_auth.store(0);
            return -3;
        default:
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "request injection failed rc=%{public}d", rc);
            return rc;
    }
}

int32_t ohos_input_query_authorized(void) {
    FnQueryAuthorized fn = ResolveQueryAuthorized();
    if (fn != nullptr) {
        int32_t status = 0;
        if (fn(&status) == 0) {
            g_inject_auth.store(status);
        }
    }
    return g_inject_auth.load();
}

void ohos_input_cancel_injection(void) {
    OH_Input_CancelInjection();
    g_inject_auth.store(0);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "injection cancelled");
}

// 当前按住的鼠标键（-1 表示没有）。拖动要靠移动事件带上按键：
// 只发 BUTTON_DOWN 再发不带 button 的 MOVE，系统会当成「悬停」而不是拖拽。
std::atomic<int32_t> g_pressed_button{-1};

int32_t ohos_input_inject_mouse_move(int32_t x, int32_t y) {
    struct Input_MouseEvent* ev = OH_Input_CreateMouseEvent();
    if (ev == nullptr) {
        return -1;
    }
    OH_Input_SetMouseEventAction(ev, MOUSE_ACTION_MOVE);
    int32_t pressed = g_pressed_button.load(std::memory_order_relaxed);
    if (pressed >= 0) {
        OH_Input_SetMouseEventButton(ev, pressed);
    }
    OH_Input_SetMouseEventDisplayX(ev, x);
    OH_Input_SetMouseEventDisplayY(ev, y);
    // Global 注入按全局坐标系校验（IsValidGlobalXY）：不设 globalX/Y 会被当作
    // 无效值直接返回 INPUT_PARAMETER_ERROR(401)。单屏设备全局坐标 == 显示坐标。
    OH_Input_SetMouseEventGlobalX(ev, x);
    OH_Input_SetMouseEventGlobalY(ev, y);
    OH_Input_SetMouseEventActionTime(ev, NowMicros());
    int32_t rc = OH_Input_InjectMouseEventGlobal(ev);
    OH_Input_DestroyMouseEvent(&ev);
    LogInjectResult("move", rc, x, y);
    return rc;
}

int32_t ohos_input_inject_mouse_button(int32_t button, int32_t down, int32_t x, int32_t y) {
    struct Input_MouseEvent* ev = OH_Input_CreateMouseEvent();
    if (ev == nullptr) {
        return -1;
    }
    OH_Input_SetMouseEventAction(ev, down != 0 ? MOUSE_ACTION_BUTTON_DOWN : MOUSE_ACTION_BUTTON_UP);
    OH_Input_SetMouseEventButton(ev, button);
    OH_Input_SetMouseEventDisplayX(ev, x);
    OH_Input_SetMouseEventDisplayY(ev, y);
    OH_Input_SetMouseEventGlobalX(ev, x);
    OH_Input_SetMouseEventGlobalY(ev, y);
    OH_Input_SetMouseEventActionTime(ev, NowMicros());
    int32_t rc = OH_Input_InjectMouseEventGlobal(ev);
    OH_Input_DestroyMouseEvent(&ev);
    g_pressed_button.store(down != 0 ? button : -1, std::memory_order_relaxed);
    LogInjectResult(down != 0 ? "button-down" : "button-up", rc, x, y);
    return rc;
}

// 单发一个轴事件（action 由调用方给定）。
static int32_t InjectAxisStep(int32_t action, int32_t x, int32_t y, float value, const char* what) {
    struct Input_MouseEvent* ev = OH_Input_CreateMouseEvent();
    if (ev == nullptr) {
        return -1;
    }
    OH_Input_SetMouseEventAction(ev, action);
    OH_Input_SetMouseEventDisplayX(ev, x);
    OH_Input_SetMouseEventDisplayY(ev, y);
    OH_Input_SetMouseEventGlobalX(ev, x);
    OH_Input_SetMouseEventGlobalY(ev, y);
    OH_Input_SetMouseEventAxisType(ev, MOUSE_AXIS_SCROLL_VERTICAL);
    OH_Input_SetMouseEventAxisValue(ev, value);
    OH_Input_SetMouseEventActionTime(ev, NowMicros());
    int32_t rc = OH_Input_InjectMouseEventGlobal(ev);
    OH_Input_DestroyMouseEvent(&ev);
    LogInjectResult(what, rc, x, y);
    if (action == MOUSE_ACTION_AXIS_UPDATE) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "wheel delta x1000=%{public}d", static_cast<int32_t>(value * 1000.0f));
    }
    return rc;
}

// 滚轮：系统按「手势生命周期」消费轴事件，只发 AXIS_BEGIN 不会真正滚动，
// 必须 BEGIN → UPDATE(带轴值) → END 成一组；返回值取 UPDATE 那一步。
int32_t ohos_input_inject_mouse_wheel(int32_t x, int32_t y, float vertical) {
    if (vertical == 0.0f) {
        return 0;
    }
    // BEGIN 也带上轴值：部分实现只读第一个事件的轴值，BEGIN 给 0 会被忽略。
    int32_t rc = InjectAxisStep(MOUSE_ACTION_AXIS_BEGIN, x, y, vertical, "wheel-begin");
    if (rc != 0) {
        return rc;
    }
    rc = InjectAxisStep(MOUSE_ACTION_AXIS_UPDATE, x, y, vertical, "wheel");
    InjectAxisStep(MOUSE_ACTION_AXIS_END, x, y, 0.0f, "wheel-end");
    return rc;
}

int32_t ohos_input_inject_key(int32_t keycode, int32_t down) {
    struct Input_KeyEvent* ev = OH_Input_CreateKeyEvent();
    if (ev == nullptr) {
        return -1;
    }
    OH_Input_SetKeyEventKeyCode(ev, keycode);
    OH_Input_SetKeyEventAction(ev, down != 0 ? KEY_ACTION_DOWN : KEY_ACTION_UP);
    OH_Input_SetKeyEventActionTime(ev, NowMicros());
    int32_t rc = OH_Input_InjectKeyEvent(ev);
    OH_Input_DestroyKeyEvent(&ev);
    LogInjectResult(down != 0 ? "key-down" : "key-up", rc, keycode, 0);
    return rc;
}

void ohos_input_block(int32_t block) {
    // RustDesk 的「屏蔽本机输入」在桌面上靠 grab 实现。OHOS 没有等价的
    // 全局输入拦截 NDK 接口，只能记下状态，实际不生效。
    OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                 "input_block(%{public}d) requested, not supported on OHOS", block);
}

// ===========================================================================
// 屏幕采集（被控端，M3）
// ===========================================================================

// ===========================================================================
// 屏幕采集（被控端）
// ===========================================================================
//
// 走原生 OH_AVScreenCapture（回调模式，RGBA 原始流），把每帧直接推进
// scrap 的共享槽（rustdesk_ohos_capture_push_frame），由 Rust 侧的
// video_service 拿去做编码 —— 采集不做编码，避免两条编码链。
//
// 权限：StartScreenCapture 会由系统弹窗征求用户同意（第三方应用每次
// 会话一次），不需要 ACL 权限。用户拒绝时 Start 返回非 0，UI 据此提示。

namespace {

OH_AVScreenCapture* g_capture = nullptr;
int32_t g_cap_w = 0;
int32_t g_cap_h = 0;
std::atomic<bool> g_cap_on{false};
std::atomic<bool> g_audio_on{false};

// ---------------------------------------------------------------------------
// 系统声音（内部音频）环形缓冲
// ---------------------------------------------------------------------------
//
// RustDesk 的 audio_service 在 Linux 上从 `_pa` IPC 取 PCM、在 Android 上从
// AudioRecord 取；鸿蒙两者都没有。但已经在跑的 OH_AVScreenCapture 本身就能
// 把「整个系统播放的声音」以 PCM 原始流交回来 —— 复用它，不引入第二套采集。
//
// 为什么要过一层环形缓冲而不是直接在系统回调里回调 Rust：
//   • onAudioBufferAvailable 在系统线程上触发，回调期间不能阻塞，
//     而 Rust 侧是拉模式（audio_service 自己每轮取一次），两边节奏不同步；
//   • 缓冲也能吸收画面编码抖动带来的读延迟。
//
// 数据格式：PCM S16LE、48kHz、立体声（与 RustDesk 的 Opus 参数一致，
// 转换只剩 s16→f32 一步，不需要重采样）。
constexpr size_t kAudioRingCap = 1u << 20;  // 1 MiB ≈ 2.7s @48k stereo s16
uint8_t g_audio_ring[kAudioRingCap];
size_t g_audio_rd = 0;
size_t g_audio_wr = 0;
std::mutex g_audio_mu;
std::atomic<int64_t> g_audio_last_read_ms{0};
std::atomic<uint64_t> g_audio_dropped{0};

int64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

void audio_ring_write(const uint8_t* src, size_t len) {
    if (src == nullptr || len == 0 || len > kAudioRingCap) {
        return;
    }
    std::lock_guard<std::mutex> lk(g_audio_mu);
    // 消费者超过 1s 没来取（还没人订阅音频，或对端刚打开声音）：
    // 丢掉缓冲里的陈数据，避免一开声音先放 2 秒"过去的声音"。
    const int64_t last = g_audio_last_read_ms.load(std::memory_order_relaxed);
    if (last == 0 || now_ms() - last > 1000) {
        g_audio_rd = g_audio_wr;
    }
    const size_t avail = kAudioRingCap - (g_audio_wr - g_audio_rd);
    if (len > avail) {
        const size_t drop = len - avail;
        g_audio_rd += drop;
        g_audio_dropped.fetch_add(drop, std::memory_order_relaxed);
    }
    for (size_t i = 0; i < len; ++i) {
        g_audio_ring[(g_audio_wr + i) % kAudioRingCap] = src[i];
    }
    g_audio_wr += len;
}

void OnCaptureError(OH_AVScreenCapture* /*capture*/, int32_t code, void* /*userData*/) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                 "screen capture error %{public}d", code);
}

// SetCallback 结构体里的 onError 是不带 userData 的 2 参签名（与
// SetErrorCallback 的 3 参不同），复用同一个日志实现。
void OnCaptureErrorCb(OH_AVScreenCapture* capture, int32_t code) {
    OnCaptureError(capture, code, nullptr);
}

// 拉取模式：onVideoBufferAvailable 只通知"有帧"，实际取帧走
// AcquireVideoBuffer → OH_NativeBuffer。只有这条路能拿到系统缓冲区的
// 真实行跨距（stride）与像素格式 —— DataCallback 推送模式的 OH_AVBuffer
// 不暴露 stride，而真机的缓冲区是带行对齐 padding 的，按 width*4 紧凑
// 解析会整幅错位（花屏）。取完帧按行压平成紧凑 RGBA 再推给 Rust。
void OnVideoBufferAvailable(OH_AVScreenCapture* capture, bool isReady) {
    static std::atomic<int32_t> cb_count{0};
    static std::atomic<int32_t> err_count{0};
    const int32_t n = cb_count.fetch_add(1);
    if (!isReady || capture == nullptr ||
        !g_cap_on.load(std::memory_order_acquire)) {
        return;
    }
    int32_t fence = -1;
    int64_t timestamp = 0;
    OH_Rect region{};
    OH_NativeBuffer* nb =
        OH_AVScreenCapture_AcquireVideoBuffer(capture, &fence, &timestamp, &region);
    if (nb == nullptr) {
        if (err_count.fetch_add(1) < 3) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "acquire video buffer returned null");
        }
        return;
    }
    void* vir = nullptr;
    OH_NativeBuffer_Config bcfg{};
    const int32_t map_rc = OH_NativeBuffer_Map(nb, &vir);
    OH_NativeBuffer_GetConfig(nb, &bcfg);
    if (map_rc != 0 || vir == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "native buffer map failed rc=%{public}d", map_rc);
        OH_AVScreenCapture_ReleaseVideoBuffer(capture);
        return;
    }
    // 注意：fence fd 不要自己 close。官方示例（Acquire→Map→GetConfig→UnMap→
    // Release）从不关闭 fence —— 系统在 ReleaseVideoBuffer 时统一回收。
    // 这里曾经 close(fence)，与系统的释放形成双重关闭：fd 号被复用后，
    // 系统的第二次 close 会误杀随机存活 fd（连接 socket → 主控端反复断联；
    // 音频线程 tokio 的 epoll fd → epoll_wait EBADF → panic 闪退）。
    const int32_t w = bcfg.width;
    const int32_t h = bcfg.height;
    const int32_t stride = bcfg.stride;
    if (w <= 0 || h <= 0 || stride < w * 4) {
        if (err_count.fetch_add(1) < 3) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "bad buffer config %dx%d stride=%d fmt=%d",
                         w, h, stride, bcfg.format);
        }
        OH_NativeBuffer_Unmap(nb);
        OH_AVScreenCapture_ReleaseVideoBuffer(capture);
        return;
    }
    if (n < 3 || n % 150 == 0) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "capture frame #%{public}d %{public}dx%{public}d stride=%{public}d fmt=%{public}d",
                     n, w, h, stride, bcfg.format);
    }

    // 按行压平成紧凑 RGBA（stride 可能带 padding；BGRA 就地换 R/B 通道）。
    const size_t compact_stride = static_cast<size_t>(w) * 4;
    const size_t need = compact_stride * static_cast<size_t>(h);
    static std::mutex compact_mu;
    static std::vector<uint8_t> compact;
    {
        std::lock_guard<std::mutex> lk(compact_mu);
        compact.resize(need);
        const uint8_t* src = static_cast<const uint8_t*>(vir);
        if (bcfg.format == NATIVEBUFFER_PIXEL_FMT_RGBA_8888 && stride == w * 4) {
            std::memcpy(compact.data(), src, need);
        } else {
            for (int32_t y = 0; y < h; ++y) {
                const uint8_t* row = src + static_cast<size_t>(y) * stride;
                uint8_t* dst = compact.data() + static_cast<size_t>(y) * compact_stride;
                if (bcfg.format == NATIVEBUFFER_PIXEL_FMT_RGBA_8888) {
                    std::memcpy(dst, row, compact_stride);
                } else if (bcfg.format == NATIVEBUFFER_PIXEL_FMT_BGRA_8888) {
                    for (int32_t x = 0; x < w; ++x) {
                        dst[x * 4 + 0] = row[x * 4 + 2];
                        dst[x * 4 + 1] = row[x * 4 + 1];
                        dst[x * 4 + 2] = row[x * 4 + 0];
                        dst[x * 4 + 3] = row[x * 4 + 3];
                    }
                } else {
                    if (err_count.fetch_add(1) < 3) {
                        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                                     "unsupported pixel format %d", bcfg.format);
                    }
                    OH_NativeBuffer_Unmap(nb);
                    OH_AVScreenCapture_ReleaseVideoBuffer(capture);
                    return;
                }
            }
        }
        rustdesk_ohos_capture_push_frame(compact.data(), need,
                                         static_cast<size_t>(w),
                                         static_cast<size_t>(h), compact_stride);
    }
    OH_NativeBuffer_Unmap(nb);
    OH_AVScreenCapture_ReleaseVideoBuffer(capture);
}

// 音频缓冲可用：拉取 → 拷进环形缓冲 → 立即归还。
// 只处理 OH_ALL_PLAYBACK（整个系统的播放声）。麦克风那一路在 Start 时就被
// SetMicrophoneEnabled(false) 关掉了 —— 远程协助要先能把"电脑里的声音"传过去，
// 录麦克风还牵扯隐私授权，等真有需求再单独开。
void OnAudioBufferAvailable(OH_AVScreenCapture* capture, bool isReady,
                            OH_AudioCaptureSourceType type) {
    static std::atomic<int32_t> cnt{0};
    static std::atomic<int32_t> err_cnt{0};
    if (!isReady || capture == nullptr || type != OH_ALL_PLAYBACK ||
        !g_cap_on.load(std::memory_order_acquire)) {
        return;
    }
    // 关键：这个接口要的是「由调用方提供的结构体」，系统只负责往里填
    // （`*audiobuffer` 不能是 nullptr，否则系统侧报 #906 并直接返回）。
    // 传 `&nullptr` 会一直被拒 —— 这是第一次实现的错误。
    static OH_AudioBuffer audio_buf{};
    OH_AudioBuffer* p = &audio_buf;
    const OH_AVSCREEN_CAPTURE_ErrCode rc =
        OH_AVScreenCapture_AcquireAudioBuffer(capture, &p, type);
    if (rc != AV_SCREEN_CAPTURE_ERR_OK || p == nullptr || p->buf == nullptr ||
        p->size <= 0) {
        if (err_cnt.fetch_add(1) < 3) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "acquire audio buffer failed rc=%{public}d size=%{public}d",
                         static_cast<int32_t>(rc), p == nullptr ? -1 : p->size);
        }
        return;
    }
    audio_ring_write(p->buf, static_cast<size_t>(p->size));
    const int32_t n = cnt.fetch_add(1);
    if (n < 3 || n % 500 == 0) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "capture audio #%{public}d size=%{public}d type=%{public}d",
                     n, p->size, static_cast<int32_t>(type));
    }
    // 与视频缓冲一样：归还由系统负责，应用不要自己 close 任何 fd。
    OH_AVScreenCapture_ReleaseAudioBuffer(capture, type);
}

/// 建一个采集实例并启动。`with_audio` 为 false 时完全不带音频配置。
///
/// 拆成单独函数是为了让调用方能在"带音频启动失败"时退回"纯画面" ——
/// 音频是增强项，不能因为它拖垮整个被控链路。
OH_AVScreenCapture* TryStartCapture(int32_t w, int32_t h, bool with_audio,
                                    int32_t* out_rc) {
    OH_AVScreenCapture* cap = OH_AVScreenCapture_Create();
    if (cap == nullptr) {
        *out_rc = -3;
        return nullptr;
    }

    OH_AVScreenCaptureConfig cfg{};
    cfg.captureMode = OH_CAPTURE_HOME_SCREEN;
    cfg.dataType = OH_ORIGINAL_STREAM;  // 原始帧（RGBA / PCM），不是编码流
    cfg.videoInfo.videoCapInfo.videoFrameWidth = w;
    cfg.videoInfo.videoCapInfo.videoFrameHeight = h;
    cfg.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
    if (with_audio) {
        cfg.audioInfo.micCapInfo.audioSampleRate = 48000;
        cfg.audioInfo.micCapInfo.audioChannels = 2;
        cfg.audioInfo.micCapInfo.audioSource = OH_MIC;
        cfg.audioInfo.innerCapInfo.audioSampleRate = 48000;
        cfg.audioInfo.innerCapInfo.audioChannels = 2;
        cfg.audioInfo.innerCapInfo.audioSource = OH_ALL_PLAYBACK;
    }

    OH_AVSCREEN_CAPTURE_ErrCode rc = OH_AVScreenCapture_Init(cap, cfg);
    if (rc != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "capture init failed rc=%{public}d audio=%{public}d",
                     static_cast<int32_t>(rc), with_audio ? 1 : 0);
        OH_AVScreenCapture_Release(cap);
        *out_rc = -4;
        return nullptr;
    }

    if (with_audio) {
        // 只要系统播放声，不要麦克风（关掉后系统也不会弹录音授权）。
        rc = OH_AVScreenCapture_SetMicrophoneEnabled(cap, false);
        if (rc != AV_SCREEN_CAPTURE_ERR_OK) {
            OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                         "disable microphone rc=%{public}d", static_cast<int32_t>(rc));
        }
    }

    OH_AVScreenCapture_SetErrorCallback(cap, OnCaptureError, nullptr);
    // 拉取模式（SetCallback 的 onVideoBufferAvailable）而不是 SetDataCallback：
    // 只有拉取模式的 AcquireVideoBuffer 能拿到 OH_NativeBuffer，从而读到
    // 真实的 stride / 像素格式（真机缓冲区带行对齐 padding，见回调注释）。
    OH_AVScreenCaptureCallback cbs{};
    cbs.onError = OnCaptureErrorCb;
    cbs.onAudioBufferAvailable = with_audio ? OnAudioBufferAvailable : nullptr;
    cbs.onVideoBufferAvailable = OnVideoBufferAvailable;
    rc = OH_AVScreenCapture_SetCallback(cap, cbs);
    if (rc != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "set callback failed rc=%{public}d", static_cast<int32_t>(rc));
        OH_AVScreenCapture_Release(cap);
        *out_rc = -4;
        return nullptr;
    }

    rc = OH_AVScreenCapture_StartScreenCapture(cap);
    if (rc != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "start screen capture failed rc=%{public}d audio=%{public}d (user denied?)",
                     static_cast<int32_t>(rc), with_audio ? 1 : 0);
        OH_AVScreenCapture_Release(cap);
        *out_rc = -5;
        return nullptr;
    }
    g_audio_on.store(with_audio, std::memory_order_release);
    return cap;
}

}  // namespace

/// 本机能否采集屏幕（被控端前置条件）。手机形态不支持被控，返回 0。
int32_t ohos_capture_can_start(void) {
    return rustdesk_ohos::Is2in1() ? 1 : 0;
}

int32_t ohos_capture_start(uint32_t display_id) {
    if (!rustdesk_ohos::Is2in1()) {
        OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                     "capture_start: not 2in1, refused");
        return -1;
    }
    std::lock_guard<std::mutex> lk(g_capture_mu);
    if (g_capture != nullptr) {
        return 0;
    }
    (void)display_id;  // 当前只采主屏（OH_CAPTURE_HOME_SCREEN）

    int32_t w = 0;
    int32_t h = 0;
    if (OH_NativeDisplayManager_GetDefaultDisplayWidth(&w) != DISPLAY_MANAGER_OK ||
        OH_NativeDisplayManager_GetDefaultDisplayHeight(&h) != DISPLAY_MANAGER_OK ||
        w <= 0 || h <= 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "capture_start: display size unavailable");
        return -2;
    }
    // 让 scrap 的显示器列表与真实屏幕一致，video_service 才能建服务。
    rustdesk_ohos_displays_sync();

    // 先试「画面 + 系统声音」，失败再退回「纯画面」。
    OH_AVScreenCapture* cap = nullptr;
    int32_t last_rc = 0;
    for (int attempt = 0; attempt < 2 && cap == nullptr; ++attempt) {
        const bool with_audio = attempt == 0;
        cap = TryStartCapture(w, h, with_audio, &last_rc);
        if (cap == nullptr && with_audio) {
            OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                         "capture with audio failed rc=%{public}d, retry without audio",
                         last_rc);
        }
    }
    if (cap == nullptr) {
        return last_rc;
    }

    g_cap_w = w;
    g_cap_h = h;
    g_cap_on.store(true, std::memory_order_release);
    g_capture_running = true;
    g_capture = cap;
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "screen capture started, %{public}dx%{public}d RGBA, audio=%{public}d",
                 w, h, g_audio_on.load() ? 1 : 0);
    return 0;
}

int32_t ohos_capture_stop(void) {
    OH_AVScreenCapture* cap = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_capture_mu);
        g_cap_on.store(false, std::memory_order_release);
        g_capture_running = false;
        cap = g_capture;
        g_capture = nullptr;
    }
    if (cap != nullptr) {
        OH_AVScreenCapture_StopScreenCapture(cap);
        OH_AVScreenCapture_Release(cap);
        rustdesk_ohos_capture_clear();
        g_audio_on.store(false, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lk(g_audio_mu);
            g_audio_rd = 0;
            g_audio_wr = 0;
            g_audio_last_read_ms.store(0, std::memory_order_relaxed);
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "screen capture stopped");
    }
    return 0;
}

/// 采集是否在跑（1）或已停（0）。宿主守护线程用它判断要不要重起采集：
/// 用户撤销录屏授权、系统回收、进程挂起后恢复，都会让采集静默消失。
int32_t ohos_capture_is_running(void) {
    return (g_capture_running && g_capture != nullptr) ? 1 : 0;
}

/// 可读的音频字节数（PCM S16LE 48k 立体声）。Rust 侧据此只取整 10ms 块。
int32_t ohos_capture_audio_available(void) {
    std::lock_guard<std::mutex> lk(g_audio_mu);
    return static_cast<int32_t>(g_audio_wr - g_audio_rd);
}

/// 取走最多 cap 字节。返回实际拷贝量（0 表示暂时没有数据）。
int32_t ohos_capture_read_audio(uint8_t* dst, int32_t cap) {
    if (dst == nullptr || cap <= 0) {
        return 0;
    }
    std::lock_guard<std::mutex> lk(g_audio_mu);
    const size_t avail = g_audio_wr - g_audio_rd;
    const size_t n = avail < static_cast<size_t>(cap) ? avail : static_cast<size_t>(cap);
    for (size_t i = 0; i < n; ++i) {
        dst[i] = g_audio_ring[(g_audio_rd + i) % kAudioRingCap];
    }
    g_audio_rd += n;
    g_audio_last_read_ms.store(now_ms(), std::memory_order_relaxed);
    return static_cast<int32_t>(n);
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
