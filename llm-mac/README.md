# rime-llm-rerank 的 macOS 移植（实验）

上游：[zhanghaozhecn/rime-llm-rerank](https://github.com/zhanghaozhecn/rime-llm-rerank)（署名许可：个人使用无限制，商用需署名）。

用本地小模型（Qwen3.5-0.8B）对 Rime 候选按上文重排。本目录只放**移植脚本和构建配置**，不含上游源码、llama.cpp 与模型。

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

替换已存在的 `rime_llm.so` 时必须「先删再复制」（`install_llm.sh` 已经这样做）。原地覆盖会让 macOS 缓存的旧代码签名与新内容对不上，加载时内核直接 `SIGKILL (Code Signature Invalid)`，输入法一启动就崩，反复崩溃后系统会把它从「已启用输入法」里移除。
恢复方法：删掉并重新复制 `.so` 后，运行 `Squirrel --disable-input-source im.rime.inputmethod.Squirrel.Hans`、`--enable-input-source …`、`--select-input-source …`，必要时到「系统设置 → 键盘 → 输入法」里重新添加。

## 为什么能直接加载

Squirrel 的签名带 `disable-library-validation`，且它的 `librime-lua.dylib` 导出全部 `lua_*` 符号（内嵌 Lua 5.4.6），所以自己编译的 Lua C 模块可以直接加载，不需要同一开发者签名。

## 与 Windows 版的差异

- 没有 UIA/COM 光标上文读取；`llm_context()` 恒返回 `nil`，上文来自 Rime 的 `commit_history`（本会话内上屏的内容）。
- `use_mmap` 字段在 llama.cpp b11632 里已改成 `load_mode`。
- 日志与默认模型路径改为 POSIX。

## 实测（Apple Silicon，CPU，4 线程）

- 模型加载约 1 秒；10 条同音词用例首选 10/10；单次打分约 20 ms（3 个候选，无预解码优化）。
- 4/6/8 线程耗时相同但 CPU 占用翻倍，推荐 4 线程。
- 测试脚本：`smoke_test.lua`（无需模型）、`model_test.lua`（需要 Qwen3.5-0.8B-Q4_K_M.gguf）。
  用自编译的官方 Lua 5.4.6 解释器运行：`lua model_test.lua <so 所在目录> <模型路径> <日志目录> 4`。

## 内存：关闭权重重排（`use_extra_bufts = false`）

llama.cpp 默认会把权重重排成更适合 CPU 的布局，模型因此不能再用文件映射，变成约 500 MB 的私有内存。实测（同样 300 次打分，结果一致）：

| | 内存占用 | 单次打分 |
|---|---|---|
| 重排开 | 869 MB | 约 20 ms |
| 重排关（当前） | **374 MB** | 约 27 ms |

`port_to_mac.py` 默认生成「重排关」的版本。想要更快、不在乎内存，去掉那行 `mparams.use_extra_bufts = false;` 重新编译即可。

## 可选：Metal GPU 推理（实验）

默认是 CPU 推理。Apple Silicon 上可以改用 Metal，构建时加 `-DRIME_LLM_METAL=ON`（着色器库内嵌进 `.so`，不依赖外部文件）：

```bash
cmake -G Ninja -S . -B build_metal -DRIME_LLM_METAL=ON && cmake --build build_metal --target rime_llm
```

实测（M1 Pro，Qwen3.5-0.8B Q4_K_M，同样的 300 次打分，结果一致，首选 10/10）：

| | CPU（默认） | Metal |
| --- | --- | --- |
| 单次打分 | 约 27 ms | **约 13 ms** |
| 300 次打分的 CPU 时间 | 30.2 秒 | **0.9 秒** |
| 内存占用 | 372 MB | 417 MB |
| 首次加载 | 约 1 秒 | 约 9 秒（系统第一次编译着色器），之后约 1 秒（有缓存） |

注意：llama.cpp 的 Metal 设备对象会在进程退出的静态析构里断言「所有缓冲都已释放」。如果退出时模型还没释放，进程会 abort，也就是**每次输入法退出都会产生一次崩溃报告**。所以 `rime_llm.so` 在模块卸载（`__gc`）和进程退出（`atexit`，在模型加载之后注册，保证先于 ggml 的静态析构）时都会释放模型。

## 空闲自动卸载

模型加载后会占约 320~400 MB 的内存，不打字时也一直占着。`llm_rerank/idle_unload_minutes`（默认 20，0 = 不卸载）：超过这么多分钟没有任何按键，就释放模型和上下文，下次打字时自动加载回来。

实测（M1 Pro）：卸载后 Squirrel 从约 409 MB 降到约 85 MB（Metal 版）或 373 → 53 MB（CPU 版）；重新加载约 0.5~0.9 秒（系统缓存是热的时候），这段时间不重排，也不阻塞输入。连续打字等于没有这个功能。

实现要点：C++ 里一个计时线程用条件变量睡到「最早可能过期」的时刻才醒，不轮询；每次按键由处理器调用 `touch()` 刷新「最近使用」，所以只打短拼音（不触发重排）也不会被误判为空闲；加载时上屏的预解码记录会清掉并重新触发。

同时修了两处会让「重新加载」失效的问题：
1. 处理器以前在调用预解码之前就记下「这个上文已预解码」，模型还没加载好时那次调用什么都没做，记录却已写上，加载完之后上文没变就再也不补预解码。现在只有预解码真的排上才记录。
2. 预解码遇到另一个预解码正在跑时，原版直接丢弃自己（可能是最新的请求），留下的反而是旧上文。现在会把最新的请求记成待办，当前预解码结束后接着做。

## Lua 层（`lua/ai_rerank_filter.lua`、`lua/ai_rerank_processor.lua`）

移植自上游的 `llm_filter.lua` / `llm_processor.lua`，并带上了为全拼做的适配（按覆盖长度分组、四字两阶段）。融合打分逻辑保持不变，其余改动：

- **开关**：方案开关 `ai_rerank`（`Control+Shift+5` 在当前输入框临时开关，或方案菜单 F4 / Control+` 里的「AI 关/开」），**默认开**（鼠须管每个输入框是独立会话，默认关会让新输入框里看起来没生效）。关闭时处理器直接放行、过滤器惰性透传，不加载模型。
- **不取尽候选**：只取前 `scan_limit`（80）个候选做重排，其余惰性透传。雾凇词库大，输入单个字母时候选数以万计，原版会一次取尽。
- **默认只对 3 个字母及以上触发**（`code_pattern: [a-z]{3,}`），避开置顶词（`d`→的）和简拼。
- **隐私**：不写任何含输入内容的文件。删掉了训练语料、事件日志、`debug_fusion`（会写上文片段）、词频落盘。上文只来自 Rime 的 `commit_history`，不读取任何应用里的文字。
- 修复：引擎清空提交历史后，旧上文不再残留。
- 第二阶段不做繁简转换（雾凇词库本身是简体）。

## 安装

```bash
./install.sh                     # 配置与 Lua（先备份，再安装）
llm-mac/install_llm.sh           # rime_llm.so 与模型（校验模型 SHA-256 后复制）
# 重启输入法后生效；AI 默认开启，Control+Shift+5 在当前输入框临时开/关
```

## 测试

用自编译的官方 Lua 5.4.6 运行（需要真实的 `rime_llm.so` 与模型）：

- `smoke_test.lua`：模块接口（无需模型）
- `model_test.lua`：模型打分合理性与耗时
- `filter_test.lua`：用模拟的 Rime 环境端到端测过滤器与处理器（开关、两音节重排、四字两阶段、空上文、scan_limit、编辑键重置、不写明文文件）

## 不阻塞输入（延迟与崩溃修复）

实测日志里出现过超过 100 ms 的打分（最慢 761 ms），原因和对应的处理：

| 原因 | 处理 |
| --- | --- |
| 打分在主线程上等后台预解码释放锁 | `score` 用 `try_lock`，拿不到锁就直接返回 `nil, "busy"`，这次按键保持原顺序 |
| 上文没预解码好，主线程现场解码（约 40~55 ms） | 第一阶段调用 `score(ctx, cands, false)`：没预解码好就返回 `nil, "unprepared"`，Lua 补一次异步预解码；下一次按键重排 |
| 上屏后新上文要到下一次按键才触发预解码 | 处理器在同步完 `commit_history` 之后立刻再触发一次预解码 |
| 四字第二阶段每个字母都现场解码（约 100 ms） | 退格时（输入串变短）跳过；剩余拼音少于 4 个字母不跑；第二阶段只用最后 8 个字作为上文；第一阶段按「上文+候选」缓存 |

另外修复了一个**崩溃**：第二阶段用到的翻译器曾被缓存成 Lua 模块级变量，在多个输入框之间共享，引擎销毁后再用会段错误。现在存在每个引擎自己的 `env` 里。`llm_rerank/stage2: false` 可以一键关闭第二阶段。

## 状态

- [x] 编译通过，冒烟测试通过
- [x] 真实模型：10/10 首选，单次打分约 20 ms
- [x] Lua 层移植，模拟环境端到端测试 19/19 通过
- [x] 在真实 Squirrel 里加载并生效（开关默认开；标记 ◇ 重排首选、◈ 两阶段首选）
