# RustDesk HarmonyOS 移植架构（ohos/main）

> 目标：**保留 Rust、最大化复用上游、手机与 2in1 通用、主控+被控、且上游更新可合并**。
> 本文件是这份 fork 的最高约束，任何实现与原冲突时以本文为准。

---

## 1. 四条硬约束与对应的设计答案

| 约束 | 设计答案 |
|---|---|
| 保留 Rust | 全部协议/加密/会话/文件传输沿用上游 `src/{client,server,rendezvous_mediator,...}`，仅新增平台后端 |
| 最大化复用上游代码 | 复用率按模块计（§5），**唯一重写的部分是 5 个平台后端**，协议层零改动 |
| 手机 + 电脑通用 | 同一 APK 用 `deviceType` 能力探测决定运行模式（§6），不做两套分支 |
| 上游可升级 | **生成式补丁**：对上游文件的修改不提交，构建时脚本自动施加（§3），`git diff upstream` 只有新增文件 |
| 主控 + 被控 | 主控走 `client.rs`；被控走 `server.rs` + 自研 `scrap::ohos` / `enigo::ohos` 后端 |

---

## 2. 仓库与分支模型

```
origin    = rustdesk/rustdesk          （只读，作为唯一上游）
ohos/main = 本分支                       （线性历史，只加新文件）

目录布局（★ = 新增，其余与上游完全一致）：
src/platform/ohos/          ★ 平台后端（mod.rs + ffi.rs）
src/ohos/                   ★ C ABI 导出层（供 NAPI 调用）+ host 生命周期
libs/scrap/src/ohos/        ★ 被控端采集器（接收 C++ 编码帧 → 喂上游 video_service）
libs/enigo/src/ohos/        ★ 输入注入后端（仅 2in1，调用 OH_Input）
scripts/ohos/               ★ 构建与同步脚本
docs/ohos/                  ★ 本文档
ohos-app/                   ★ ArkTS 工程（壳 + C++ NAPI，独立目录，不污染上游树）
```

**原则**：能新增就不修改；必须修改的（cfg 谓词）用脚本在构建时施加。

---

## 3. 三层补丁策略（核心机制）

### Tier 1｜新增文件（零冲突）
所有 OHOS 实现都在上面 ★ 目录里。上游改动这些区域的可能性接近 0。

### Tier 2｜生成式 cfg 补丁（不提交，构建时施加）
上游有 **330 处** `not(any(target_os = "android", target_os = "ios"))` 和 **96 处** `any(target_os = "android", target_os = "ios")`。
因为 `aarch64-unknown-linux-ohos` 的 cfg 是 `target_os="linux" + target_env="ohos"`，这些"非桌面"判断会把 OHOS 误判为桌面，导致编入 sciter/gtk/x11。

做法：`scripts/ohos/apply-mobile-cfg.py` 幂等地把 OHOS 加进这些谓词（426 处 / 30 文件），
**但不提交这些改动**——`git status` 永远干净，`git merge upstream/master` 永远无冲突。

```bash
python scripts/ohos/apply-mobile-cfg.py          # 构建前施加（build-core.sh 自动调用）
python scripts/ohos/apply-mobile-cfg.py --check  # CI 校验
```

### Tier 3｜必须的少量真修改（已提交，见 PATCH_INVENTORY.md）
仅 2 处、共 8 行：
1. `src/platform/mod.rs`：注册 ohos 模块 + 排除 linux 模块
2. `.cargo/config.toml`：追加 ohos 目标段（文件末尾，冲突概率极低）

**判定规则**：任何需要改上游逻辑的改动都必须先讨论——如果只能靠改上游逻辑实现，说明设计错了，应改为新增文件 + 适配器。

---

## 4. 构建体系（为什么是 Rust 静态库 + C++ NAPI）

```
ArkTS (UI/授权/生命周期)
   │ import from 'libentry.so'
   ▼
C++ NAPI 层（libentry.so）
   ├─ VideoRender：OH_VideoDecoder + XComponent Surface（解码/渲染只有 C 侧能做）
   ├─ AudioEngine：OH_AudioRenderer / OH_AudioCapturer
   ├─ CaptureAdapter：AVScreenCapture → OH_VideoEncoder（被控端）
   ├─ InputInjection：OH_Input_RequestInjection（被控端，仅 2in1）
   └─ napi threadsafe function（事件推送，替代轮询）
   │ C ABI（src/platform/ohos/ffi.rs 声明的同一份符号）
   ▼
librustdesk_core.a（cargo build --target aarch64-unknown-linux-ohos）
   └─ 上游协议/会话/加密/文件/剪贴板逻辑 + platform::ohos
```

