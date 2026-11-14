# RustDesk for HarmonyOS —— DevEco 工程

这是鸿蒙侧的**壳**：ArkTS 界面 + C++ 胶水层，真正的 RustDesk 核心是仓库根目录
那个 Rust 工程编译出来的 `liblibrustdesk.a`。

```
ohos-app/
├── entry/src/main/
│   ├── cpp/
│   │   ├── CMakeLists.txt      链 librustdesk.a + 系统库
│   │   ├── ohos_abi.cpp        实现 Rust 需要的 19 个 ohos_*（hilog/display/deviceinfo…）
│   │   ├── napi_bridge.cpp     napi 导出 + 事件派发（threadsafe function）
│   │   ├── renderer.cpp        XComponent Surface 渲染循环（帧直写，不过 ArkTS）
│   │   └── types/libentry/     index.d.ts，ArkTS 侧的类型契约
│   ├── ets/
│   │   ├── common/RustDesk.ets napi 封装 + 事件总线
│   │   ├── common/KeyMap.ets   KeyCode → RustDesk 的 VK_* 键名
│   │   ├── pages/Index.ets     连接页
│   │   └── pages/SessionPage.ets 会话页（XComponent + 手势）
│   └── module.json5
└── build-profile.json5
```

C ABI 契约在 **`../ohos/include/rustdesk_ohos.h`**（Rust 与 C++ 共用同一份，
不要在这里复制第二份）。

## 数据流

```
              ┌──────────── 视频 ────────────┐
Rust video_service ──on_rgba(mem::swap)──▶ 帧槽
                                            │
                    renderer.cpp 线程 ──acquire/mmap/memcpy/flush──▶ XComponent Surface
                                            │
                                        release（背压：不 release 画面就停）

              ┌──────────── 输入 ────────────┐
ArkTS 手势/键盘 ──napi──▶ rustdesk_ohos_mouse/_key ──▶ io_loop ──▶ 远端

              ┌──────────── 状态 ────────────┐
Rust ui_handler ──JSON──▶ ohos_ui_event ──tsfn──▶ ArkTS onEvent
```

**帧为什么不过 ArkTS**：1080p 一帧 8MB，走 napi 传 ArrayBuffer 每帧一次跨语言
拷贝，30fps 就是 250MB/s，手机上直接卡死。所以 C++ 自己从帧槽取、自己写 Surface。

**事件为什么只有一条通道**：Rust 的 `InvokeUiSession` 有 48 个方法，一个方法一个
回调就要 48 个 threadsafe function 和 48 个上下文对象。统一成
`{"event":..,"data":..}` 后，C++ 只需要一次线程切换。

## 构建

### 前置

| 项 | 要求 |
|---|---|
| DevEco Studio | 5.0 及以上（工程按 API 12 语法写，本机验证用 API 26 SDK） |
| SDK | `C:/ohos-sdk/default/openharmony/native`（或你自己装的路径） |
| Rust | `rustup target add aarch64-unknown-linux-ohos` |
| 签名 | 必须配，否则装不上真机 |

### 第一步：编 Rust 静态库

```bash
bash scripts/ohos/build-core.sh release
# 产物：target/aarch64-unknown-linux-ohos/release/liblibrustdesk.a
```

**必须用 release**。debug 的 `.a` 有 648MB，DevEco 链接时会吃掉几个 G 内存，
基本必失败。

脚本还会顺带做两件事：施加 `apply-mobile-cfg.py` 的 cfg 补丁（Tier-2，不提交）、
准备 libsodium 的宿主/目标双份链接目录。

### 第二步：打开工程

DevEco Studio → `File > Open` → 选 `ohos-app/` 目录。

首次打开有两处要按你本机情况改：

1. **`build-profile.json5` 的 SDK 版本**
   ```json5
   "compatibleSdkVersion": "6.0.0(26)",   // ← 改成你装的版本，例如 "5.0.5(17)"
   "targetSdkVersion": "6.0.0(26)",
   ```

2. **Rust 库路径**（一般不用改）
   CMakeLists 会按 `../../../../..` 反推出仓库根，再用
   `target/aarch64-unknown-linux-ohos/{release|debug}/liblibrustdesk.a`。
   如果你的产物在别处，加一行：
   ```json5
   "buildOption": {
     "externalNativeOptions": {
       "arguments": "-DRUSTDESK_LIB=/abs/path/liblibrustdesk.a"
     }
   }
   ```

