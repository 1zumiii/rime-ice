# rime-llm-rerank 的 macOS 移植（实验）

上游：[zhanghaozhecn/rime-llm-rerank](https://github.com/zhanghaozhecn/rime-llm-rerank)（署名许可：个人使用无限制，商用需署名）。

使用本地小模型（Qwen3.5-0.8B），依据上文对 Rime 候选重新排序。本目录仅包含移植脚本和构建配置，不含上游源码、llama.cpp 与模型。

## 构建

依赖：Xcode 命令行工具、CMake、Ninja。以下目录放在仓库之外（例如 `~/Documents/rime-llm-mac-port/`）：

```bash
git clone https://github.com/zhanghaozhecn/rime-llm-rerank.git rerank
git clone --depth 1 --branch b11632 https://github.com/ggml-org/llama.cpp.git llama.cpp
# Lua 5.4.6 头文件（Squirrel 内嵌 5.4.6）：https://www.lua.org/ftp/lua-5.4.6.tar.gz
#   sha256 7d5ea1b9cb6aa0b59ca3dde1c6adcb57ef83a1ba8e5432c0ecd06bf439b3ad88 ，解压到 deps/lua-5.4.6
python3 -I scripts/port_to_mac.py rerank/cpp/rime_llm.cpp rime_llm_mac.cpp
cp llm-mac/CMakeLists.txt .
cmake -G Ninja -S . -B build && cmake --build build --target rime_llm
```

产物 `build/rime_llm.so`（arm64，静态链接 llama.cpp，CPU 推理）。

## 安装注意：不要原地覆盖 `rime_llm.so`

替换已存在的 `rime_llm.so` 时，须先删除再复制（`install_llm.sh` 已按此处理）。原地覆盖会使 macOS 缓存的旧代码签名与新内容不符，加载时内核直接以 `SIGKILL (Code Signature Invalid)` 终止进程，输入法一启动即崩溃，反复崩溃后系统会将其从“已启用的输入法”中移除。

恢复方法：删除并重新复制 `.so`，然后运行 `Squirrel --disable-input-source im.rime.inputmethod.Squirrel.Hans`、`--enable-input-source …`、`--select-input-source …`；必要时在“系统设置 → 键盘 → 输入法”中重新添加。

## 为什么能直接加载

Squirrel 的签名带 `disable-library-validation`，且其 `librime-lua.dylib` 导出全部 `lua_*` 符号（内嵌 Lua 5.4.6），因此自行编译的 Lua C 模块可以直接加载，无需与其相同的开发者签名。

## 与 Windows 版的差异

- 不含 UIA/COM 光标上文读取；`llm_context()` 恒返回 `nil`，上文取自 Rime 的 `commit_history`（本会话内上屏的内容）。
- `use_mmap` 字段在 llama.cpp b11632 中已改为 `load_mode`。
- 日志与默认模型路径改为 POSIX。

## 实测（Apple Silicon，CPU，4 线程）

- 模型加载约 1 秒；10 条同音词用例首选 10/10；单次打分约 20 ms（3 个候选，无预解码优化）。
- 4/6/8 线程耗时相同但 CPU 占用翻倍，推荐 4 线程。
- 测试脚本：`smoke_test.lua`（无需模型）、`model_test.lua`（需要 Qwen3.5-0.8B-Q4_K_M.gguf）。
  使用自行编译的官方 Lua 5.4.6 解释器运行：`lua model_test.lua <so 所在目录> <模型路径> <日志目录> 4`。

## 内存：关闭权重重排（`use_extra_bufts = false`）

llama.cpp 默认会把权重重排为更适合 CPU 的布局，模型因此无法再使用文件映射，变为约 500 MB 的私有内存。实测（同样 300 次打分，结果一致）：

| | 内存占用 | 单次打分 |
|---|---|---|
| 重排开 | 869 MB | 约 20 ms |
| 重排关（当前） | 374 MB | 约 27 ms |

`port_to_mac.py` 默认生成“重排关”的版本。需要更快的打分且不在意内存时，删除 `mparams.use_extra_bufts = false;` 这一行并重新编译。

## 可选：Metal GPU 推理（实验）

默认使用 CPU 推理。Apple Silicon 上可改用 Metal，构建时加 `-DRIME_LLM_METAL=ON`（着色器库内嵌于 `.so`，不依赖外部文件）：

```bash
cmake -G Ninja -S . -B build_metal -DRIME_LLM_METAL=ON && cmake --build build_metal --target rime_llm
```

实测（M1 Pro，Qwen3.5-0.8B Q4_K_M，同样的 300 次打分，结果一致，首选 10/10）：

| | CPU（默认） | Metal |
| --- | --- | --- |
| 单次打分 | 约 27 ms | 约 13 ms |
| 300 次打分的 CPU 时间 | 30.2 秒 | 0.9 秒 |
| 内存占用 | 372 MB | 417 MB |
| 首次加载 | 约 1 秒 | 约 9 秒（系统第一次编译着色器），之后约 1 秒（有缓存） |

注意：llama.cpp 的 Metal 设备对象在进程退出的静态析构阶段，会断言“所有缓冲区均已释放”。退出时若模型尚未释放，进程会 abort，即每次输入法退出都会产生一份崩溃报告。因此 `rime_llm.so` 在模块卸载（`__gc`）和进程退出（`atexit`，在模型加载之后注册，确保早于 ggml 的静态析构）时都会释放模型。

## 空闲自动卸载

模型加载后占用约 320~400 MB 内存，不输入时也不释放。`llm_rerank/idle_unload_minutes` 控制空闲卸载（默认 20，0 表示不卸载）：超过该时长没有任何按键，即释放模型和上下文，下次输入时自动重新加载。

实测（M1 Pro）：卸载后 Squirrel 的内存由约 409 MB 降至约 85 MB（Metal 版），CPU 版由 373 MB 降至 53 MB。重新加载约 0.5~0.9 秒（系统缓存已预热时），期间不重排，也不阻塞输入。连续输入时该机制不会触发。

实现要点：C++ 侧由一个计时线程用条件变量休眠到“最早可能过期”的时刻，不轮询。处理器在每次按键时调用 `touch()` 刷新“最近使用”时间，因此只输入短拼音（不触发重排）时也不会被误判为空闲。模型被卸载后，“已预解码”的记录会被清除，并在重新加载后再次触发预解码。

另外修复了两处会使“重新加载”失效的问题：
1. 处理器原先在调用预解码之前就记录“该上文已预解码”。模型尚未加载完成时，这次调用不产生任何效果，记录却已写入，加载完成后上文不变，就不会再补做预解码。现在只有预解码确实排入队列后才记录。
2. 原版在已有预解码运行时，会直接丢弃新到的预解码请求（它可能是最新的），留下的反而是旧上文。现在将最新请求记为待办，当前预解码结束后继续执行。

## 并发与边界情况

空闲卸载带来了“模型在使用中被释放”的风险，已逐条核对并加固：

| 场景 | 处理 | 测试（`concurrency_test.lua`） |
| --- | --- | --- |
| 超时瞬间用户开始打字 | 模型设有一把生命周期读写锁：分词、打分、预解码持共享锁，卸载持独占锁。有请求在使用时不卸载；卸载进行时无法取得共享锁，当次直接跳过（`busy`），既不阻塞，也不访问已释放的内存。此前分词所用的 `g_vocab` 没有任何锁保护，属于实际存在的缺口 | `race` |
| 卸载时预解码仍在执行 | 预解码线程持共享锁，并在取得锁之后再确认模型仍然存在，不再对空指针调用 | `race` |
| 模型加载中再次收到输入 | “检查并置位”改为原子操作，不会重复创建模型；加载完成后，处理器对最新上文重新请求预解码 | `loading` |
| 预解码完成时输入已变化 | 预解码结果按“上文 token + 代次”匹配，旧结果不会用于新上文；被挡住的最新请求记为待办 | `idle_test.lua`、`filter_test.lua` |
| 退出时计时线程正在唤醒 | 停止标志在锁内置位（避免丢失唤醒），并通过 `join` 等待线程真正退出，再卸载模型 | `exit_wait`、`exit_window` |
| 配置热切换 / 重复初始化 | 计时线程始终只有一个；模块被卸载（`__gc`）再重新初始化后，状态清零并可重新启动。此前重新初始化后，空闲卸载会静默失效 | `reinit`、`toggles` |

测试中使用环境变量 `RIME_LLM_TEST_UNLOAD_DELAY_MS` 将卸载窗口延长到数百毫秒，使原本只有几十毫秒的竞态可稳定复现。该变量仅在测试时设置，正常使用不受影响。

## Lua 层（`lua/ai_rerank_filter.lua`、`lua/ai_rerank_processor.lua`）

移植自上游的 `llm_filter.lua`、`llm_processor.lua`，并包含针对全拼的适配（按覆盖长度分组、四字两阶段）。融合打分逻辑保持不变，其余改动如下：

- 开关：方案开关 `ai_rerank`（`Control+Shift+5` 在当前输入框临时开关，或在方案菜单 F4 / Control+` 中选择“AI 关/开”），默认开启（鼠须管的每个输入框为独立会话，默认关闭会使新输入框看起来未生效）。关闭时处理器直接放行，过滤器惰性透传，不加载模型。
- 不取尽候选：仅取前 `scan_limit`（80）个候选重排，其余惰性透传。雾凇词库很大，输入单个字母时候选数以万计，而原版会一次取尽。
- 触发范围：默认仅对 3 个字母及以上的输入触发（`code_pattern: [a-z]{3,}`），避开置顶词（`d`→的）和简拼。
- 隐私：不写入任何含输入内容的文件。已删除训练语料、事件日志、`debug_fusion`（会写入上文片段）和词频落盘。上文仅取自 Rime 的 `commit_history`，不读取任何应用内的文字。
- 修复：引擎清空提交历史后，旧上文不再残留。
- 第二阶段不做繁简转换（雾凇词库本身是简体）。

## 安装

```bash
./install.sh                     # 配置与 Lua（先备份，再安装）
llm-mac/install_llm.sh           # rime_llm.so 与模型（校验模型 SHA-256 后复制）
# 重启输入法后生效；AI 默认开启，Control+Shift+5 在当前输入框临时开/关
```

## 测试

使用自行编译的官方 Lua 5.4.6 运行（需要真实的 `rime_llm.so` 与模型）：

- `smoke_test.lua`：模块接口（无需模型）
- `model_test.lua`：模型打分合理性与耗时
- `filter_test.lua`：使用模拟的 Rime 环境，对过滤器与处理器做端到端测试（开关、两音节重排、四字两阶段、空上文、scan_limit、编辑键重置、不写明文文件）

## 不阻塞输入（延迟与崩溃修复）

实测日志中出现过超过 100 ms 的打分（最慢 761 ms），原因和对应处理如下：

| 原因 | 处理 |
| --- | --- |
| 打分在主线程上等后台预解码释放锁 | `score` 使用 `try_lock`，无法取得锁时直接返回 `nil, "busy"`，当次按键保持原顺序 |
| 上文没预解码好，主线程现场解码（约 40~55 ms） | 第一阶段调用 `score(ctx, cands, false)`：未预解码完成时返回 `nil, "unprepared"`，Lua 补做一次异步预解码，下一次按键再重排 |
| 上屏后新上文要到下一次按键才触发预解码 | 处理器在同步完 `commit_history` 之后，立即再触发一次预解码 |
| 四字第二阶段每个字母都现场解码（约 100 ms） | 退格时（输入串变短）不执行；剩余拼音少于 4 个字母时不执行；第二阶段只用最后 8 个字作为上文；第一阶段按“上文 + 候选”缓存 |

另有一处崩溃已修复：第二阶段使用的翻译器曾被缓存为 Lua 模块级变量，在多个输入框之间共享，引擎销毁后再使用会引发段错误。现在改为存放在各引擎自己的 `env` 中。将 `llm_rerank/stage2` 设为 `false` 即可关闭第二阶段。

## 状态

- [x] 编译通过，冒烟测试通过
- [x] 真实模型：10/10 首选，单次打分约 20 ms
- [x] Lua 层移植，模拟环境端到端测试 19/19 通过
- [x] 在真实 Squirrel 里加载并生效（开关默认开；标记 ◇ 重排首选、◈ 两阶段首选）