**关键取舍**：不追求"纯 Rust"。ArkTS 拿不到 AVCodec 绑定，音视频必须在 C++；但**协议、会话、加密、输入事件语义、文件传输全部留在 Rust**，这才是"复用上游"的实质。

数据面铁律（沿用 2in1 审计结论）：
- 逐帧数据不经 ArkTS；Surface 零拷贝直连解码器
- 输出队列 ≤ 2 帧，拥塞丢旧帧
- 事件用 threadsafe function 推送，ArkTS 轮询仅作兜底

---

## 5. 模块复用率与对应关系（上游 ↔ 鸿蒙）

| 功能 | 上游文件 | 鸿蒙侧改动 | 复用率 |
|---|---|---|---|
| 协议编解码 | `src/protobuf/*`, `libs/hbb_common` | 无 | 100% |
| 打洞/中继 | `src/rendezvous_mediator.rs` | 无 | 100% |
| 主控会话 | `src/client.rs`, `client/io_loop.rs` | 替换 UI 回调（Interface trait 实现） | 90% |
| 被控会话 | `src/server/connection*.rs`, `service.rs` | 无 | 100% |
| 视频编码（被控） | `src/server/video_service.rs` | 新增 `scrap::ohos::Capturer` 接受 C++ 编码帧 | 70% |
| 视频解码（主控） | `libs/scrap/src/common/codec.rs` | 新增 OHOS 硬解 sink（C++ 侧） | 60% |
| 输入事件语义 | `src/input.rs`, `src/keyboard.rs` | 无（键值映射新增 ohos 表） | 95% |
| 输入注入（被控） | `libs/enigo` | 新增 `enigo::ohos`（OH_Input C ABI） | 40% |
| 文件传输 | `src/common.rs`, `src/client/file_trait.rs` | 新增沙箱路径适配（无 SAF，用 picker） | 85% |
| 剪贴板 | `src/clipboard.rs`, `libs/clipboard` | 新增 pasteboard 后端 | 50% |
| 音频（主控播放） | `src/client.rs` AudioHandler | C++ OH_AudioRenderer | 60% |
| 音频（被控采集） | `src/server/audio_service.rs` | C++ OH_AudioCapturer | 50% |
| 账户/地址簿 | `src/hbbs_http/*`, `auth_2fa.rs` | 无 | 100% |
| 桌面 UI | `src/ui/*` | 不移植（ArkTS 重写） | 0% |

**综合**：协议与业务层 ~95% 复用；平台后端（5 个）是全部工作量所在。

---

## 6. 手机与 2in1 的能力矩阵（同一 APK）

`platform::ohos::device_type()` 决定运行模式，UI 侧同步隐藏不可用入口。

| 能力 | 手机 / 平板 | 2in1 / PC | 实现路径 |
|---|---|---|---|
| 主控（控制别人） | ✅ | ✅ | 上游 client.rs |
| 被控-屏幕共享 | ⚠️ 每次弹隐私提示，用户可随时停止 | ✅ API22+ 可申请 CUSTOM_SCREEN_RECORDING 免提示 | AVScreenCapture |
| 被控-键鼠控制 | ❌ 平台无注入接口 | ✅ OH_Input_RequestInjection（用户弹窗授权） | enigo::ohos |
| 被控-无人值守 | ❌ | ⚠️ 待 AGC 与固件验证 | — |
| 文件传输 | ✅ | ✅ | 上游 + 沙箱路径 |
| 剪贴板 | ✅ | ✅ | pasteboard |
| 双向语音 | ✅ 麦克风 | ✅ | OH_AudioCapturer |

**红线**：手机形态被控一律降级为"仅观看"。任何通过系统漏洞绕过的实现都不做——这是合规要求，也是可持续性的前提。

---

## 7. 上游同步工作流

### 跟 tag，不跟 master

**同步目标只有发行 tag（`1.5.1` / `1.6.0` …），永不合 master 头。** 理由：