### 第三步：配签名

`File > Project Structure > Signing Configs` → 勾 `Automatically generate signature`。
需要登录华为账号。

### 第四步：跑

连真机 → Run。日志过滤 `RustDesk`：

```bash
hdc shell hilog -T RustDesk
hdc shell hilog -T RustDeskNapi
hdc shell hilog -T RustDeskRender
```

按这个顺序出现说明链路通了：

```
RustDeskNapi: XComponent registered
RustDesk: 设备形态 / core initialized, abi=1     ← ArkTS 侧
RustDeskRender: surface created 1080x2340
RustDeskRender: render loop enter
```

## 当前边界（M1）

已经通了：

- 主控连接（`session_start` → `io_loop` → 解码 → 出画面）
- 触摸手势 → 鼠标（单击 / 拖动 / 长按右键 / 双指滚轮）
- 物理键盘 → VK 键名（2in1 或接外接键盘）
- 状态事件（connected / close / display / block_input）

明确**没有**做的，别误以为坏了：

| 功能 | 状态 | 原因 |
|---|---|---|
| 剪贴板同步 | 空实现 | 要走 UDMF + `ohos.permission.READ_PASTEBOARD`（system_basic，需 ACL），M2 |
| 软键盘输入 | 未接 | 需要在会话页加隐藏输入框，M2 |
| 文件传输 | 事件已上报，UI 未做 | M2 |
| 被控端（手机共享屏幕） | `ohos_capture_can_start()` 返回 0 | 要接 AVScreenCapture，M3 |
| 2in1 键鼠注入 | 能力查询已实现，注入未接 | 要 `ohos.permission.INJECT_INPUT_EVENT`（需 ACL），M3 |
| 多显示器切换 | `switchDisplay` 已导出，UI 未做 | M2 |

## 排错

**`找不到 Rust 静态库`**
先跑第一步。CMake 会把期望路径打出来。

**`undefined symbol: ohos_xxx`**
说明 `ohos_abi.cpp` 没被编进来，或者你删掉了某个实现。19 个 `ohos_*` 全在
那个文件里，一个都不能少。

**画面出来了但不动**
`frame_release` 没被调。渲染循环的每条返回路径都必须 release，否则 Rust 侧
背压会把后续帧全丢掉。

**画面静止时 CPU 也不高，但一动就花屏**
可能是 `SET_BUFFER_GEOMETRY` 用的尺寸与帧尺寸不一致。见 renderer.cpp 里
"buffer 的几何尺寸取帧尺寸"那段注释。

**点不准**
XComponent 的尺寸必须等于 `displayW()/displayH()`（按远端宽高比算出来的），
不能直接 `width('100%')`。否则 Surface 被拉伸，坐标换算就偏。

---

## ⭐ OHOS 平台判定与资源探测必查（2026-11-11 全项目强制）

> 本节是**跨项目强制条款**，源自 PhotoCraft v0.22.0 的严重缺陷「打开照片报内存不足，只有很小的图片能打开」。
> 权威版见《craft-鸿蒙移植通用检查清单》文首 ⭐ 铁律与 §18。新项目开工、每次上游升级后必须逐项打勾。

**一眼判据**：编译、链接、启动全绿，只有稍大的数据失败，且报错里出现 `0.0 GB is free`、
`0 bytes available`、`0 cores`、`limit 0` 这类**零值** → 先怀疑「资源探测器读不到 → fail-closed 返回 0」，
不要当成真的资源不足，也不要先猜「文件太大 / ArkTS 缓存 / fd 读取」。

**根因**：OHOS triple（`*-unknown-linux-ohos`）仍报告 `target_os = "linux"`。上游凡靠
`#[cfg(target_os = "linux")]` 分派的 Linux 专属逻辑（cgroup / procfs / 内存探测 / 字体路径 / `dlopen` /
系统目录）在鸿蒙应用沙箱里都会被误用。PhotoCraft 的通用 Linux 探测器要求 cgroup v1 挂载带 `memory`
controller 名，而 OHOS 把 memory 控制器挂在 `/dev/memcg`、`mountinfo` 不含 controller 名，应用进程读
`/dev/memcg` 与 `/proc/<pid>/root/sys/fs/cgroup` 均为 `Permission denied`；探测器因此返回
`available_ram = Some(0)`，图片导入准入 `check_fits()` 把每张稍大的照片判成内存不足，真机报错原文是
`not enough memory to open this 6000 × 4000 px image: it needs about 0.1 GB and 0.0 GB is free`
（该设备 `/proc/meminfo` 实际有约 22.2 GiB 可用）。

