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

// 核心版本号（"1.5.1"）。「关于」页显示用。调用方负责 rustdesk_ohos_string_free。
char *rustdesk_ohos_version(void);

// 进程内初始化，必须最先调用且只调一次。
// app_dir: 应用沙箱内的可写目录（ArkTS 的 context.filesDir）。
// 返回 0 成功。
int32_t rustdesk_ohos_init(const char *app_dir);

// 最近一次错误信息。调用方负责 rustdesk_ohos_string_free。
char *rustdesk_ohos_last_error(void);

void rustdesk_ohos_string_free(char *p);

// --- 连接配置（自建服务器）-------------------------------------------------

// 读取服务器相关配置（JSON）。调用方负责 rustdesk_ohos_string_free。形如：
// {"custom-rendezvous-server":"","relay-server":"","api-server":"","key":"",
//  "effective-rendezvous-server":"rs-ny.rustdesk.com:21116"}
// effective-* 是**实际生效**的地址（可能来自编译期内置的定制服务器）。
// 另外还带 "id"（本机 ID）和 "temporary-password"（一次性密码），首页卡片用。
char *rustdesk_ohos_config_json(void);

// 写入服务器配置。json 是对象，只认 custom-rendezvous-server / relay-server /
// api-server / key 四个键，其余忽略；值为空串表示删除该项（回到默认）。
// 返回 0 成功。
int32_t rustdesk_ohos_config_set(const char *json);

// --- 本机身份 / 最近会话（首页用）------------------------------------------

// 刷新一次性密码（首页卡片上的「刷新」）。
void rustdesk_ohos_update_temporary_password(void);

// 设置固定密码。传空串表示清除。返回 0 成功。
int32_t rustdesk_ohos_set_permanent_password(const char *pw);

// 最近连接过的对端，按最后连接时间倒序。调用方负责 rustdesk_ohos_string_free。
// 形如 [{"id":"123456789","ts":1730000000,"fav":false}, ...]，ts 是 Unix 秒。
char *rustdesk_ohos_peers_json(void);

// 收藏列表整体写回。json 是字符串数组，例如 ["123456789"]。返回 0 成功。
int32_t rustdesk_ohos_store_fav(const char *json_ids);

// --- 主控会话 -------------------------------------------------------------

// 连接远端。立即返回，结果通过 ui_event("connected"/"msgbox") 上报。
// peer_id: "123456789" 或 "123456789@server"，可带 "?key=..." 参数
// password: 预设密码，空串表示连接后再向用户索要
// force_relay: 非 0 表示强制中继
int32_t rustdesk_ohos_session_start(const char *peer_id, const char *password,
                                    int32_t force_relay);

void rustdesk_ohos_session_close(void);

// 提交登录凭据（密码弹窗的「确定」走这里）。username / os_password 通常传空串。
// remember 非 0 表示记住密码（存进该 peer 的 PeerConfig）。返回 0 成功；
// 没有活跃会话时返回 -2。
int32_t rustdesk_ohos_session_login(const char *username, const char *os_password,
                                    const char *password, int32_t remember);

// 回应「未加密连接」警告。accept 非 0 = 继续，0 = 取消。
// 上游会在建链后同步等待这个回话，不回就一直黑屏。没有活跃会话时返回 -2。
int32_t rustdesk_ohos_session_continue_insecure(int32_t accept);

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

// 输入一段文字（软键盘）。走 KeyEvent.seq 通道，逐字符注入，
// 不受两端键位布局影响，中文/符号也能用；空串直接返回 0。
int32_t rustdesk_ohos_text(const char *text);

int32_t rustdesk_ohos_switch_display(int32_t index);

// 代理设置（JSON），形如 {"proxy":"","username":"","password":""}。
// 代理不在 Config 的 options map 里，而是 Config2 的 socks 字段，
// 所以单独给一对读写接口。返回的 char* 由调用方释放。
char *rustdesk_ohos_proxy_json(void);

int32_t rustdesk_ohos_proxy_set(const char *json);

// 读 / 写单个配置项的原始值。key 必须在 UI 白名单内，否则返回空串 / 错误码。
// 返回的 char* 由调用方用 rustdesk_ohos_string_free 释放。
char *rustdesk_ohos_option_get(const char *key);

int32_t rustdesk_ohos_option_set(const char *key, const char *value);

// 读 / 写单个**本地**配置项（LocalConfig）。打洞开关等走这条路。
char *rustdesk_ohos_local_option_get(const char *key);

int32_t rustdesk_ohos_local_option_set(const char *key, const char *value);

// 当前生效 ID 服务器的连接状态：1=已连接（绿）、0=正在连接（黄）、-1=连接失败（红）。
// 由进程内一条后台看门狗线程持续探测并更新，本函数不阻塞，可随便从 UI 线程调。
int32_t rustdesk_ohos_server_status(void);