- master 上混着开发中的翻译、CI 调整、未合入的重构，跟它走等于把未发布的行为带进来；
- 对外需要一个能说清的版本对应关系 —— 应用内版本串 `0.1.0 (1.5.1) for HarmonyOS`
  里括号那个数字，就是选中的 tag（来自 `src/version.rs` 的 `VERSION`，合并后重编自动变）；
- 发版 tag 是上游自己验证过的状态，出问题也容易对照上游的 release note 定位。

一条命令走完（默认自动取最新发行 tag，也可显式指定）：

```bash
bash scripts/ohos/sync-upstream.sh            # 自动选最新 tag
bash scripts/ohos/sync-upstream.sh 1.6.0      # 指定 tag
```

脚本内部步骤：定位 tag → `merge --no-ff` → 重跑 `apply-mobile-cfg.py` →
aarch64 编译验证 → 打印补丁面体检与"关键依赖是否变动" → 提交。
若目标 tag 已在当前分支内，直接退出（幂等，可以随时跑）。

合并完成后还有两件手工事：`app.json5` 的 `versionName`/`versionCode` 与
`common/Version.ets` 的 `OHOS_APP_VERSION` 同步递增，然后重编 HAP 冒烟。

**冲突处理三原则**：
1. Tier-1 文件冲突 → 说明上游在同名路径加了文件，重命名我们的模块（如 `ohos/` → `ohos_next/`）后保留两者
2. Tier-3 少数几处冲突 → 按 PATCH_INVENTORY 的意图重打，非常小
3. 上游改了我们依赖的**函数签名**（如 `trait Service`）→ 只改 `src/platform/ohos` 或 `src/ohos` 内的适配，不改上游

**历史记录（别重犯）**：2026-11-01 曾试合 master 头（领先基线 9 个提交），
零冲突、核心也编过，但按产品口径**不采纳** —— 那 9 个提交当时都还没发版。

**体检口径**（`sync-upstream.sh` 会打印，人工判断）：
- `git diff --cached --stat <tag> -- src libs Cargo.toml .cargo` —— 增量应只出现在
  PATCH_INVENTORY 列出的那批文件里；
- 上游若动了 `nix` / `socket2` / `rdev` / `tokio-native-tls` 版本，`ohos/third_party/`
  下的 vendored 副本要重新 vendor，这是历史上最容易破的一处；
- 上游若改了 `libs/scrap` 的 `Capturer` trait 或 `video_service` 接口，鸿蒙采集后端要跟着改。

---

## 8. 里程碑

| 阶段 | 交付 | 验收 |
|---|---|---|
| **M0 编译地基** ✅ | Rust 目标可用，`cargo check` 通过 core 子集 | `librustdesk.a` 产出，`rustdesk_ohos_*` 导出符号存在 |
| **M1 主控打通** ✅ 代码闭合，待真机 | Rust 会话 + C++ 胶水层 + ArkTS UI 全部落地 | 真机连 Windows 出画面，延迟 <200ms |
| **M2 主控功能** | 文件传输、剪贴板、多屏、画质调优 | 与 Flutter 版功能对照表 ≥80% |
| **M3 被控（2in1）** | Capturer + enigo::ohos + host 生命周期 | 标准 RustDesk 主控端可连入并操作 |
| **M4 手机被控（只读）** | 屏幕共享 + 权限降级 | 手机共享屏幕，控制入口隐藏 |
| **M5 质量** | 长稳/断线重连/安全边界 | 2h 会话无泄漏，权限撤销 1s 内 fail-closed |

### 8.1 M1 的分层实现

四层都已落地，逐层可独立验证：

| 层 | 文件 | 职责 |
|---|---|---|
| C ABI 导出 | `src/platform/ohos/entry.rs` | 19 个 `rustdesk_ohos_*`：init / 会话 / 帧 / 输入 / 采集 |
| 会话 | `src/platform/ohos/session.rs` | 造 `Session<OhosUiSession>` 并跑上游 `io_loop`（单会话） |
| UI 适配 | `src/platform/ohos/ui_handler.rs` | 实现 `InvokeUiSession` 48 个方法；帧槽 + JSON 事件 |
| C ABI 导入 | `src/platform/ohos/ffi.rs` | 19 个 `ohos_*`，由 C++ 实现 |
| C++ 实现 | `ohos-app/entry/src/main/cpp/ohos_abi.cpp` | 那 19 个的实体（hilog / DisplayManager / DeviceInfo / 降级实现） |
| napi 边界 | `ohos-app/entry/src/main/cpp/napi_bridge.cpp` | 16 个 JS 函数 + threadsafe function 派发事件 |
| 渲染 | `ohos-app/entry/src/main/cpp/renderer.cpp` | XComponent Surface 渲染循环 |
| ArkTS | `ohos-app/entry/src/main/ets/` | 连接页、会话页、手势换算、键名映射 |

