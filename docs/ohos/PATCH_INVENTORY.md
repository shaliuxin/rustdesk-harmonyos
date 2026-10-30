# 补丁清单（Tier-3：唯一提交到 git 的上游修改）

> 规则：本文件列出的每一处都必须能说明"为什么不能靠新增文件解决"。
> 新增任何条目需在 PR 描述里给出理由。Tier-1/Tier-2 不在此列。

| # | 文件 | 改动 | 行数 | 原因 | 上游冲突概率 |
|---|---|---|---|---|---|
| 1 | `src/platform/mod.rs` | 注册 `ohos` 模块；把 `linux` / `gtk_sudo` 的 cfg 加上 `not(target_env = "ohos")` | 9 | 平台选择必须在编译期发生，无法用新增文件绕开 | 低（该文件极少改动） |
| 2 | `.cargo/config.toml` | 文件末尾追加 `[target.aarch64-unknown-linux-ohos]` 与 `[env]` 段 | 18 | 交叉编译工具链配置只能放这里 | 低（追在末尾） |
| 3 | `Cargo.toml` | 把 `scrap` / `hbb_common` 从 `[dependencies]` 移到按目标分流的两个 `[target.'cfg(...)'.dependencies]` 段；鸿蒙不带 `webrtc`/`wayland` feature | 16 | WebRTC 链路（`webrtc-util 0.11 → nix 0.26.4`）在 OHOS 上报 51 个 libc 类型错误，无法在新文件里解决；feature 只能在此声明 | 中（上游若改动这两行依赖） |

## 不提交的改动（生成式，Tier-2）

| 脚本 | 影响面 | 说明 |
|---|---|---|
| `scripts/ohos/apply-mobile-cfg.py` | 30 文件 / 426 处 | 把 `not(any(android, ios))` 一类谓词加上 `target_env = "ohos"`，使 OHOS 归入"非桌面"分支。**每次构建前自动施加，不进入 git** |

## 升级检查表（每次 merge 上游后逐项确认）

1. `git diff origin/master --stat -- src libs Cargo.toml .cargo` 的输出应仅包含上表 2 项
2. `python scripts/ohos/apply-mobile-cfg.py --check` 通过（构建前会重新施加，此检查用于确认规则仍能覆盖全部站点）
3. `bash scripts/ohos/build-core.sh` 成功
4. 若上游新增了平台后端目录（如 `libs/scrap/src/ohos` 撞名），重命名我们的目录并更新本文档