// --- 会话操作（Android 底栏 ⋮「更多」菜单）---------------------------------
//
// 这一组全是「发一条消息给 io_loop」，不等待结果，返回 0 只代表已入队。

// 锁定远端屏幕。
int32_t rustdesk_ohos_lock_screen(void);

// 重启远端设备。只有 Windows / Linux / macOS 对端支持，调用方先自行判断。
int32_t rustdesk_ohos_restart_remote(void);

// 把密码发到远端 OS 登录界面。activate 非 0 = 发完立刻回车。
int32_t rustdesk_ohos_input_os_password(const char *pw, int32_t activate);

// 请求提权：direct 用于已是管理员会话，with_logon 用于 UAC 要凭据。
int32_t rustdesk_ohos_elevate_direct(void);
int32_t rustdesk_ohos_elevate_with_logon(const char *username,
                                         const char *password);

// 会话录屏开关。start 非 0 开始，0 停止。会话不存在时 is_recording 返回 0。
int32_t rustdesk_ohos_record_screen(int32_t start);
int32_t rustdesk_ohos_is_recording(void);

// 翻转一个会话级开关（"block-input"、"show-remote-cursor"…）。
// 名字必须与上游 toggle_option 认的字面量一致，否则对端不认。
int32_t rustdesk_ohos_toggle_option(const char *name);

// 对端平台（"Windows" / "Linux" / "MacOS" / "Android"）。会话不存在返回空串。
// 菜单项可用性判断靠它。调用方负责 rustdesk_ohos_string_free。
char *rustdesk_ohos_peer_platform(void);

// 按 USB HID usage 发一个键（Android 被控端的音量键 / 电源键）。
// 只认这四个 usage，别的会被静默丢弃：
//   0x007f 静音 / 0x0080 音量+ / 0x0081 音量- / 0x0066 电源
// 必须成对调用：down=1 之后再 down=0，否则对端会一直「按住」。
int32_t rustdesk_ohos_hid_key(int32_t usb_hid, int32_t down);

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

// --- 被控端：远程协助（按需起停，不做常驻服务）------------------------------
//
// 与 ArkTS 的分工：UI 只管调这四个函数，状态机（是否在跑、采集有没有起）
// 全在 Rust 侧的 entry.rs。所有函数返回 0 成功 / 负数失败。
int32_t rustdesk_ohos_host_supported(void);   // 1 = 本机型可被控（2in1）
int32_t rustdesk_ohos_host_start(void);       // 起采集 + 注册 + 监听
int32_t rustdesk_ohos_host_stop(void);        // 断会话 + 停采集 + 撤授权
int32_t rustdesk_ohos_host_state(void);       // 0 停止 / 1 运行中

// 键鼠注入授权：0 未授权 / 1 授权中 / 2 已授权
int32_t rustdesk_ohos_injection_status(void);
int32_t rustdesk_ohos_request_injection(void);

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

// 注入授权状态：0=未授权 1=授权中（系统弹窗已出）2=已授权
// API < 20 的系统没有 OH_Input_RequestInjection，会一直返回 0。
int32_t ohos_input_query_authorized(void);
// 主动放弃注入授权（结束远程协助时调）。
void ohos_input_cancel_injection(void);

// 坐标一律用**全局屏幕像素**（左上角为原点），与主控端看到的帧坐标一致。
// button：0=左 1=中 2=右（与 OHOS MOUSE_BUTTON_* 同值）。
int32_t ohos_input_inject_mouse_move(int32_t x, int32_t y);
int32_t ohos_input_inject_mouse_button(int32_t button, int32_t down, int32_t x, int32_t y);
int32_t ohos_input_inject_mouse_wheel(int32_t x, int32_t y, float vertical);
// keycode 用 OHOS KeyCode（见 multimodalinput/oh_key_code.h）。
int32_t ohos_input_inject_key(int32_t keycode, int32_t down);

// --- 屏幕采集能力 ---------------------------------------------------------
int32_t ohos_capture_can_start(void);
int32_t ohos_capture_start(uint32_t display_id);
int32_t ohos_capture_stop(void);
// 采集是否仍在运行（1/0）。用于宿主守护线程在系统撤销授权后重起采集。
int32_t ohos_capture_is_running(void);

// 系统播放声（内部音频）。与画面同一次 AVScreenCapture 会话采集：
// PCM S16LE / 48kHz / 立体声，只取「整个系统播放」这一路（不含麦克风）。
// 数据先进 C++ 侧环形缓冲，Rust 的 audio_service 轮询取走后再做 Opus 编码。
int32_t ohos_capture_audio_available(void);  // 可读字节数
int32_t ohos_capture_read_audio(uint8_t *dst, int32_t cap);  // 返回实际字节数

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
