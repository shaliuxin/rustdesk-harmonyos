# 补丁清单（Tier-3：唯一提交到 git 的上游修改）

> 规则：本文件列出的每一处都必须能说明"为什么不能靠新增文件解决"。
> 新增任何条目需在 PR 描述里给出理由。Tier-1/Tier-2 不在此列。
>
> 当前状态：`cargo check --target aarch64-unknown-linux-ohos --lib` **零错误通过**（M0 达成）。

## 一、真正的上游语义修改（Tier-3）

| # | 文件 | 改动 | 行数 | 原因 | 上游冲突概率 |
|---|---|---|---|---|---|
| 1 | `src/platform/mod.rs` | 注册 `ohos` 模块；把 `linux` / `gtk_sudo` 的 cfg 加上 `not(target_env = "ohos")` | 11 | 平台选择必须在编译期发生，无法用新增文件绕开 | 低（该文件极少改动） |
| 2 | `.cargo/config.toml` | 文件末尾追加 `[target.aarch64-unknown-linux-ohos]` 与 `[env]` 段（ar / clang / sysroot / pkg-config / bindgen 参数） | 17 | 交叉编译工具链配置只能放这里 | 低（追在末尾） |
| 3 | `Cargo.toml` | ① `scrap` / `hbb_common` 从 `[dependencies]` 移到按目标分流的 `[target.'cfg(...)'.dependencies]` 段；② `[patch.crates-io]` 增加 `tokio-native-tls` / `socket2` / `nix` / `tungstenite` / `webrtc*` 等；③ `exclude` 增加 `ohos/` 下的 vendored crate | 25 | WebRTC 链路（`webrtc-util 0.11 → nix 0.26.4`）在 OHOS 上报 51 个 libc 类型错误，无法在新文件里解决；feature 与 patch 只能在此声明 | 中（上游若改动这两行依赖） |
| 4 | `build.rs` | 把 `#[cfg(windows)]` / `cfg!(windows)` 换成 `CARGO_CFG_TARGET_OS == "windows"` 判断 | 9 | build script 由**宿主** rustc 编译，`cfg(windows)` 判断的是宿主而非目标；Windows 宿主交叉编译到 OHOS 时会误编 `windows.cc`。这是上游的真实 bug | 低 |
| 5 | `Cargo.lock` | 随 3 自动更新 | — | 锁文件必须与 patch 段一致 | 中（上游任何依赖变更都会冲突，直接 `git checkout --theirs` 后重跑 `cargo update -p` 即可） |

## 二、含 Tier-1 手工代码的上游文件（"混合文件"）

以下文件既有脚本生成的 cfg 改写，也有手写的鸿蒙实现。Tier-1 代码不能丢，
因此这些文件**整体提交**，其中的谓词改写随之入库——脚本幂等，merge 后重跑无害。

| 文件 | 手写内容 |
|---|---|
| `src/server.rs` | `input_service` 空壳（6 个函数）+ `pub(crate) mod wayland` 空壳；鸿蒙不需要 `enigo`/`xdo`/`uinput`/门户 |
| `src/platform/ohos/mod.rs` | `linux_compat` 注册 + `ohos::linux` 别名模块 |
| `src/platform/ohos/linux_compat.rs` | 新增文件，见「三」 |
| `libs/scrap/src/lib.rs` | `cfg(target_env = "ohos")` 的 `android` / `wayland` 同名兼容模块（含剪贴板 protobuf FFI 通道） |
| `src/client.rs` | `OhosAudioSink` 占位（`psimple::Simple` 的零尺寸替身） |
| `src/server/connection.rs` | 鸿蒙版 `TerminalUserToken` |
| `src/ui_session_interface.rs` | `mobile_wheel` 模块挂载（触屏滚轮换算） |
| `src/hbbs_http/http_client.rs` | `TlsType::NativeTls` 在鸿蒙上降级到 rustls |
| `src/keyboard.rs` / `src/lang.rs` | 鸿蒙版 `get_keyboard_mode` / `translate` |
| `libs/base/Cargo.toml` | `target_env = "ohos"` 分支的依赖 |

