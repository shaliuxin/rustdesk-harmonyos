// ArkTS ←→ C++ 的 napi 边界。
//
// 这一层只做三件事：
//   1. 注册 entry 模块，把 rustdesk_ohos_* 包成 JS 函数
//   2. 把 XComponent 的 Surface 生命周期接给 renderer
//   3. 用一个 napi threadsafe function 把 Rust 的 JSON 事件派发到 ArkTS 主线程
//
// 为什么事件只用一个函数（`onEvent`）而不是 48 个回调：
//   Rust 的 InvokeUiSession 有 48 个方法，如果每个都对应一个 napi 回调，
//   C++ 要写 48 个 threadsafe function、48 个上下文对象，而且新增事件
//   要改三处（Rust/C++/ArkTS）。统一成 `{"event":..,"data":..}` 后，
//   只有 C++ 需要动的是「一次线程切换」，事件名清单本身在
//   ohos/include/rustdesk_ohos.h 里维护。
//
// 线程模型：
//   Rust 从 tokio worker 调用 → PostUiEvent（任意线程）
//     → napi_call_threadsafe_function（非阻塞入队）
//       → CallJs（ArkTS 主线程）→ ArkTS 的 onEvent 回调

#include "bridge.h"
#include "rustdesk_ohos.h"

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <napi/native_api.h>

#include <memory>
#include <mutex>
#include <string>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "RustDeskNapi"

namespace {

// tsfn 的句柄 + 一个身份标记。
//
// 为什么要标记：`napi_release_threadsafe_function` 是异步的，finalize 回调
// 可能在我们已经创建了**新**的 tsfn 之后才触发。如果 finalize 里无脑
// `g_tsfn = nullptr`，就会把刚建好的那个打死（表现为「第二次进会话收不到
// 任何事件」）。所以 finalize 只清理属于自己那一代的东西。
struct TsfnToken {
    napi_threadsafe_function fn = nullptr;
};

napi_threadsafe_function g_tsfn = nullptr;
TsfnToken* g_tsfn_token = nullptr;
std::mutex g_tsfn_mu;

// --- 参数辅助 --------------------------------------------------------------

bool GetStringArg(napi_env env, napi_value value, std::string& out) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) return false;
    if (len == 0) {
        out.clear();
        return true;
    }
    // napi_get_value_string_utf8 会连 NUL 一起写，所以缓冲区要比 len 大 1。
    std::string buf(len + 1, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, &buf[0], buf.size(), &copied) != napi_ok) {
        return false;
    }
    // 用 copied 而不是 len：理论上一致，但 UTF-8 截断时 copied 才是真实长度。
    out.assign(buf.c_str(), copied);
    return true;
}

bool GetIntArg(napi_env env, napi_value value, int32_t& out) {
    return napi_get_value_int32(env, value, &out) == napi_ok;
}

bool GetBoolArg(napi_env env, napi_value value, bool& out) {
    return napi_get_value_bool(env, value, &out) == napi_ok;
}

napi_value MakeInt(napi_env env, int32_t v) {
    napi_value out;
    napi_create_int32(env, v, &out);
    return out;
}

napi_value MakeBool(napi_env env, bool v) {
    napi_value out;
    napi_get_boolean(env, v, &out);
    return out;
}

napi_value MakeUndefined(napi_env env) {
    napi_value out;
    napi_get_undefined(env, &out);
    return out;
}

// 把 Rust 返回的 char* 转成 JS 字符串并释放。
// Rust 分配、C++ 释放 —— 与头文件里的约定一致（rustdesk_ohos_string_free）。
napi_value TakeString(napi_env env, char* p) {
    if (p == nullptr) {
        napi_value null_v;
        napi_get_null(env, &null_v);
        return null_v;
    }
    napi_value out;
    napi_create_string_utf8(env, p, NAPI_AUTO_LENGTH, &out);
    rustdesk_ohos_string_free(p);
    return out;
}

// --- threadsafe function ---------------------------------------------------

void CallJs(napi_env env, napi_value js_cb, void* /*context*/, void* data) {
    std::unique_ptr<std::string> msg(static_cast<std::string*>(data));
    // env 为 null 表示运行时正在销毁（napi_tsfn_abort 之后）。
    // 此时必须自己释放 data，且不能碰任何 napi value。
    if (env == nullptr || js_cb == nullptr || msg == nullptr) return;

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_value arg;
    napi_create_string_utf8(env, msg->c_str(), msg->size(), &arg);
    napi_call_function(env, undefined, js_cb, 1, &arg, nullptr);
}