契约头文件：`ohos/include/rustdesk_ohos.h`（两个方向的完整声明 + 事件名清单）。

**帧的传递模型**（照搬 `flutter::FlutterHandler::on_rgba_soft_render` 的槽语义，
但**终点不同**：不是交给 ArkTS，而是 C++ 直接写 Surface）：

```
video_service ──on_rgba(&mut ImageRgb)──▶ 帧槽（mem::swap，零拷贝）
                                             │ valid=true
              C++ 渲染线程 ──frame_acquire──▶ 拿裸指针
                          ──mmap/memcpy──▶ Surface buffer
                          ──flush + frame_release──▶ valid=false，旧缓冲换回管线复用
```

`valid == true` 期间新帧被丢弃（背压），所以渲染循环**每条返回路径**都必须
release，否则画面会停在第一帧——这是唯一的使用约束。

为什么不让 ArkTS 拿帧去画：1080p 一帧 8MB，走 napi 传 ArrayBuffer 每帧一次
跨语言拷贝，30fps 就是 250MB/s，手机上直接卡死。因此 `rgba` 事件在
`ohos_abi.cpp` 的 `ohos_ui_event` 里被直接丢弃，省掉每帧一次线程切换。

**事件通道**：所有 UI 回调序列化成 `{"event":..., "data":{...}}` 交给
`ohos_ui_event`，由 C++ 用 napi threadsafe function 切到主线程。
另外 `rustdesk_ohos_state_json()` 提供「电平触发」的状态快照，
供页面重建后恢复 UI（只靠事件会丢状态）。

**缓冲尺寸的取舍**：buffer geometry 取**帧**尺寸而非 Surface 尺寸，
memcpy 因而是一次行对行大拷贝；ArkTS 把 XComponent 的宽高比设成帧的宽高比，
合成器缩放后不变形。反过来用 Surface 尺寸建 buffer 就得在 CPU 上做软件缩放，
1080p 每帧几十毫秒，不可行。

### 8.2 M1 剩余：真机验证

代码侧已闭合（`cargo check` 零错误、C++ 三文件 `-Wall -Wextra` 零警告、
19 个 `ohos_*` 全部有实现），剩下的是需要真机才能做的部分：

1. DevEco 里配签名、跑起来，确认 `hilog` 出现
   `XComponent registered` → `surface created` → `render loop enter`。
2. 连一台 Windows，确认出画面、触摸/键盘生效，测延迟。
3. 依据实测调 `kIdleSleepMs`（当前 8ms）和背压行为。

### 8.3 已知缺口（不是 bug，是有意留空）

| 功能 | 现状 | 原因 |
|---|---|---|
| 剪贴板 | `ohos_clipboard_*` 返回空/-1 | OH_Pasteboard 走 UDMF，且读要 `ohos.permission.READ_PASTEBOARD`（system_basic + ACL）。返回半截数据比返回空更危险（双向同步会覆盖远端剪贴板）。M2 改走 ArkTS 侧 `@ohos.pasteboard` |
| 用户名/锁屏状态 | 返回空串 / 未锁定 | account、screenLock 都是系统 API，普通应用拿不到 NDK 接口 |
| 指针位置 | `ohos_cursor_pos` 返回 -1 | OHOS 无「读全局指针坐标」的 NDK；`OH_Input_GetMouseEvent` 是注入用的构造器，不是状态查询 |
| 输入屏蔽 | 只记日志 | 无全局输入拦截 NDK，`block_input` 在 OHOS 上无法真正生效 |
| 屏幕采集 | ✅ 已接 AVScreenCapture（M3） | 见 8.4；模拟器媒体服务不产生帧回调，需 2in1 真机验证 |
| 键鼠注入 | ✅ 已接 OH_Input（M3，仅 2in1） | 见 8.4 |
| 被控端音频 | ✅ 系统播放声（`OH_ALL_PLAYBACK`） | 麦克风未开（要录音隐私授权），见 8.4 |

