# 拼写容错评测脚本

仅限 macOS（调用 Squirrel 自带的 librime，不加载 Lua）。词条来自仓库公开词库，不含任何个人数据。

1. `python3 make_sets.py`：从 `cn_dicts/` 抽取词，生成 `words.json`、`clean_all.txt`。
2. `python3 rime_probe.py <工作目录> <方案变体> <输入文件>`：逐行输入，输出前 7 个候选（JSON 行）。
3. 用基线结果生成 `clean_S.txt.base.jsonl`、`clean_all.txt.base.jsonl` 后，`python3 eval_typo.py` 生成各类错拼集合。

结论与数据见 `docs/typo-tolerance.md`。