void OnTsfnFinalize(napi_env /*env*/, void* data, void* /*hint*/) {
    auto* token = static_cast<TsfnToken*>(data);
    {
        std::lock_guard<std::mutex> lk(g_tsfn_mu);
        if (g_tsfn_token == token) {
            g_tsfn = nullptr;
            g_tsfn_token = nullptr;
        }
    }
    delete token;
}

// --- XComponent ------------------------------------------------------------

void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window) {
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    rustdesk_ohos::OnSurfaceCreated(window, static_cast<int32_t>(w), static_cast<int32_t>(h));
}

void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window) {
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    rustdesk_ohos::OnSurfaceChanged(static_cast<int32_t>(w), static_cast<int32_t>(h));
}

void OnSurfaceDestroyedCB(OH_NativeXComponent* /*component*/, void* /*window*/) {
    rustdesk_ohos::OnSurfaceDestroyed();
}

OH_NativeXComponent_Callback g_xc_callback = {
    .OnSurfaceCreated = OnSurfaceCreatedCB,
    .OnSurfaceChanged = OnSurfaceChangedCB,
    .OnSurfaceDestroyed = OnSurfaceDestroyedCB,
    .DispatchTouchEvent = nullptr,
};

// --- 导出函数 --------------------------------------------------------------

napi_value JsAbiVersion(napi_env env, napi_callback_info /*info*/) {
    return MakeInt(env, static_cast<int32_t>(rustdesk_ohos_abi_version()));
}

napi_value JsInit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return MakeInt(env, -1);
    std::string app_dir;
    if (!GetStringArg(env, args[0], app_dir)) return MakeInt(env, -1);
    return MakeInt(env, rustdesk_ohos_init(app_dir.c_str()));
}

napi_value JsLastError(napi_env env, napi_callback_info /*info*/) {
    return TakeString(env, rustdesk_ohos_last_error());
}

napi_value JsSessionStart(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string peer_id;
    std::string password;
    int32_t force_relay = 0;
    if (argc < 1 || !GetStringArg(env, args[0], peer_id)) return MakeInt(env, -1);
    if (argc >= 2 && args[1] != nullptr) GetStringArg(env, args[1], password);
    if (argc >= 3 && args[2] != nullptr) GetIntArg(env, args[2], force_relay);

    return MakeInt(env, rustdesk_ohos_session_start(peer_id.c_str(), password.c_str(), force_relay));
}

napi_value JsSessionClose(napi_env env, napi_callback_info /*info*/) {
    rustdesk_ohos_session_close();
    return MakeUndefined(env);
}

napi_value JsSessionRefresh(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t display = 0;
    if (argc >= 1) GetIntArg(env, args[0], display);
    rustdesk_ohos_session_refresh(display);
    return MakeUndefined(env);
}

napi_value JsStateJson(napi_env env, napi_callback_info /*info*/) {
    return TakeString(env, rustdesk_ohos_state_json());
}

napi_value JsMouse(napi_env env, napi_callback_info info) {
    // 7 个参数：mask, x, y, alt, ctrl, shift, command
    size_t argc = 7;
    napi_value args[7] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t v[7] = {0, 0, 0, 0, 0, 0, 0};
    for (size_t i = 0; i < argc && i < 7; ++i) {
        if (args[i] != nullptr) GetIntArg(env, args[i], v[i]);
    }
    // 缺参数时按 0 处理：调用方少传修饰键是常见情况，不该报错。
    return MakeInt(env, rustdesk_ohos_mouse(v[0], v[1], v[2], v[3], v[4], v[5], v[6]));
}

napi_value JsKey(napi_env env, napi_callback_info info) {
    // 7 个参数：name, down, press, alt, ctrl, shift, command
    size_t argc = 7;
    napi_value args[7] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string name;
    if (argc < 1 || !GetStringArg(env, args[0], name)) return MakeInt(env, -1);
    int32_t v[6] = {0, 0, 0, 0, 0, 0};
    for (size_t i = 1; i < argc && i < 7; ++i) {
        if (args[i] != nullptr) GetIntArg(env, args[i], v[i - 1]);
    }
    return MakeInt(env, rustdesk_ohos_key(name.c_str(), v[0], v[1], v[2], v[3], v[4], v[5]));
}

napi_value JsCtrlAltDel(napi_env env, napi_callback_info /*info*/) {
    return MakeInt(env, rustdesk_ohos_ctrl_alt_del());
}

napi_value JsSwitchDisplay(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t index = 0;
    if (argc >= 1) GetIntArg(env, args[0], index);
    return MakeInt(env, rustdesk_ohos_switch_display(index));
}

