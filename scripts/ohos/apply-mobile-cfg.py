#!/usr/bin/env python3
"""
OpenHarmony 移植：幂等重写上游 cfg 谓词。

为什么需要脚本而不是手改：
    上游 src/ 有 330 处 `not(any(target_os = "android", target_os = "ios"))` 与
    615 处 `target_os = "android"`。手改会产生大量 diff，每次同步上游必冲突。
    本脚本把「OHOS 属于第三类移动端」这一判断以**可重复执行**的方式施加：
        - 只放宽「非桌面平台」这一组谓词（加上 target_env = "ohos"）
        - 不动任何 android 专属分支（jni / mediacodec / android_logger）
    因此每次 `git merge upstream/master` 后重跑本脚本即可得到等价工作树，
    冲突面被压到「新增文件 + 本脚本」这一层。

用法：
    python scripts/ohos/apply-mobile-cfg.py           # 施加（幂等）
    python scripts/ohos/apply-mobile-cfg.py --check   # 只检查是否已全部施加（CI 用）
    python scripts/ohos/apply-mobile-cfg.py --dry-run # 只看会改多少处
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

NEG = 'not(any(target_os = "android", target_os = "ios"))'
NEG_OHOS = 'not(any(target_os = "android", target_os = "ios", target_env = "ohos"))'

POS = 'any(target_os = "android", target_os = "ios")'
POS_OHOS = 'any(target_os = "android", target_os = "ios", target_env = "ohos")'

SKIP_DIRS = {".git", "target", "node_modules", "flutter", "docs"}


def targets():
    for pattern in ("**/*.rs", "**/Cargo.toml"):
        for p in ROOT.glob(pattern):
            if any(part in SKIP_DIRS for part in p.parts):
                continue
            yield p


def rewrite(text: str) -> tuple[str, int]:
    """返回 (新文本, 改动计数)。POS 必须在 NEG 之后处理。"""
    changes = 0
    text, n = re.subn(re.escape(NEG), NEG_OHOS, text)
    changes += n
    # 只替换尚未包含 ohos 的正向谓词
    def pos_sub(m: re.Match) -> str:
        nonlocal changes
        if 'target_env = "ohos"' in m.group(0):
            return m.group(0)
        changes += 1
        return POS_OHOS

    text = re.sub(re.escape(POS), pos_sub, text)
    return text, changes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    total_files = 0
    total_changes = 0
    pending: list[tuple[pathlib.Path, str]] = []

    for path in targets():
        try:
            original = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        updated, n = rewrite(original)
        if n:
            total_files += 1
            total_changes += n
            pending.append((path, updated))

    if args.check:
        if total_changes:
            print(f"[FAIL] {total_changes} cfg 处未施加 ohos 谓词（{total_files} 个文件）")
            return 1
        print("[OK] 所有 cfg 谓词已包含 ohos")
        return 0

    print(f"{'[dry-run] ' if args.dry_run else ''}{total_files} 个文件 / {total_changes} 处改动")
    if args.dry_run:
        return 0

    for path, updated in pending:
        path.write_text(updated, encoding="utf-8")
    print("已施加。请执行 `cargo check --target aarch64-unknown-linux-ohos` 验证。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