**本项目自检清单（开工 / 每次上游升级后）**：
- [ ] `grep -rn 'target_os = "linux"\|cfg(unix)' <上游>/crates`，逐个判断平台假设在 OHOS 沙箱里是否成立；重点查「读取系统资源上限」类代码（内存、CPU、磁盘、cgroup、rlimit）。
- [ ] OHOS 专用分支只用 `#[cfg(target_env = "ohos")]`；真正的 Linux 分支写成 `#[cfg(all(target_os = "linux", not(target_env = "ohos")))]`，且 OHOS 交叉编译不得有该模块的 dead_code 警告。
- [ ] 探测器「测不到」必须返回 `UNKNOWN`（让上游走未知资源的保守策略），**绝不返回 `Some(0)`**。
- [ ] 只用沙箱真正可读的数据源（`/proc/meminfo` 的 `MemAvailable`），按单应用口径保守封顶；不要把整机 RAM 原样交给单个任务；由系统管理的 swap/zram 记 0。
- [ ] 平台修复做成独立 numbered patch + `target_env = "ohos"` 分支 + `#[cfg(any(target_env = "ohos", test))]` 的主机可跑纯函数单测，保证上游升级只冲突一个 hunk。
- [ ] 真机前后对照：构造「文件小、解码内存大」的样本，先在旧包复现报错，再 `hdc install -r -d` 覆盖安装验证；不能只跑 `cargo check` / 单测就宣布修好。

> 出处（MLA）：「⭐ OHOS 平台判定与资源探测铁律」与「§18. PhotoCraft 追加经验」，
> *craft-鸿蒙移植通用检查清单.md*, 本地工作区 `C:/Users/mingh/WorkBuddy/2026-11-01-23-18-01/`,
> 11 Nov. 2026. 修复实例见 PhotoCraft `patches/0005-ohos-memory.patch` 与
> `upstream/photocraft/crates/raster/src/memory/system.rs`。

---

## ⭐ 关窗保存确认必查（2026-11-11 全项目强制）

> 本节是**跨项目强制条款**，源自「点系统窗口 X / 返回手势不弹『是否保存』对话框、未保存改动静默丢失」
> 这一**数据丢失级缺陷**。权威版见《craft-鸿蒙移植通用检查清单》文首 ⭐ 关窗保存确认铁律（12 项）、
> §8、§15 / §15.1 / §15.2 与 §19 全项目落地登记。新项目从骨架阶段、每次上游升级后按序打勾。

**为什么最容易漏**：关闭链路跨 ArkTS 拦截层、Rust 逻辑相帧顺序、上游「允许关闭」信号三层，
任一层缺失都能编译通过、正常启动、hilog 甚至全绿，但点 X 就是不弹框。VectorCraft v0.23.0
连续修了两次才闭环——首版只接通道，用户复测仍是「直接关掉、不弹框」。

**现象 → 断点速判**：点 X 直接退出且无日志 → ArkTS 没订阅窗口级关窗事件；
拦到了却静默关窗 → Rust `tick` 在 `run_ui` pass 外 / 「无 CancelClose」被误判成「无未保存」；
弹框但选完保存或丢弃窗口不关 → 没锁存本上游的允许关闭信号；
框根本画不出来 → 关窗时窗口失焦、`active=false` 让 Frame 分支提前返回。

**本项目必查清单（骨架 → 交付，缺一项不算闭环）**：
- [ ] **1. 先查本上游用什么表达「可以关窗」，绝不照抄兄弟工程字段**：
      `grep -rn "close_requested\|allow_close\|quit_requested\|ui.status\|CancelClose\|quit_confirmed" <上游>/apps <上游>/crates`。
      GridCraft 用 `SheetApp::allow_close`；WordCraft 用 `close_requested()` + `quit_requested`；
      VectorCraft 没有 `allow_close`，靠 `unsaved::close_all(app, "quit")` 写 `app.ui.status = "quit"`；
      FilmCraft / DeckCraft 用 `intercept_quit()` 发 `CancelClose`，作答后 `quit_confirmed` + `Close`。
