# ohos/tools —— x86_64（模拟器）构建所需的本地工具

这些是**构建期工具**，不是运行期依赖，二进制不进版本库（见 `.gitignore`）。
重新生成方式见下；已有目录时脚本会直接复用。

## 需要的工具

| 工具 | 版本 | 用途 |
| --- | --- | --- |
| `make.exe` | GNU make 4.4.1（msys2 `msys/make`） | libvpx / libsodium 的 configure+make 构建 |
| `nasm.exe` | NASM 3.02 | libaom 的 x86_64 汇编（`--target=generic-gnu` 的 libvpx 用不到） |
| `perl-root/` | msys2 perl 5.42.3 + msys2-runtime 3.6.12 + dash | libaom 的 rtcd 代码生成、libvpx 的 `rtcd.pl` |

## 获取方式（清华 msys2 镜像，GitHub 直连不可用）

```bash
curl -L --ssl-no-revoke -o make.pkg.tar.zst \
  https://mirrors.tuna.tsinghua.edu.cn/msys2/msys/x86_64/make-4.4.1-3-x86_64.pkg.tar.zst
curl -L --ssl-no-revoke -o nasm.pkg.tar.zst \
  https://mirrors.tuna.tsinghua.edu.cn/msys2/mingw/ucrt64/nasm-3.02-1-any.pkg.tar.zst
curl -L --ssl-no-revoke -o perl-5.42.3-3-x86_64.pkg.tar.zst \
  https://mirrors.tuna.tsinghua.edu.cn/msys2/msys/x86_64/perl-5.42.3-3-x86_64.pkg.tar.zst
curl -L --ssl-no-revoke -o msys2-runtime-3.6.12-1-x86_64.pkg.tar.zst \
  https://mirrors.tuna.tsinghua.edu.cn/msys2/msys/x86_64/msys2-runtime-3.6.12-1-x86_64.pkg.tar.zst
# 用 Python 的 zstandard + tarfile 解包（Git Bash 无 zstd）
```

## 关键约束（踩过的坑）

1. **`make` 找 `sh`**：msys2 的 make 把 `/usr/bin/sh` 解析到它自己的运行时根
   （即 `perl-root/`），所以 `perl-root/usr/bin/sh.exe` 与 `perl-root/bin/sh.exe`
   都放了 dash 伪装的 `sh.exe`；`mkdir/cp/mv/rm/ln/sed/grep/env` 也从 Git Bash
   `usr/bin` 拷进 `perl-root/usr/bin`（dash 解析绝对路径会落到 perl-root）。
2. **`/usr/bin/env`**：`rtcd.pl` 的 shebang 是 `#!/usr/bin/env perl`，
   perl-root 里原本没有 `env.exe` → `rtcd.pl` 静默产出 0 字节的 `*_rtcd.h`
   （表现为链接期 `undefined symbol: vpx_convolve8_vert_neon`）。必须把
   Git Bash 的 `env.exe` 也拷进 `perl-root/usr/bin/`。
3. **路径形式**：给 dash 的 `PATH` 条目必须是 POSIX 形式（`/c/...`），
   `SHELL`/程序路径必须是 Windows 混合形式（`C:/...`）；混用会 ENOENT 或被
   `:` 切坏。
4. **`TOOLS_WIN` 要在改 PATH 之前算**：PATH 一旦带上 `perl-root/usr/bin`，
   Git Bash 的 `cygpath` 会加载 perl-root 的 `msys-2.0.dll`，路径解析错乱。
5. **harness 删除垫片**：autoconf 的 `conftest` 临时文件删不掉会让 libtool 的
   `cd conftest` 测试失败、结尾 `cd ..` 把 cwd 顶上一层，报
   `config.status: error: cannot find input file: 'Makefile.in'`。
   对策：`env -u CODEBUDDY_SESSION_ID -u CLAUDE_SESSION_ID` 让垫片直接透传真 rm。

## 目录说明

- `make.exe`、`nasm.exe`：直接解出的可执行文件
- `perl-root/`：最小 msys2 根（perl + runtime + dash + 基础 coreutils）
- `make-root/`、`nasm-root/`：解包中间目录（可删）
- `*.tar.zst`、`*.html`、`t.asm`/`t.o`：下载与验证残留（可删）
