#!/usr/bin/env python3
"""生成「按错到相邻键」的拼音容错规则，输出到 algebra_extra.yaml。

规则：
- 只处理 3 个字母及以上的音节，只替换非首字母（韵母部分）；
- 键盘按 QWERTY 的错位几何判断相邻；
- 排除：错误形式本身是真音节，或者是某个真音节的前缀（避免干扰正常输入过程）。
用法：python3 tools/gen_typo_rules.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DICTS = ["cn_dicts/8105.dict.yaml", "cn_dicts/base.dict.yaml"]
MIN_LEN = 3

# 邻键误触容错开关。实测会吞掉「完整拼音夹缩写」的输入，收益小于代价，默认关闭。
ENABLE_NEIGHBOUR_TYPO = False

# 模糊音：平翘舌 z/zh c/ch s/sh，前后鼻音 an/ang en/eng in/ing（取自官方被注释掉的规则）
# 想关掉某一组，注释掉对应几行后重新运行本脚本
FUZZY = [
    "derive/^([zcs])h/$1/",
    "derive/^([zcs])([^h])/$1h$2/",
    "derive/ang$/an/",
    "derive/an$/ang/",
    "derive/eng$/en/",
    "derive/en$/eng/",
    "derive/ing$/in/",
    "derive/in$/ing/",
]

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
OFFSET = [0.0, 0.25, 0.75]
POS = {c: (r, i + OFFSET[r]) for r, row in enumerate(ROWS) for i, c in enumerate(row)}


def neighbours(c):
    r, x = POS[c]
    out = set()
    for c2, (r2, x2) in POS.items():
        if c2 == c:
            continue
        if r2 == r and abs(x2 - x) <= 1.0:
            out.add(c2)
        elif abs(r2 - r) == 1 and abs(x2 - x) <= 0.6:
            out.add(c2)
    return out


def load_syllables():
    syl = set()
    for f in DICTS:
        for line in (ROOT / f).read_text(encoding="utf8").splitlines():
            parts = line.split("\t")
            if len(parts) >= 2:
                for s in parts[1].split():
                    if re.fullmatch(r"[a-z]+", s):
                        syl.add(s)
    return syl


def main():
    syl = load_syllables()
    if not ENABLE_NEIGHBOUR_TYPO:
        syl_for_rules = set()
    else:
        syl_for_rules = syl
    prefixes = {s[:k] for s in syl for k in range(1, len(s) + 1)}
    rules = set()
    for s in syl_for_rules:
        if len(s) < MIN_LEN:
            continue
        for k in range(1, len(s)):
            for c in neighbours(s[k]):
                t = s[:k] + c + s[k + 1:]
                if t in prefixes:
                    continue
                rules.add((t, s))
    lines = [
        "# encoding: utf-8",
        "# 由 tools/gen_typo_rules.py 生成，不要手改。",
        "# 追加到 speller/algebra 的额外规则：模糊音；邻键误触容错默认关闭（见生成脚本的 ENABLE_NEIGHBOUR_TYPO）",
        "---",
        "rules:",
    ]
    lines += [f"  - {r}" for r in FUZZY]
    for t, s in sorted(rules):
        lines.append(f"  - derive/^{s}$/{t}/")
    (ROOT / "algebra_extra.yaml").write_text("\n".join(lines) + "\n", encoding="utf8")
    print(f"{len(syl)} 个音节，生成 {len(rules)} 条邻键规则 + {len(FUZZY)} 条模糊音规则", file=sys.stderr)


if __name__ == "__main__":
    main()