## 三、Tier-1：完全不碰上游的新增文件

| 路径 | 作用 |
|---|---|
| `src/platform/ohos/mod.rs` | 平台入口：显示、输入、剪贴板、电源、权限（FFI 到 C++ 侧） |
| `src/platform/ohos/ffi.rs` | `extern "C"` 全部收进私有 `mod raw`，对外只暴露安全封装（`take_string()` 统一接管 C++ 内存） |
| `src/platform/ohos/linux_compat.rs` | **关键设计**：上游有 60 余处 `#[cfg(target_os = "linux")]` 块写死 `crate::platform::linux::*`。与其让补丁表膨胀，不如提供同签名 API（`is_x11()` 恒 false、`resolutions()` 空、`WallPaperRemover`/`WakeLock` 空类型…），缺口集中在一个文件、编译期可发现 |
| `libs/scrap/src/common/ohos.rs` | 屏幕采集后端（AVScreenCapture 经 C++ 侧） |
| `ohos/third_party/{rdev,nix,socket2,tokio-native-tls}` | vendored 空实现，签名与上游 linux 后端**逐字对齐**（例：`start_grab_listen` 的回调必须是 `FnMut(Event) -> Option<Event>`，写窄了 `keyboard.rs` 的调用点就编不过） |
| `scripts/ohos/*.sh` | 构建、同步上游 |

### 为什么 shim 优于改 cfg

判断标准：

- **调用点多**（166 处 `rdev::`、26 处 `ipc::Data`）或**上游每次 merge 都可能新增调用点** → 造同签名 shim，调用点零改动；
- **单一位置、语义清晰** → 交给 Tier-2 精确补丁。

## 四、不提交的改动（生成式，Tier-2）

| 脚本 | 影响面 | 说明 |
|---|---|---|
| `scripts/ohos/apply-mobile-cfg.py` | 41 文件 / 583 处 `target_env = "ohos"`；36 条精确补丁 + 8 条文件级正则 | ① 把 `not(any(android, ios))` 一类谓词加上 `target_env = "ohos"`，使 OHOS 归入"非桌面"分支；② 把裸 `#[cfg(target_os = "linux")]` 读作"桌面 linux"；③ 精确补丁处理无法模式化的站点。**每次构建前自动施加，不进入 git** |

### 三条踩过的硬约束（写在这里，避免重犯）

1. **Cargo 不允许同一依赖在不同 target 段使用不同 source path**
   （`Dependency 'arboard' has different source paths depending on the build target`）。
   `package = "..."` 别名也绕不过——Cargo 检查的是包名。原计划给 `arboard` 造 shim，最终改为
   **复用上游的移动端分支**（`clipboard.rs` 的 "android 侧" 实为"移动端侧"，走 platform 层纯文本读写），
   删掉了 4 个 shim 目录。
2. **`[patch]` 的版本必须与 `Cargo.lock` 逐位一致**，否则报 `patch ... was not used in the crate graph`。
3. **`message_proto` 由 `base` crate 生成**，`hbb_common` 里没有（`hbb_common::message_proto` 报 E0432）。

## 五、升级检查表（每次 merge 上游后逐项确认）

1. `python scripts/ohos/apply-mobile-cfg.py --check` 通过（构建前会重新施加，此检查确认规则仍覆盖全部站点）
2. 若脚本报 `目标代码已变化，未匹配`，说明上游改动了某条精确补丁锚点，逐条核对后更新锚点
3. `cargo check --target aarch64-unknown-linux-ohos --lib` 零错误
4. `bash scripts/ohos/build-core.sh` 产出 `librustdesk.a`
5. 若上游新增平台后端目录（如 `libs/scrap/src/ohos` 撞名），重命名我们的目录并更新本文档