- [ ] **2. ArkTS 只订阅一个窗口级关窗事件**：`EntryAbility.onWindowStageCreate` 里
      `getMainWindowSync().on('windowWillClose', async (): Promise<boolean> => …)`。SDK 26 契约：
      `return true` = 拦截（窗口保留）、`false` / reject = 放行；写成同步 `(): boolean` 会报
      `10505001 No overload matches this call`。别同时注册 `windowStageClose` / `onPrepareToTerminate`
      （优先级冲突，见 §8）；WordCraft 的 `windowStageClose` 是另一套已验证写法，照抄前先核 SDK 声明。
- [ ] **3. 回调内直连、无条件拦截**：`native.close(); return true;`，**不要** `closeGuard.ets` 那种跨模块
      单例回调（多一层「两文件是否共享同一模块实例」的不确定性，见 §15.2）。Rust 确认后由页面
      `receive('close')` → `terminateSelf()`，该路径不会再触发 `windowWillClose`，无需「已确认放行」标志。
- [ ] **4. 返回手势也要消费**：`onBackPress()` 转发 Escape（键码 2070）并 `return true`，
      否则返回手势直接销毁页面，同样绕过未保存确认。
- [ ] **5. 头号根因：Rust `editor_frame` 把 `tick` / `finish_ime_logic` 放进 `ctx.run_ui` 的 pass 内、
      `ui()` 之前**，用 `current_pass_index() == 0` 防多 pass 重复。只要上游 logic 读 `ctx.input()`
      （`close_requested` / `focused` / zoom / viewport）就必须如此：pass 外只能读上一帧 input，
      `ViewportEvent::Close` 当帧不可见 → 上游不发 `CancelClose` → 宿主误判「无未保存」→ 静默关窗（§15.1）。
      对照物：eframe `App::logic`、web shell `logic`、GridCraft `editor_frame` 三者顺序一致。
- [ ] **6. 关窗判定不能反向推断**：`CancelClose` 优先暂缓（等用户作答）；**绝不**把「本帧没有
      `CancelClose`」当成「无未保存」直接 Confirm；锁存第 1 项查到的允许关闭信号后放行一次，
      加 `terminating` 防重复 `notify("close")`。用户点 Cancel 时上游不发信号、窗口自然保留。
- [ ] **7. 关窗期间强制出帧**：`Message::Close` 里 `active = true; bridge::resume()`，
      Frame / vsync 请求 / repaint 排帧的 active 判断在校验期间放行（`active || close`）。
      否则系统 X 先触发 `onBackground → active(false)`，保存框永远画不出来。
- [ ] **8. 三段诊断日志**：`system X forwarded` → `saveChanges pending, window kept` →
      `confirmed, notifying host`（Rust `bridge::notify(0,"diagnostic",…)` + ArkTS `console.info`），
      真机点一次 X 就能从 hilog 读出全链路，无需合成输入。
- [ ] **9. 构建与包内校验**：`cargo check` → 双 ABI release → `assembleHap` → 包内 ArkTS 字节码含
      `windowWillClose`、`.so` 含三段诊断文案 → `hdc install -r -d` 覆盖安装；别只改源码就宣布修好。
- [ ] **10. 真机三态人工验收不可省**：制造未保存改动 → 点 X → **亲眼看到**「是否保存」框；
      分别试 Save / Don't Save / Cancel，前两者应出现 `confirmed, notifying host` 且窗口关闭，Cancel 保留。
- [ ] **11. 验收判据写进移植报告**：`RegisterListener: [windowWillClose, 1]` 只证明**监听器注册**，
      **不等于修好**；必须有用户真机点 X 的实证日志 / 截图才算闭环。VectorCraft 首版正是栽在这里。
- [ ] **12. 多窗口 2-in-1 设备不发合成点击**：合成点击会被误路由并改动邻窗
      （VectorCraft 曾在 GridCraft 单元格误写 `7`），此项一律请用户手点。

> **升级 / 回归**：上游大版本升级可能改宿主帧顺序或允许关闭字段名，按第 1、5、6 项重新 `grep`，
> 再跑一次第 10 项三态验收。
>
> 出处（MLA）：「⭐ 关窗保存确认铁律」与「§15. 关窗保存守卫」，
> *craft-鸿蒙移植通用检查清单.md*, 本地工作区 `C:/Users/mingh/WorkBuddy/2026-11-01-23-18-01/`,
> 10–11 Nov. 2026.
