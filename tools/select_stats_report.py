#!/usr/bin/env python3
"""汇总 select_stats.tsv（纯数字的选词统计）：重排前后“被选中的是第一位”的比例等。
用法：python3 -I tools/select_stats_report.py <select_stats.tsv> [更多文件…]
列：时间戳, AI 开关, 模型(q|s), 输入字母数, 候选数, 原顺序位次, 最终顺序位次, 上文档(0 空 1 短 2 中 3 长), 候选字数, 候选类型, 缓存标记"""
import sys
from collections import Counter, defaultdict

rows = []
for p in sys.argv[1:]:
    for line in open(p, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) == 11 and f[0].isdigit():
            rows.append(dict(ts=int(f[0]), ai=int(f[1]), model=f[2], inlen=int(f[3]), n=int(f[4]),
                             o=int(f[5]), f=int(f[6]), ctx=int(f[7]), clen=int(f[8]), typ=f[9], s1=f[10]))
if not rows:
    sys.exit("没有可用的记录")


def pct(a, b):
    return f"{100*a/b:.1f}%" if b else "-"


def block(title, rs):
    # 只统计“重排确实参与了”的记录：AI 开、有候选数、原顺序位次已知
    ran = [r for r in rs if r["ai"] == 1 and r["n"] > 1 and r["o"] > 0 and not r["s1"].startswith("skip")]
    off = [r for r in rs if r["ai"] == 0]
    print(f"\n## {title}（共 {len(rs)} 次选词）")
    if off:
        print(f"- AI 关：选中第一位 {pct(sum(r['f']==1 for r in off), len(off))}（{len(off)} 次）")
    if ran:
        o1 = sum(r["o"] == 1 for r in ran)
        f1 = sum(r["f"] == 1 for r in ran)
        better = sum(r["o"] != 1 and r["f"] == 1 for r in ran)
        worse = sum(r["o"] == 1 and r["f"] != 1 for r in ran)
        print(f"- AI 开且重排参与（{len(ran)} 次）：原顺序第一位被选中 {pct(o1, len(ran))} → 重排后第一位被选中 {pct(f1, len(ran))}")
        print(f"  重排救回 {better} 次（原来不是第一位、重排后是），帮倒忙 {worse} 次（原来是第一位、重排后不是）")
        sel_pos = Counter(min(r["f"], 6) for r in ran)
        print("  重排后所选位次分布：" + "，".join(f"第{k}位 {pct(v, len(ran))}" for k, v in sorted(sel_pos.items())))
    skipped = [r for r in rs if r["ai"] == 1 and (r["n"] <= 1 or r["s1"].startswith("skip") or r["o"] == 0)]
    if skipped:
        print(f"- AI 开但重排未参与（上文不足、候选太少、被跳过等）：{len(skipped)} 次，其中选中第一位 {pct(sum(r['f']==1 for r in skipped), len(skipped))}")


block("全部", rows)
models = defaultdict(list)
for r in rows:
    models[r["model"]].append(r)
if len(models) > 1:
    for m, rs in models.items():
        block({"q": "Qwen 0.8B", "s": "学生模型"}.get(m, m), rs)
for lo, hi, name in [(1, 3, "输入 1~3 个字母"), (4, 6, "输入 4~6 个字母"), (7, 99, "输入 7 个字母以上")]:
    rs = [r for r in rows if lo <= r["inlen"] <= hi]
    if rs:
        block(name, rs)
for c, name in enumerate(["上文为空", "上文 1~2 字", "上文 3~9 字", "上文 10 字以上"]):
    rs = [r for r in rows if r["ctx"] == c]
    if rs:
        block(name, rs)