这些偏差都写进了对应函数的注释里，改的时候按注释里给的路径走。

### 8.4 被控（M3，临时远程协助）实现要点

不装常驻服务：用户在「共享屏幕」页打开开关 → 应用进程内起采集 + 注册 + 监听，
关掉即全部拆掉。几条踩过的坑，改代码前先读：

| 主题 | 结论 |
|---|---|
| 取帧方式 | 必须用 `SetCallback` + `AcquireVideoBuffer` 拉取模式。`SetDataCallback` 推送模式不暴露 stride，真机缓冲区按 64 字节行对齐，按 `width*4` 紧凑解析会整幅错位（花屏） |
| fence fd | **不要自己 `close(fence)`**。系统在 `ReleaseVideoBuffer` 时统一回收，双重关闭会误杀复用后的 fd（表现为连接反复断、tokio epoll `EBADF` 闪退） |
| 音频取数 | `AcquireAudioBuffer` 要求调用方**先提供 `OH_AudioBuffer` 结构体**再传其地址；传空指针会被 `#906` 拒绝（采集回调照常触发但一帧也拿不到） |
| 音频格式 | S16LE / 48k / 立体声，与 Opus 参数一致；Rust 侧按整 10ms 块取（Opus 只接受固定帧长），`s16 → f32` 后编码 |
| 音频降级 | 先试「画面+声音」，`Init`/`Start` 失败自动退回纯画面 —— 音频不能拖垮被控链路 |
| 身份稳定 | **ID 持久化**（`Config::get_id`）：重连/重启后地址不变。**一次性密码不落盘**：只在进程内存里，退出即换；且被成功使用一次后立刻更换（`connection::validate_password` → `entry::note_temporary_password_used`）。需要「断线后仍可用原口令重连」的场景走固定密码。老版本残留的 `ohos_temporary_password` 文件会在启动时删除 |
| 断线重连 | ① 状态看门狗发现「服务器不可达→可达」且远程协助开着 → 立刻 `RendezvousMediator::restart()` 重注册（不等 18s 超时），不关已有会话；② 宿主守护线程每 2s 巡检，`start_server` 线程退出或采集被系统回收时按 2s→30s 退避自动拉起 |



---

## 9. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| openssl vendored 无法交叉编译 | 阻塞编译 | 优先切 rustls；不行则用 OHOS 自带 libssl |
| 上游 426 处 cfg 补丁随版本漂移 | 构建失败 | 脚本幂等 + CI --check，失败时人工补规则（只改脚本） |
| 无线程安全事件通道 | 延迟高 | C++ threadsafe function；Rust 侧暴露 callback 注册 |
| 被控端 AGC 受限权限审核 | 无法上架 | 先个人侧载（debug Profile），商用再走 AGC |
| 上游大改（如切换到新 UI 框架） | 适配层失效 | 只依赖协议层与 Service trait，不依赖 UI |

---

## 10. 双架构构建（arm64-v8a + x86_64）

DevEco 模拟器是 **x86_64**，真机/2in1 是 **arm64-v8a**。安装包 ABI 不匹配会报
`code:9568347 / install parse native so failed`。故 native 栈两套并存，
`ohos-app/entry/build-profile.json5` 的 `abiFilters` 同时含两者。

### 10.1 架构映射

| DevEco `OHOS_ARCH` | Rust target | sysroot 子目录 | libsodium 链接目录 |
|---|---|---|---|
| `arm64-v8a` | `aarch64-unknown-linux-ohos` | `ohos/sysroot/aarch64` | `ohos/sodium-link-aarch64` |
| `x86_64` | `x86_64-unknown-linux-ohos` | `ohos/sysroot/x86_64` | `ohos/sodium-link-x86_64` |

`CMakeLists.txt` 按 `OHOS_ARCH` 自动推导，两套产物互不覆盖。

### 10.2 构建顺序（每个架构各一遍）

