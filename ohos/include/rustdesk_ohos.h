// RustDesk HarmonyOS —— Rust 核心与 C++ 胶水层之间的 C ABI。
//
// 这个头文件是两个方向的唯一契约：
//
//   1. **导出**（`rustdesk_ohos_*`）：Rust 实现，C++/ArkTS 调用。
//      ArkTS 通过 napi 调 C++，C++ 再调这里；也可以由 C++ 直接调（UI 线程外）。
//
//   2. **导入**（`ohos_*`）：C++ 实现，Rust 调用。这些必须由
//      `libentry.so`（或任何被链接进同一进程的 C++ 库）提供，否则链接期报未定义符号。
//      见 `src/platform/ohos/ffi.rs` 与 `libs/scrap/src/lib.rs` 的 `extern "C"` 声明。
//
// 线程约定：
//   - 所有 `rustdesk_ohos_*` 都可以从任意线程调用，内部有锁；但
//     `rustdesk_ohos_frame_acquire` / `_frame_release` 必须成对、同线程。
//   - 所有 `ohos_*` 由 Rust 从 tokio worker 线程调用，C++ 侧实现**必须线程安全**，
//     涉及 UI 的必须自己切到 ArkTS 主线程（napi_create_threadsafe_function）。
//
// 字符串约定：
//   - 传入 Rust 的 `const char*` 是 UTF-8、以 NUL 结尾，生命周期只需覆盖本次调用。
//   - 从 Rust 返回的 `char*` 由 Rust 分配，调用方必须用
//     `rustdesk_ohos_string_free()` / `ohos_free_string()` 释放，**不能** free()。

#ifndef RUSTDESK_OHOS_H
#define RUSTDESK_OHOS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ===========================================================================
// 一、Rust 导出的接口
// ===========================================================================

// ABI 版本。ArkTS/C++ 启动时校验，避免 .a 与胶水层版本错配。
uint32_t rustdesk_ohos_abi_version(void);

// 进程内初始化，必须最先调用且只调一次。
// app_dir: 应用沙箱内的可写目录（ArkTS 的 context.filesDir）。
// 返回 0 成功。
int32_t rustdesk_ohos_init(const char *app_dir);

// 最近一次错误信息。调用方负责 rustdesk_ohos_string_free。
char *rustdesk_ohos_last_error(void);

void rustdesk_ohos_string_free(char *p);

// --- 主控会话 -------------------------------------------------------------

// 连接远端。立即返回，结果通过 ui_event("connected"/"msgbox") 上报。
// peer_id: "123456789" 或 "123456789@server"，可带 "?key=..." 参数
// password: 预设密码，空串表示连接后再向用户索要
// force_relay: 非 0 表示强制中继
int32_t rustdesk_ohos_session_start(const char *peer_id, const char *password,
                                    int32_t force_relay);

void rustdesk_ohos_session_close(void);

// 请求关键帧（回到前台 / 旋转屏幕后调用）。
void rustdesk_ohos_session_refresh(int32_t display);

// 连接状态快照（JSON）。页面重建后用它恢复 UI。调用方负责 free。
// 形如：
// {"connected":true,"secured":true,"direct":false,"stream_type":"DEFAULT_CONN",
//  "peer_id":"...","display":{"x":0,"y":0,"w":1080,"h":1920},"scale":1.0,
//  "cursor":{"x":0,"y":0,"embedded":true},"block_input":false,"displays":[...]}
char *rustdesk_ohos_state_json(void);

// --- 帧 -------------------------------------------------------------------

// 取当前帧（RGBA8888）。返回空指针表示暂无新帧（画面静止时的正常现象）。
// 尺寸写入 out_w / out_h。拿到后必须调 rustdesk_ohos_frame_release，
// 否则下一帧会被背压丢弃、画面停住。
const uint8_t *rustdesk_ohos_frame_acquire(int32_t display, int32_t *out_w,
                                           int32_t *out_h);

void rustdesk_ohos_frame_release(int32_t display);

// --- 输入：本机事件 → 远端 -------------------------------------------------

// mask: RustDesk 协议的鼠标掩码，与 Flutter 版 session_send_mouse 完全一致：
//   低 3 位（0x7）是事件类型：
//     0 MOVE / 1 DOWN / 2 UP / 3 WHEEL / 4 TRACKPAD / 5 MOVE_RELATIVE
//   高位是同时按下的按钮：
//     0x01 LEFT / 0x02 RIGHT / 0x04 WHEEL / 0x08 BACK / 0x10 FORWARD
// 典型组合：左键按下 = 0x01 | 1 = 1；左键拖动 = 0x01 | 0 = 1（MOVE 时按钮位保留）。
// 坐标是远端画面坐标系（已按 state_json 里的 display/scale 换算过）；
// WHEEL / TRACKPAD 时 x/y 是滚动增量，符号由服务端按 reverse_mouse_wheel 处理。
int32_t rustdesk_ohos_mouse(int32_t mask, int32_t x, int32_t y, int32_t alt,
                            int32_t ctrl, int32_t shift, int32_t command);

