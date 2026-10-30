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

## 7. 上游同步工作流（每月 1 次，30 分钟）

```bash
git fetch origin
git checkout ohos/main
git merge --no-commit origin/master      # 理论上零冲突（Tier1/2 不在 git 里）
python scripts/ohos/apply-mobile-cfg.py  # 重新施加生成式补丁
bash scripts/ohos/build-core.sh          # 编译验证
# 失败则按 §8 处理
git commit -m "chore: merge upstream $(date +%F)"
```

**冲突处理三原则**：
1. Tier-1 文件冲突 → 说明上游在同名路径加了文件，重命名我们的模块（如 `ohos/` → `ohos_next/`）后保留两者
2. Tier-3 两处冲突 → 按 PATCH_INVENTORY 的意图重打，非常小
3. 上游改了我们依赖的**函数签名**（如 `trait Service`）→ 只改 `src/platform/ohos` 或 `src/ohos` 内的适配，不改上游

**CI 守卫**（后续加）：
- `apply-mobile-cfg.py --check` 必须通过
- `git diff origin/master --stat` 中不得出现 `src/` 下的既有文件（除 PATCH_INVENTORY 允许的 2 处）

---

## 8. 里程碑

| 阶段 | 交付 | 验收 |
|---|---|---|
| **M0 编译地基** | Rust 目标可用，`cargo check` 通过 core 子集 | `librustdesk_core.a` 产出，符号 `rust_main` 存在 |
| **M1 主控打通** | client.rs 跑通连接 + 解码回调 + 输入发送 | 真机连 Windows 出画面，延迟 <200ms |
| **M2 主控功能** | 文件传输、剪贴板、多屏、画质调优 | 与 Flutter 版功能对照表 ≥80% |
| **M3 被控（2in1）** | Capturer + enigo::ohos + host 生命周期 | 标准 RustDesk 主控端可连入并操作 |
| **M4 手机被控（只读）** | 屏幕共享 + 权限降级 | 手机共享屏幕，控制入口隐藏 |
| **M5 质量** | 长稳/断线重连/安全边界 | 2h 会话无泄漏，权限撤销 1s 内 fail-closed |

---

## 9. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| openssl vendored 无法交叉编译 | 阻塞编译 | 优先切 rustls；不行则用 OHOS 自带 libssl |
| 上游 426 处 cfg 补丁随版本漂移 | 构建失败 | 脚本幂等 + CI --check，失败时人工补规则（只改脚本） |
| 无线程安全事件通道 | 延迟高 | C++ threadsafe function；Rust 侧暴露 callback 注册 |
| 被控端 AGC 受限权限审核 | 无法上架 | 先个人侧载（debug Profile），商用再走 AGC |
| 上游大改（如切换到新 UI 框架） | 适配层失效 | 只依赖协议层与 Service trait，不依赖 UI |