napi_value JsSendChat(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string text;
    if (argc < 1 || !GetStringArg(env, args[0], text)) return MakeInt(env, -1);
    return MakeInt(env, rustdesk_ohos_send_chat(text.c_str()));
}

napi_value JsDisplaysSync(napi_env env, napi_callback_info /*info*/) {
    return MakeInt(env, rustdesk_ohos_displays_sync());
}

napi_value JsLogProbe(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string msg;
    if (argc >= 1) GetStringArg(env, args[0], msg);
    rustdesk_ohos_log_probe(msg.c_str());
    return MakeUndefined(env);
}

// 切换渲染循环。切后台时 ArkTS 调 setRenderActive(false)，
// 避免后台还在 30fps 拉帧耗电。
napi_value JsSetRenderActive(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool active = true;
    if (argc >= 1) GetBoolArg(env, args[0], active);
    rustdesk_ohos::SetRenderActive(active);
    return MakeUndefined(env);
}

// 注册 UI 事件回调。只能设一个（多设会覆盖），因为 ArkTS 侧永远只有一个页面在收。
napi_value JsOnEvent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return MakeBool(env, false);

    napi_valuetype type = napi_undefined;
    napi_typeof(env, args[0], &type);
    if (type != napi_function) return MakeBool(env, false);

    napi_value name;
    napi_create_string_utf8(env, "rustdesk.uiEvent", NAPI_AUTO_LENGTH, &name);

    std::lock_guard<std::mutex> lk(g_tsfn_mu);
    if (g_tsfn != nullptr) {
        napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
        g_tsfn = nullptr;
        g_tsfn_token = nullptr;  // 交给 finalize 去 delete
    }

    auto* token = new (std::nothrow) TsfnToken();
    if (token == nullptr) return MakeBool(env, false);

    napi_status st = napi_create_threadsafe_function(
        env, args[0], nullptr, name,
        0,   // max_queue_size = 0 → 不限制。事件量不大（每帧一条 rgba + 稀疏控制事件），
             // 限制反而会在弱网抖动时丢「连接状态」这种必须送达的消息。
        1,   // initial_thread_count
        token, OnTsfnFinalize, nullptr,
        CallJs, &token->fn);
    if (st != napi_ok) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "create threadsafe function failed: %{public}d", st);
        delete token;
        return MakeBool(env, false);
    }
    g_tsfn = token->fn;
    g_tsfn_token = token;
    return MakeBool(env, true);
}

// --- 模块注册 --------------------------------------------------------------

napi_value Init(napi_env env, napi_value exports) {
    // XComponent：只有 libraryname 为 "entry" 的 XComponent 会走到这里。
    napi_value xc_export = nullptr;
    napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xc_export);
    if (xc_export != nullptr) {
        OH_NativeXComponent* component = nullptr;
        if (napi_unwrap(env, xc_export, reinterpret_cast<void**>(&component)) == napi_ok &&
            component != nullptr) {
            OH_NativeXComponent_RegisterCallback(component, &g_xc_callback);
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "XComponent registered");
        }
    }

    napi_property_descriptor desc[] = {
        {"abiVersion", nullptr, JsAbiVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"init", nullptr, JsInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError", nullptr, JsLastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sessionStart", nullptr, JsSessionStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sessionClose", nullptr, JsSessionClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sessionRefresh", nullptr, JsSessionRefresh, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stateJson", nullptr, JsStateJson, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mouse", nullptr, JsMouse, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"key", nullptr, JsKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"ctrlAltDel", nullptr, JsCtrlAltDel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"switchDisplay", nullptr, JsSwitchDisplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendChat", nullptr, JsSendChat, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"displaysSync", nullptr, JsDisplaysSync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"logProbe", nullptr, JsLogProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setRenderActive", nullptr, JsSetRenderActive, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onEvent", nullptr, JsOnEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

namespace rustdesk_ohos {

bool PostUiEvent(const char* json) {
    std::lock_guard<std::mutex> lk(g_tsfn_mu);
    if (g_tsfn == nullptr) return false;
    auto* payload = new (std::nothrow) std::string(json);
    if (payload == nullptr) return false;
    // 非阻塞：队列满时宁可丢这条事件，也不能卡住 Rust 的 tokio worker。
    napi_status st = napi_call_threadsafe_function(g_tsfn, payload, napi_tsfn_nonblocking);
    if (st != napi_ok) {
        delete payload;
        return false;
    }
    return true;
}

}  // namespace rustdesk_ohos

extern "C" __attribute__((constructor)) void RegisterRustDeskModule(void) {
    napi_module_register(&g_module);
}
