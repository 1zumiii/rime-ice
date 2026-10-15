<h1 align="center">雾凇拼音 · 1zumiii Edition</h1>

<p align="center">简体中文 · <a href="README.en.md">English</a></p>

<p align="center">
  基于 <a href="https://github.com/iDvel/rime-ice">雾凇拼音（rime-ice）</a> 的个人定制版本：最近使用优先、本地小模型 AI 重排、语法模型、模糊音，以及配套的鼠须管（macOS）和小狼毫（Windows）配置。<br>
  上游原版的说明保留在 <a href="README.upstream.md">README.upstream.md</a>。
</p>

---

## 项目说明

这个 fork 基于 [iDvel/rime-ice](https://github.com/iDvel/rime-ice) 的 `da1fbe6`（2026-10-05）。我在日常使用中加了一些自己需要的功能，主要在 macOS 的鼠须管（Squirrel 1.1.2，librime 1.16）上使用和测试；Windows 小狼毫有一套配置，但验证较少。

- 默认分支为 `custom`，只从上游合并更新，不向上游推送或提交 PR。`main` 与上游保持一致，仅用来同步。
- **所有个人改动都放在单独的文件里**（`*.custom.yaml` 补丁、独立的 Lua 脚本），没有直接修改上游的方案、词库和 Lua，所以合并上游更新时基本不会冲突。
- 只用于个人，没有做成通用发行版。`AI 重排` 是实验功能，效果只在少量用例上测过，见下文说明。

## 新增功能

### 最近使用优先

最近 72 小时内上屏过的词，会被提升到第 2 个候选位置（最多 2 个词），置顶词仍然在最前。参数在 `rime_ice.custom.yaml` 的 `recent_boost_filter` 里（`window_hours`、`idx`、`max_boost` 等）。

- 记录保存在 `~/Library/Rime/recent_words.tsv`，**是你上屏词的明文记录**（默认最多保留 3000 条），不会同步到别处，也不会进仓库。
- 原版的词频学习（userdb）仍然保留，这个功能是在它之上的补充。

### AI 重排（实验，仅 macOS Apple Silicon）

用本地小模型（Qwen3.5-0.8B，Q4_K_M 量化）根据**本次输入会话里刚上屏的内容**，对候选词重新排序。例如上屏"我最近没有太多"之后输入 `jingli`，首选会变成"精力"，而不是"经理"；输入 `jingliguolai` 时，用两阶段重排拼出"经理过来"。

- 移植自 [zhanghaozhecn/rime-llm-rerank](https://github.com/zhanghaozhecn/rime-llm-rerank)（署名许可，原版仅支持 Windows）。C++ 推理核心保持不变，去掉了 Windows 的光标上文读取；Lua 层按雾凇拼音的候选结构和 Squirrel 重写了一部分，详见 [llm-mac/README.md](llm-mac/README.md)。
- **标记**：重排后的首选候选后面带 `◇`；四字两阶段拼出来的首选带 `◈`。
- **开关**：默认开启，每个输入框独立（鼠须管每个输入框是独立会话）。按 `Control+Shift+5` 在当前输入框临时关闭或打开。要默认关闭，把 `rime_ice.custom.yaml` 里 `ai_rerank` 开关的 `reset` 改成 `0`。
- **上文只来自 Rime 的 `commit_history`**，也就是本次会话里通过输入法上屏的内容，不读取任何应用里的文字，所以换输入框后首个词不会重排。
- **隐私**：不写任何包含输入内容的文件，没有联网。上游原有的训练语料、事件日志、词频落盘都已删除。
- **默认只对 3 个字母及以上的输入触发**（`code_pattern: [a-z]{3,}`），避开置顶词和简拼；只在前 80 个候选里重排，其余候选保持惰性生成，避免雾凇的大词库卡顿。
- **资源占用**（Apple Silicon，CPU 推理，4 线程）：模型加载约 1 秒，单次打分约 27 ms，Squirrel 占用内存约 394 MB。已经关闭 llama.cpp 的权重重排（`use_extra_bufts = false`），内存从 869 MB 降到 374 MB，换来单次打分慢约 7 ms。
- **效果的局限**：我只用十几条同音词用例验证过，不能代表真实输入的准确率。它只重排 Rime 已经生成的候选，不能产生新候选。

需要自己编译 `rime_llm.so`（Xcode、CMake）并下载约 508 MB 的模型，步骤见 [llm-mac/README.md](llm-mac/README.md)。

### 语法模型

配置了万象的语法模型 `wanxiang-lts-zh-hans.gram`（约 379 MB），改善整句输入时的同音字选择。Squirrel 自带 octagram 插件。模型文件不在仓库里，需要自己从 [amzxyz/RIME-LMDG](https://github.com/amzxyz/RIME-LMDG/releases) 下载，放进 `~/Library/Rime/`。没有这个文件时相关配置会被忽略，不影响使用。

整句候选后面会带 `❖` 标记（`model_badge_filter.lua`）。

### 模糊音

开启了平翘舌（z/zh、c/ch、s/sh）和前后鼻音（an/ang、en/eng、in/ing），规则在 `algebra_extra.yaml`，由 `tools/gen_typo_rules.py` 生成。想关掉某一组，在脚本里注释掉对应行后重新生成。

脚本里还有一个"相邻按键误触容错"，默认关闭：实测它会吞掉"完整拼音夹着缩写"的输入，得不偿失。

### 其他小改动

| 改动 | 说明 |
| --- | --- |
| 冷词降频 | 启用上游自带的 `cold_word_drop`：`Control+j` 降频，`Control+x` 隐藏，`Control+d` 强制删词 |
| 英文、自定义短语调频 | `melt_eng` 打开用户词典，`custom_phrase` 改为 `tabledb`（Rime 会回写 `custom_phrase.txt`） |
| 中英混输自动空格 | 启用上游自带的 `cn_en_spacer`，`VIP中P` → `VIP 中 P` |
| 每页候选 5 个 | 7 个时短词容易顶到第二行 |
| 方案列表 | 只保留 `rime_ice`，其余方案文件仍在，需要时在 `default.custom.yaml` 的 `schema_list` 里加回 |
| 外观 | `squirrel.custom.yaml`：微信键盘配色、横排候选、OpenSans 字体 |

## 踩过的坑

给想改补丁的人（也是给以后的自己）：

1. **不要用 `__patch` 引用带 `/+` 的文件。** 那样 `/+` 不会按"追加"处理，而是把官方整段 `speller/algebra` 整体替换掉，所有简拼（`zm`、`zuijd`）全部失效。要用 `"speller/algebra/+": { __include: algebra_extra:/rules }`。`tools/verify_build.sh` 会在安装前自检这一点。
2. **不要用 `@last`**，它是"替换最后一项"，会把官方末尾的 `uniquifier` 挤掉；追加要用 `@before last` 或 `@after last`。
3. **补丁键按字典序依次生效**，带数字的 `@before N` 依赖前面的插入；同一个键只能写一次，所以 `@before 0`、`@after last` 这类位置各只能给一个组件用。
4. **替换已存在的 `rime_llm.so` 必须先删再复制。** 原地覆盖会让 macOS 缓存的旧代码签名对不上新内容，加载时内核直接 `SIGKILL (Code Signature Invalid)`，输入法一启动就崩，反复崩溃后系统会把它从已启用输入法里移除。`llm-mac/install_llm.sh` 已经这样处理。
5. **鼠须管的开关状态是每个输入框各管各的**，新输入框会回到默认状态，所以需要常开的开关默认值要设成开。
6. **官方 `.gitignore` 会忽略 `*.custom.yaml`**，这个 fork 已放行根目录和 `windows/` 下的。

## 编译与安装

### macOS（鼠须管）

```bash
git clone https://github.com/1zumiii/rime-ice-Custom.git
cd rime-ice-Custom
./install.sh            # 先自检，再备份到 ~/Library/Rime.backup-时间，然后安装（保留词频库等个人数据）
```

`install.sh` 不会覆盖：`*.userdb`（词频库）、`installation.yaml`、`user.yaml`、`recent_words.tsv`、冷词记录、已存在的 `custom_phrase.txt`。安装后重启输入法（`Squirrel --quit`，下次打字时系统会重新拉起）。

AI 重排的二进制和模型另外安装：`llm-mac/install_llm.sh`，步骤见 [llm-mac/README.md](llm-mac/README.md)。

### Windows（小狼毫）

`windows/` 下有一套适配：`install.ps1`（先备份再安装，保留你的 `default.custom.yaml` 和用户数据）、`check_deployed.ps1`（部署后检查官方拼写规则有没有被补丁覆盖）、以及去掉了和 AI 重排可能冲突的功能的 `rime_ice.custom.yaml`。**这套脚本没有在真实 Windows 机器上完整验证过，请先用 `-DryRun` 预览。** AI 重排在 Windows 上用的是自行从源码编译的上游插件（带一些本地补丁，补丁不在本仓库里），不是这里的 macOS 移植。

## 同步上游更新

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout custom && git merge main
```

## 自定义内容的位置

| 位置 | 内容 |
| --- | --- |
| `rime_ice.custom.yaml`、`default.custom.yaml`、`squirrel.custom.yaml` | 方案、全局和外观补丁 |
| `algebra_extra.yaml`、`tools/gen_typo_rules.py` | 模糊音与（默认关闭的）邻键容错规则 |
| `lua/recent_boost_filter.lua` | 最近使用优先 |
| `lua/ai_rerank_filter.lua`、`lua/ai_rerank_processor.lua` | AI 重排的过滤器与处理器 |
| `lua/model_badge_filter.lua` | 整句候选的 `❖` 标记 |
| `llm-mac/` | AI 重排的 macOS 移植：转换脚本、构建配置、安装脚本、测试 |
| `windows/` | 小狼毫适配 |
| `install.sh`、`tools/verify_build.sh` | 安装与安装前自检 |

## 致谢与许可

感谢 [iDvel/rime-ice](https://github.com/iDvel/rime-ice) 及其贡献者；[zhanghaozhecn/rime-llm-rerank](https://github.com/zhanghaozhecn/rime-llm-rerank)（AI 重排，署名许可，个人使用无限制）；[amzxyz/RIME-LMDG](https://github.com/amzxyz/RIME-LMDG)（万象语法模型）；[llama.cpp](https://github.com/ggml-org/llama.cpp)；以及 Rime、librime-lua、librime-octagram 的作者们。

本仓库沿用上游的 GPL-3.0 许可证，见 [LICENSE](LICENSE)。模型文件和语法模型各自遵循其发布方的许可。