```bash
# 1) 三方 C 库
bash ohos/build-libs-x64.sh          # x86_64；ONLY=vpx 可单步重跑
sh   ohos/build-libsodium.sh         # aarch64 侧的 libsodium（其余原脚本）

# 2) Rust 静态库
OHOS_TARGET=aarch64-unknown-linux-ohos bash scripts/ohos/build-core.sh release
OHOS_TARGET=x86_64-unknown-linux-ohos  bash scripts/ohos/build-core.sh release

# 3) 交给 DevEco 构建（自动按 abiFilters 跑两套 CMake）
#    手动复现链接：
cmake -G Ninja -DOHOS_STL=c++_shared -DOHOS_ARCH=x86_64 -DOHOS_PLATFORM=OHOS \
      -DCMAKE_TOOLCHAIN_FILE=<NDK>/build/cmake/ohos.toolchain.cmake \
      ohos-app/entry/src/main/cpp && ninja
```

### 10.3 x86_64 专有的坑（都已修，改动记录在此避免重犯）

| 现象 | 根因 | 处理 |
|---|---|---|
| `nix` 编译失败：`cannot find function getcontext` | vendored nix 的 `ucontext` 模块只在 x86/x86_64 上编译，而 ohos(musl) 的 libc 没有该函数 | `not(target_env = "ohos")` 排除该模块 |
| `... is incompatible with elf_x86_64`（libvpx） | out-of-tree 构建靠 vpath 复用了源码树里 aarch64 时代的 `.o` | 构建前 `find . -name '*.o' -delete` |
| `undefined symbol: vpx_convolve8_vert_neon` | 源码树残留 in-source 生成的 `*_rtcd.h`（ARM 配置，含 NEON 声明），`#include` 优先命中它 | 一并删除 `vp8/vp9/vpx_dsp/vpx_scale_rtcd.h` |
| vpx `make install` 只打印 `[INSTALL]` 不落盘 | msys2 make + dash 下 install 内部逻辑失效 | 显式 `cp libvpx.a $PREFIX/lib/` |
| libsodium 链接期 `undefined symbol: ..._sandy2x_implementation` / `..._xmm6_implementation` | `--disable-asm` 关掉了汇编实现，但运行时分发仍引用 | 开启 asm；libtool CPPAS 在 msys2 建不了临时文件 → 手工编译 `salsa20_xmm6-asm.S`、`sandy2x.S` 并写 `.lo` 桩 |
| `rtcd.pl` 产出 0 字节头文件 | shebang `#!/usr/bin/env perl`，perl-root 里没有 `env.exe` | 把 Git Bash 的 `env.exe` 拷进 `ohos/tools/perl-root/usr/bin/` |
| aom 报 `Unsupported nasm` | nasm 3.x 的帮助文本不再列 `-Ox` | 补丁 `aom_optimization.cmake` 放行 NASM 3.x |

工具链准备（msys2 make/nasm/perl-root）见 `ohos/tools.README.md`。

### 10.4 验证基线

| 架构 | librustdesk.a | libentry.so | 检查 |
|---|---|---|---|
| arm64-v8a | 225 MB | 58 MB，ELF64 AArch64 | `--no-undefined` 通过 |
| x86_64 | 223 MB | 61 MB，ELF64 x86-64 | 无第三方未定义符号（仅 napi/hilog 等系统符号 + zstd 弱符号） |

### 10.5 Debug / Release 与 Rust profile 的对应

DevEco 的 **Debug** 配置也会调用同一个 `CMakeLists.txt`（`CMAKE_BUILD_TYPE=Debug`），
但 Rust 库只按 release 构建（debug 的 `.a` ~648MB，链接易 OOM，且性能差）。

选择顺序：

1. `-DRUSTDESK_PROFILE=debug|release` 显式指定时优先；
2. 否则依次尝试 `release` → `debug`，取第一个存在的 `liblibrustdesk.a`；
3. `-DRUSTDESK_LIB=/abs/path` 时从路径反推 profile（保证 kcp/ring/zstd 等
   build-script 产物取自同一 profile 目录）；
4. 都不存在才 `FATAL_ERROR`，并把尝试过的路径列出来。

configure 阶段会打印 `RustDesk: OHOS_ARCH=... target=... profile=...`，
一眼能看出用的是哪套。注意 CMake 的 `message()` 在 hvigor 日志里会按 GBK 解码，
**中文字符串会乱码**，所以本文件的报错文案统一用英文。
