<h1 align="center">雾凇拼音 · 1zumiii Edition</h1>

<p align="center">
  基于 <a href="https://github.com/iDvel/rime-ice">雾凇拼音（rime-ice）</a> 的个人定制版本，加了最近使用优先、本地小模型 AI 重排、语法模型和模糊音，并带有鼠须管（macOS）、小狼毫（Windows）和同文输入法 Trime（Android）的配置。<br>
  上游原版的说明保留在 <a href="README.upstream.md">README.upstream.md</a>。
</p>

<p align="center">
  <img src="llm-android/docs/preview.png" alt="Android（同文输入法 Trime）预览：GBoard 风格主页面、AI 重排的候选" width="900"><br>
  <sub>Android（Trime）预览：GBoard 风格布局，工具栏的 <code>● AI</code> 是 AI 重排的状态和开关；候选后面的 <code>◇</code> 表示这个首选是按上文重排出来的。</sub>
</p>

---

## 项目说明

这个 fork 基于 [iDvel/rime-ice](https://github.com/iDvel/rime-ice) 的 `da1fbe6`（2026-10-05）。我在日常使用中加了一些自己需要的功能。

主要在 macOS 的鼠须管（Squirrel 1.1.2，librime 1.16）上使用和测试。Windows 小狼毫有一套配置，但验证较少。Android 的 Trime 在一台手机（ASUS Zenfone 10）上日常使用，见下文。

- 默认分支是 `custom`，只从上游合并更新，不向上游推送，也不提 PR。`main` 与上游保持一致，只用来同步。
- 所有个人改动都放在单独的文件里（`*.custom.yaml` 补丁、独立的 Lua 脚本），没有直接修改上游的方案、词库和 Lua，所以合并上游更新时基本不会冲突。
- 只用于个人，没有做成通用发行版。AI 重排是实验功能，只在少量用例上测过，见下文。

## 新增功能

### 最近使用优先

最近 72 小时内上屏过的词，会被提升到第 2 个候选位置（最多 2 个词），置顶词仍在最前。参数在 `rime_ice.custom.yaml` 的 `recent_boost_filter` 里（`window_hours`、`idx`、`max_boost` 等）。

- 记录保存在 `~/Library/Rime/recent_words.tsv`，**是你上屏词的明文记录**（默认最多保留 3000 条），不会同步到别处，也不会进仓库。
- 原版的词频学习（userdb）仍然保留，这个功能是在它之上的补充。

### AI 重排（实验，macOS Apple Silicon；Android 见下一节）

用本地小模型（Qwen3.5-0.8B，Q4_K_M 量化）根据本次输入会话里刚上屏的内容，对候选词重新排序。例如上屏“我最近没有太多”之后输入 `jingli`，首选会变成“精力”，而不是“经理”。输入 `jingliguolai` 时，两阶段重排会拼出“经理过来”。

- 移植自 [zhanghaozhecn/rime-llm-rerank](https://github.com/zhanghaozhecn/rime-llm-rerank)（署名许可，原版仅支持 Windows）。C++ 推理核心保持不变，去掉了 Windows 的光标上文读取；Lua 层按雾凇拼音的候选结构和 Squirrel 重写了一部分，详见 [llm-mac/README.md](llm-mac/README.md)。
- 标记：重排后的首选候选后面带 `◇`，四字两阶段拼出来的首选带 `◈`。
- 开关：默认开启，每个输入框各管各的（鼠须管每个输入框是独立会话）。按 `Control+Shift+5` 在当前输入框临时关闭或打开。要默认关闭，把 `rime_ice.custom.yaml` 里 `ai_rerank` 开关的 `reset` 改成 `0`。
- 上文只来自 Rime 的 `commit_history`，也就是本次会话里通过输入法上屏的内容。它不读取任何应用里的文字，所以换输入框后的第一个词不会重排。
- 隐私：不写任何包含输入内容的文件，不联网。上游原有的训练语料、事件日志和词频落盘都已删除。
- 不会卡住输入：打分不在主线程上等后台预解码。上文还没预解码好时，这一次按键保持原顺序，下一次再重排。输入串变短（退格改字）时不跑耗时的第二阶段。第一阶段按“上文 + 候选”缓存，输入同一个词的每个字母不会重复推理。
- 默认只对 3 个字母及以上的输入触发（`code_pattern: [a-z]{3,}`），避开置顶词和简拼。只在前 80 个候选里重排，其余候选保持惰性生成，避免雾凇的大词库卡顿。
- 空闲自动卸载：20 分钟没打字就释放模型（还回约 320 MB 内存），下次打字时自动加载回来（约 1 秒，期间不重排）。连续打字时等于没有这个功能。把 `idle_unload_minutes` 设为 0 可以关闭。
- 可选 Metal GPU 推理：构建时加 `-DRIME_LLM_METAL=ON`。实测单次打分从约 27 ms 降到约 13 ms，CPU 时间降低约 97%，内存多约 45 MB，详见 [llm-mac/README.md](llm-mac/README.md)。
- 资源占用（Apple Silicon，CPU 推理，4 线程）：模型加载约 1 秒，单次打分约 27 ms，Squirrel 占用内存约 394 MB。关闭了 llama.cpp 的权重重排（`use_extra_bufts = false`），内存从 869 MB 降到 374 MB，单次打分慢约 7 ms。
- 效果的局限：我只用十几条同音词用例验证过，不能代表真实输入的准确率。它只重排 Rime 已经生成的候选，不会产生新候选。

需要自己编译 `rime_llm.so`（Xcode、CMake）并下载约 508 MB 的模型，步骤见 [llm-mac/README.md](llm-mac/README.md)。

### Android（同文输入法 Trime）

同一套配置和 AI 重排也在手机上用。推理放在独立的常驻进程里，Trime 里只留一个很薄的客户端，所以输入法进程被杀或崩溃，模型不会跟着丢。设计、实测数据和文件清单见 [llm-android/README.md](llm-android/README.md)。

- 改版 Trime：在上游固定提交上打了[一个补丁](llm-android/trime/patches/0001-ai-rerank-daemon.patch)，加了 `INTERNET` 权限（只连本机 127.0.0.1）、亮灭屏通知、工具栏的 `● AI` 状态徽标，以及经 Shizuku 拉起守护进程的入口。**仓库里不带 APK**，需要自己编译，并用自己的密钥签名（`llm-android/trime/build_apk.sh`）。
- 常驻推理进程 `rimellmd`：独立的二进制，由 adb 或 Shizuku 以 shell 身份拉起。监督进程看护工作进程，被杀、崩溃或无响应时按退避时间自动重启，并记下原因。它和 Trime 之间走 127.0.0.1，用随机令牌认证。所有 I/O 都有时限，连不上时这一次不重排，输入不会变慢。推理引擎和 Mac 上测过的是同一份。
- 手动启停：点工具栏的 `● AI` 徽标开关 AI。绿色是在线，黄色是加载或重启中，灰色是已关闭，红色是离线（点一下经 Shizuku 启动）。长按看内存、延迟、重启次数和上次退出原因。关闭时模型立即卸载，进程只剩待命；开启时立即加载。不会自动卸载，新装默认关闭，你的选择会被记住。
- 孤儿保护：Trime 被卸载后，它的数据目录会消失。守护进程发现目录连续 10 分钟不在，就自己退出，监督进程也一并结束，不会留下没人管的模型占着内存。重装 Trime 后，点红色的徽标即可重新拉起。
- 手机上的调优（骁龙 8 Gen 2 实测）：2 个推理线程（4 个会因忙等偶发数秒卡顿），3 个候选（比 5 个快约三分之一），上文 6 个 token，关闭四字词的第二阶段。这些只写在 `llm-android/trime/*.overlay.yaml` 里，部署时才追加，不影响 Mac 和 Windows。
- GBoard 风格布局：同文风主题改成 GBoard 习惯的主页面和 `?123` 数字符号页，符号页每页 4 行 × 7 列，按键用线条图标。空格键在中文模式显示“拼音”，英文模式显示“English”。补丁由 [gen_tongwenfeng_patch.py](llm-android/trime/gen_tongwenfeng_patch.py) 从主题源文件生成。
- 适用范围：只在这一台手机上验证过，其他机型和 Trime 版本没有测。重启手机后，要先启动 Shizuku，才能拉起守护进程。

### 语法模型

配置了万象的语法模型 `wanxiang-lts-zh-hans.gram`（约 379 MB），改善整句输入时的同音字选择。Squirrel 自带 octagram 插件。模型文件不在仓库里，需要自己从 [amzxyz/RIME-LMDG](https://github.com/amzxyz/RIME-LMDG/releases) 下载，放进 `~/Library/Rime/`。没有这个文件时相关配置会被忽略，不影响使用。

整句候选后面会带 `❖` 标记（`model_badge_filter.lua`）。

### 模糊音

开启了平翘舌（z/zh、c/ch、s/sh）和前后鼻音（an/ang、en/eng、in/ing），规则在 `algebra_extra.yaml`，由 `tools/gen_typo_rules.py` 生成。想关掉某一组，在脚本里注释掉对应行后重新生成。

脚本里还有一个“相邻按键误触容错”，默认关闭。实测它会吞掉“完整拼音夹着缩写”的输入，得不偿失。

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

给想改补丁的人，也给以后的自己：

1. 不要用 `__patch` 引用带 `/+` 的文件。那样 `/+` 不会按“追加”处理，而是把官方整段 `speller/algebra` 整体替换掉，所有简拼（`zm`、`zuijd`）全部失效。要用 `"speller/algebra/+": { __include: algebra_extra:/rules }`。`tools/verify_build.sh` 会在安装前自检这一点。
2. 不要用 `@last`，它是“替换最后一项”，会把官方末尾的 `uniquifier` 挤掉；追加要用 `@before last` 或 `@after last`。
3. 补丁键按字典序依次生效，带数字的 `@before N` 依赖前面的插入；同一个键只能写一次，所以 `@before 0`、`@after last` 这类位置各只能给一个组件用。
4. 替换已存在的 `rime_llm.so` 必须先删再复制。原地覆盖会让 macOS 缓存的旧代码签名对不上新内容，加载时内核直接 `SIGKILL (Code Signature Invalid)`，输入法一启动就崩，反复崩溃后系统会把它从已启用输入法里移除。`llm-mac/install_llm.sh` 已经这样处理。
5. 鼠须管的开关状态是每个输入框各管各的，新输入框会回到默认状态，所以需要常开的开关默认值要设成开。
6. 不要把绑定了引擎的对象缓存成 Lua 模块级变量。鼠须管每个输入框/应用都有独立的引擎，而 Lua 模块是共享的；把 `Component.Translator(...)` 存成模块级变量，后来的输入框会用到已销毁引擎里的翻译器，`query` 时访问野指针，进程直接段错误（崩溃报告里是 `ScriptTranslator::Query`）。要存就存在 `env` 里，随引擎一起销毁。
7. 用 Metal 的话，退出时必须先释放模型。llama.cpp 的 Metal 设备对象在进程退出的静态析构里断言缓冲已全部释放，没释放就 abort，输入法每次退出都会留一份崩溃报告。
8. 官方 `.gitignore` 会忽略 `*.custom.yaml`，这个 fork 已放行根目录、`windows/` 和 `llm-android/trime/` 下的。
9. Trime 不可调试，数据目录又是 `noexec`，`.so` 无法从外面放进去，只能打进 APK；换签名必须先卸载原来的 Trime（会清空它的数据目录，先备份）。
10. 手机上推理线程别开到 4 个。预解码和打分同时跑，ggml 的线程池忙等，在大小核加上其他应用争核的环境里会偶发数秒卡顿；2~3 个线程没有这个问题，延迟也几乎一样（这个模型有按顺序处理的循环层，延迟下限与线程数无关）。
11. Trime 的主题补丁文件名必须是 `<主题 id>.custom.yaml`（同文风是 `tongwenfeng.trime.custom.yaml`），而且 Trime 只在输入法服务启动时读主题，改完要重启一次 Trime。按键自己写的 `label` 只在中文模式生效，英文模式显示预设标签，所以图标要改在 `preset_keys` 里。
12. 覆盖安装 Trime 后，输入法服务要等键盘弹出才会起来，在那之前发出的部署广播会被丢掉：先点开一个输入框再部署。

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

`windows/` 下有一套适配：

- `install.ps1`：先备份再安装，保留你的 `default.custom.yaml` 和用户数据。
- `check_deployed.ps1`：部署后检查官方拼写规则有没有被补丁覆盖。
- `rime_ice.custom.yaml`：去掉了可能和 AI 重排冲突的功能。

脚本在真实 Windows 上跑过，修过几个问题：`robocopy` 遇到被占用的文件会卡死，预览看不到文件列表，会覆盖自己的 `weasel.yaml` 样式。覆盖面仍然有限，请先用 `-DryRun` 预览。

**安装后要点托盘图标里的“重新部署”。** 命令行的 `WeaselDeployer.exe /deploy` 不会真正编译方案。

脚本不会拷贝 `weasel.yaml`，所以你自己的小狼毫样式会保留。样式覆盖请写在 `weasel.custom.yaml`。

Windows 上的 AI 重排用的是自行从源码编译的上游插件，带一些本地补丁，补丁不在本仓库里。它不是这里的 macOS 移植。

### Android（Trime）

前提：已装好改版 Trime 并走完首次引导（选“使用应用专属存储空间”），手机用 adb 连着，并装有 Shizuku。

```bash
llm-android/trime/build_apk.sh                       # 从源码编改版 APK 并签名（首次需要 JDK 17、NDK r27d 等，见脚本开头）
adb install -r <生成的 apk>
llm-android/deploy_trime.sh --with-gram              # 推送配置和语法模型；先让 Trime 键盘弹出来，部署才会生效
llm-android/daemon/rimellmctl.sh start               # 电脑端启动守护进程（也可以在手机上点红色的 AI 徽标，经 Shizuku 启动）
```

模型文件 `Qwen3.5-0.8B-Q4_K_M.gguf` 需要放进 Trime 的用户目录（`/sdcard/Android/data/com.osfans.trime/files/rime/`）。完整说明、测试和基准脚本见 [llm-android/README.md](llm-android/README.md)。

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
| `llm-android/` | Android（Trime）：常驻推理进程、Trime 补丁与构建脚本、手机专属配置叠加、GBoard 风格布局补丁、基准与测试 |
| `install.sh`、`tools/verify_build.sh` | 安装与安装前自检 |

## 致谢与许可

感谢 [iDvel/rime-ice](https://github.com/iDvel/rime-ice) 及其贡献者；[zhanghaozhecn/rime-llm-rerank](https://github.com/zhanghaozhecn/rime-llm-rerank)（AI 重排，署名许可，个人使用无限制）；[amzxyz/RIME-LMDG](https://github.com/amzxyz/RIME-LMDG)（万象语法模型）；[llama.cpp](https://github.com/ggml-org/llama.cpp)；[osfans/trime](https://github.com/osfans/trime)（同文输入法，GPL-3.0）及同文风主题作者暖暖；[Shizuku](https://github.com/RikkaApps/Shizuku)；以及 Rime、librime-lua、librime-octagram 的作者们。

本仓库沿用上游的 GPL-3.0 许可证，见 [LICENSE](LICENSE)。模型文件和语法模型各自遵循其发布方的许可。