// name: RustDesk 键名（"A" "F1" "Backspace" "ArrowLeft" …），单字符键直接传字符。
int32_t rustdesk_ohos_key(const char *name, int32_t down, int32_t press,
                          int32_t alt, int32_t ctrl, int32_t shift,
                          int32_t command);

int32_t rustdesk_ohos_ctrl_alt_del(void);

int32_t rustdesk_ohos_switch_display(int32_t index);

int32_t rustdesk_ohos_send_chat(const char *text);

// --- 被控端：ArkTS 推入屏幕 -------------------------------------------------

// data: RGBA8888，len 字节；stride 传 0 表示 width*4。
// 数据会被拷贝，返回后 ArkTS 可以立刻重用它的 ArrayBuffer。
int32_t rustdesk_ohos_capture_push_frame(const uint8_t *data, size_t len,
                                         size_t width, size_t height,
                                         size_t stride);

// 采集被系统暂停（切后台、撤销授权）时调用，清空帧队列。
void rustdesk_ohos_capture_clear(void);

// 重新读一遍系统显示器列表并灌进采集队列。
// ArkTS 在 display.on('add'|'remove'|'change') 时调用。返回显示器数量。
int32_t rustdesk_ohos_displays_sync(void);

// 连通性自检：打一条 hilog 并发一个 probe 事件。
void rustdesk_ohos_log_probe(const char *msg);

// ===========================================================================
// 二、C++ 必须实现的接口（Rust 依赖它们，缺失会导致链接失败）
// ===========================================================================

// --- 设备与账号 -----------------------------------------------------------
int32_t ohos_device_type(void);           // 0=PHONE 1=TABLET 2=2IN1
char *ohos_get_active_user_name(void);    // Rust 侧调用后即 free
char *ohos_get_active_user_id(void);
int32_t ohos_is_locked(void);
int32_t ohos_lock_screen(void);           // 0 成功

// --- 输入注入（仅 2in1；手机形态恒返回 0）----------------------------------
int32_t ohos_input_can_inject(void);
int32_t ohos_input_request_authorization(void);
void ohos_input_block(int32_t block);

// --- 屏幕采集能力 ---------------------------------------------------------
int32_t ohos_capture_can_start(void);
int32_t ohos_capture_start(uint32_t display_id);
int32_t ohos_capture_stop(void);

// 编码帧回调：C++ 编码后把 packet 交回 Rust host 侧。
// data 只在回调期间有效，Rust 侧会立即拷贝。
typedef void (*ohos_frame_cb)(int32_t codec, int64_t pts_us, int32_t is_key,
                              const uint8_t *data, size_t len);
void ohos_capture_set_frame_callback(ohos_frame_cb cb);

// --- 剪贴板 ---------------------------------------------------------------
char *ohos_clipboard_get_text(void);        // 无文本返回 NULL 或空串
void ohos_clipboard_set_text(const char *text);
// multimime：剪贴板多格式（文本 + 图片 + 文件），protobuf 编码
int32_t ohos_clipboard_update_multi(const uint8_t *data, size_t len);
int32_t ohos_clipboard_get_multi(uint8_t **out, size_t *out_len);

// --- 显示器 ---------------------------------------------------------------
typedef struct {
  uint32_t id;
  uint32_t width;
  uint32_t height;
  uint32_t rotation;   // 0/90/180/270
  double scale;
  char name[64];
} OhosDisplayInfo;

int32_t ohos_display_count(void);
int32_t ohos_display_info(int32_t index, OhosDisplayInfo *out);

// --- 指针位置 -------------------------------------------------------------
int32_t ohos_cursor_pos(int32_t *out_x, int32_t *out_y);

// --- 内存与日志 -----------------------------------------------------------
void ohos_free_string(char *s);
void ohos_free_bytes(uint8_t *p);
void ohos_log(int32_t level, const char *tag, const char *msg);  // 0d 1i 2w 3e

// --- UI 事件（Rust → ArkTS）-----------------------------------------------
// json: {"event":"connected","data":{...}} 形式的 JSON。
// 实现要求：拷贝字符串后立刻返回，并切到 ArkTS 主线程派发；
// 典型实现是 napi_threadsafe_function + 一个队列。
//
// 事件名清单（`data` 结构见 src/platform/ohos/ui_handler.rs）：
//   rgba(display)                    有新帧，去 frame_acquire 取
//   display(x,y,w,h,cursor_embedded,scale)
//   displays([...])                  多屏列表
//   cursor_position(x,y) / cursor_id / cursor_data
//   connected(conn_type) / close(reason) / connection_type(secured,direct,stream_type)
//   peer_info / fingerprint / permission(name,value) / quality_status
//   msgbox(type,title,text,link,retry) / cancel_msgbox(tag)
//   chat(msg) / clipboard(text)
//   job_error / job_done / job_progress / folder_files / transfer_list /
//   confirm_delete / override_file_confirm / clear_all_jobs / load_last_job
//   block_input(on) / record_status(start) / screenshot / printer_request
//   voice_call_started / voice_call_waiting / voice_call_incoming / voice_call_closed
void ohos_ui_event(const char *json);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // RUSTDESK_OHOS_H
