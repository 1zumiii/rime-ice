# rime-llm-rerank 的 Android 移植（Trime，已可日常使用）

目标设备：ASUS Zenfone 10（骁龙 8 Gen 2，16 GB，Android 15）。目标前端：[Trime（同文输入法）](https://github.com/osfans/trime)。

## 已验证的事实

Trime 的 nightly 构建（arm64，v3.3.12-73）：

- 内嵌 librime 1.17.0、librime-lua（Lua 5.4.6）、librime-octagram 和 librime-predict，均静态链接在 `librime_jni.so` 中。
- `librime_jni.so` 导出 155 个 Lua 符号（`lua_*`、`luaL_*`、`luaopen_*`），`rime_llm.so` 所需符号全部在内。它同时导入了 `dlopen` 和 `dlsym`，说明内嵌的 Lua 启用了 C 模块的动态加载。
- 用户数据目录：`/sdcard/Android/data/com.osfans.trime/files/rime`。
- 该数据目录挂载为 `noexec`，`.so` 不能放在其中加载。将其打包进 APK 的原生库目录，再用 `package.loadlib("librime_llm.so", ...)` 即可加载，后面的方案以此为基础。

推理核心在手机上可运行（`rime_llm.so` 用 NDK r27d 交叉编译，arm64，`+dotprod+i8mm+fp16`）：

| 项目 | 结果 |
| --- | --- |
| 正确性 | 10 条同音词用例首选 10/10，与 Mac 一致 |
| 加载 | 约 0.7 秒（系统缓存已预热时） |
| 内存 | 私有脏页约 362 MB，模型文件映射约 501 MB（可回收） |
| 预解码之后只打分 | 约 6 ms（P95 6.6 ms） |
| 预解码本身（上屏后在后台运行） | 约 100~150 ms（4 线程） |
| 同步全流程（现场解码上文再打分） | 约 63~130 ms，同一配置前后相差一倍（手机调度和限频波动大） |

线程数与绑核（同步全流程，P50 / P95）：

- 4 线程、不绑核最稳：约 64 / 90 ms。
- 线程越多越差：6 线程 93 / 225 ms，7 线程 113 / 334 ms，8 线程 241 / 1799 ms（最大 2.4 秒）。原因是 3 个 A510 小核，加上 ggml 线程池的忙等待。
- **线程数超过绑定的核数会导致无响应**（绑定 4 个核、开 5 个线程，运行 8 分钟仍无结果）。
- 绑定大核比不绑核更慢。
- 权重重排（`use_repack`）在手机上收益为零：延迟没有改善（P50 85 ms），私有内存却多约 500 MB。保持关闭。

## 第一档配置的部署

`llm-android/deploy_trime.sh` 通过 `adb push` 将本仓库的配置推送到手机的 `/sdcard/Android/data/com.osfans.trime/files/rime`，再用 Trime 自带的广播 `com.osfans.trime.action.DEPLOY` 触发部署，无需在手机上操作界面：

```bash
llm-android/deploy_trime.sh --with-gram        # 首次：配置 + 语法模型（约 380 MB）
llm-android/deploy_trime.sh                    # 之后修改了配置：仅推送配置
```

前提：Trime 已安装并完成首次引导，在第 1 步选择“使用应用专属存储空间”。

手机端编译（骁龙 8 Gen 2，约 12~20 秒）的结果与 Mac 一致：

| 检查项 | 手机 | Mac |
| --- | --- | --- |
| `rime_ice.table.bin` 大小 | 60,656,260 字节 | 60,656,260 字节 |
| 拼写规则 / 简拼规则 | 55 / 2 | 55 / 2 |
| 过滤器、处理器顺序 | 一致 | |
| librime 版本 | 1.17.0 | 1.16.0 |

Trime 的 librime 1.17.0 比鼠须管的 1.16.0 新，因此 `translator/max_sentences`（长句候选数）可在手机端启用。

## 方案：常驻推理进程与改版 Trime

Trime 的数据目录为 `noexec`，Trime 本身也不可调试（`run-as` 被拒），因此 `rime_llm.so` 无法从外部放入，只能打包进 APK。同时出于稳定性考虑，最终采用推理独立成进程、Trime 内仅保留轻量客户端的结构：

```
Trime（改版 APK）                              rimellmd（shell 身份，由 adb 或 Shizuku 启动）
  Lua 脚本（与 Mac、PC 为同一份）                 监督进程：看护工作进程，被终止、崩溃或无响应时退避重启并记录退出原因
    └ librime_llm.so（客户端，140 KB）  ──socket──▶  工作进程：llama.cpp 引擎（与 Mac 为同一份）+ 状态文件
  工具栏 AI 徽标（状态、启停、经 Shizuku 启动）      127.0.0.1:17920，令牌认证
```

- 客户端（`daemon/rime_llm_client.cpp`）向 Lua 暴露的接口与 `rime_llm.so` 完全相同，因此 `ai_rerank_*.lua` 基本无需改动。所有 I/O 均有时限，无法连接时返回“不可用”，候选保持原顺序，输入不受影响。客户端按指数退避重连。
- 守护进程（`daemon/rimellmd.cpp`）内嵌一个私有 Lua 状态，直接调用 Mac 端已测试的引擎，不重写推理。打分与轻量请求（心跳、touch、is_ready、prepare、配置）使用两个 Lua 状态和两把锁，慢打分不会阻塞后者。
- 认证：每次启动生成随机令牌，写入 Trime 的应用专属目录（其他应用不可读）。守护进程仅监听 127.0.0.1。Trime 需要 `INTERNET` 权限，改版 APK 已加入。
- 手动启停：点按工具栏的 `● AI` 徽标，切换方案开关 `ai_rerank`。关闭时守护进程立即卸载模型并拒绝推理，仅保留数 MB 的待命进程；开启时立即加载。不自动卸载。选择会被保留（`save_options`），新安装默认关闭。长按徽标可查看详情。
- 状态面板：守护进程每 5 秒写一次 `ai_status.json`（手动切换后的 15 秒内，每 0.3 秒写一次），徽标读取该文件。绿色为在线，黄色为加载或重启中，灰色为已关闭或待机，红色为离线。详情包含内存、打分延迟、跳过和错误次数、累计重启次数以及上次退出原因。
- 自动启动：徽标为红色（离线）时，点按即可经 Shizuku 以 shell 身份启动守护进程，首次会弹出 Shizuku 的授权请求。键盘弹出时若发现离线，每分钟最多自动尝试一次。手机重启后，须先启动 Shizuku。
- 孤儿保护：Trime 被卸载后，其数据目录随之消失，无法再通过它关闭守护进程。守护进程检测到该目录连续 10 分钟不存在（可用 `--orphan-sec` 调整）时自行退出，监督进程收到退出码 77 后同样结束，不再重启。重新安装 Trime 后，点按红色徽标即可再次启动。已用临时目录和另一个端口验证：目录删除 15 秒后，两个进程均退出。
- 熄屏联动：Trime 在亮屏或熄屏时设置 Rime 选项 `screen_off`，由 Lua 转交给守护进程。默认不设单独的熄屏时限，仅保留该接口。

### 手机端调优结论

测试条件：Zenfone 10（骁龙 8 Gen 2），手机空闲，每次更换一组新候选。

- 该模型含按顺序处理的循环层，打分约 100 ms 的下限与线程数基本无关（1、2、3 线程均约 133 ms）。4 线程会因预解码与打分同时忙等而出现偶发的数秒卡顿，2~3 线程没有，因此默认使用 2 线程。
- 候选数影响最大：5 个候选 P50 约 118 ms，3 个约 78 ms，2 个约 61 ms。手机端使用 3 个。
- 四字词的第二阶段需要现场解码，每次 100~500 ms，因此在手机端关闭，Mac 和 PC 不受影响。
- 引擎默认按 128 上下文、12 并发序列预留，手机端收紧为 96 和 6：堆内存由 374 MB 降至 234 MB，延迟不变。RSS 中另有约 512 MB 为模型文件映射页（干净页，内核可随时回收）。
- 上文 token 数由 10 降为 6，缩短上屏后的后台预解码。

这些手机端专属设置不改动仓库中 Mac、PC 使用的配置，而是写在 `trime/*.overlay.yaml` 中，由 `deploy_trime.sh` 在部署时追加到暂存的 `*.custom.yaml`。

### 文件

| 路径 | 作用 |
| --- | --- |
| `daemon/rimellmd.cpp` | 守护进程（监督进程与工作进程） |
| `daemon/rime_llm_client.cpp` | Trime 内的客户端库（`librime_llm.so`） |
| `daemon/proto.h` | 线路协议（带总时限的帧读写） |
| `daemon/rimellmctl.sh` | 电脑端的 `deploy`、`start`、`stop`、`restart`、`status`、`log` |
| `daemon/test_daemon.py` | 端到端测试：认证、非法输入、正确性、并发；加 `--chaos` 还会做 `kill -9` 和 `SIGSTOP` 的恢复测试 |
| `daemon/bench_daemon.py` | 真实打分延迟基准（每次更换新候选） |
| `trime/patches/0001-ai-rerank-daemon.patch` | 对 Trime `ad5a14be` 的改动：`INTERNET` 权限、亮灭屏接收器、AI 徽标、Shizuku 启动、流式键盘布局 |
| `trime/build_apk.sh` | 从源码到签名 APK 的完整流程；`trime/sign_apk.sh` 仅负责对齐和签名 |
| `trime/*.overlay.yaml` | 手机端专属配置，部署时追加到对应的 `*.custom.yaml` |
| `trime/gen_tongwenfeng_patch.py` | 生成 `trime/tongwenfeng.trime.custom.yaml`（GBoard 风格布局补丁），不要手工编辑生成结果 |
| `trime/trime.custom.yaml` | `trime` 主题的键盘高度补丁 |
| `docs/preview.png` | README 使用的 Android 预览图 |
| `deploy_trime.sh` | 推送配置并触发部署 |

覆盖安装改版 APK 之后，输入法服务须等到键盘弹出才会启动，而部署广播只有在服务运行时才会被接收。因此装完后应先打开任意输入框，再部署。

**更换签名密钥须先卸载原有的 Trime。** 卸载会清空其数据目录，应事先备份用户词库。

## 学生模型（输入法专用小模型）

由 Windows 侧蒸馏得到的约 16.5M 参数的字符级 Transformer（GPT-2 结构），用于替代 Qwen3.5-0.8B 做候选排序。评测中混合准确率 92.1%（0.8B 为 92.7%），手机上 Q8_0、2 线程、6 个候选含进程间通信的打分中位约 11 ms（0.8B 约 60~80 ms，且只打 3 个候选）。

- 启用：把 `student.gguf`（建议 Q8_0）和词表 `student.vocab.txt` 放进 Trime 的用户目录，然后让守护进程重启（先结束旧进程，再点工具栏的 AI 徽标启动）。启动脚本发现这两个文件就自动使用学生模式，否则仍用 0.8B。徽标长按的详情会显示当前模型。
- 回退：删除这两个文件并重启守护进程即可回到 0.8B；此时候选数自动限制为 3 个（`--n-seq-max 4`），不会因为配置里的候选数变多而变慢。
- 实现：推理核心的补丁在 `llm-mac/port_to_mac.py` 里（Lua 属性 `student_vocab` 开启）。输入为 `<bos>` + 上文最后 30 个字 + 候选的字，不使用 llama 的分词器；打分为候选各字对数概率之和，各位置权重为 1，与蒸馏评测同口径；候选的字按位置并行解码，上文的预解码沿用原有机制。
- 注意：学生的训练上下文上限为 64，上文最多取 30 个字；候选最多打分前 12 个字。
- 验证：`daemon/test_student.py` 在手机上单独起一个守护进程（端口 17921），核对几组同音词的排序并测延迟。
- 已知情况：Q8_0 量化对准确率的影响尚待评测确认；难例上学生比 0.8B 弱约 4 个百分点。

## 手机端配置更新

改版 Trime 在工具栏左侧三个点打开的面板里提供“从仓库更新”入口（与原有的“更新配置”不同，后者只是重新部署本地配置），打开后可填写仓库地址与分支（默认 `1zumiii/rime-ice-Custom` 的 `custom` 分支），点击“立即更新”即完成下载、覆盖和重新部署。

- 地址格式：`https://github.com/用户/仓库`、`用户/仓库`、`.../tree/分支`，或直接给 `.zip` 链接。仓库须公开。
- 覆盖范围与 `deploy_trime.sh` 一致：排除其他平台文件、文档、构建产物、个人数据和大模型；`llm-android/trime/*.overlay.yaml` 追加到同名 `.custom.yaml`，`llm-android/trime/*.custom.yaml`（主题补丁）直接放入用户目录；新装默认关闭 AI 的处理也一并执行。
- 备份与回退：覆盖前把将被改动的文件备份到应用私有目录，只保留上一个版本。更新后 45 秒内进程被重启两次（即连续崩溃两次）自动回退，部署本身失败时立即回退，也可在界面上手动回退。回退会恢复被改动的文件、删除新增的文件并强制重新编译。
- 需要联网，因此改版 Trime 声明了 `INTERNET` 权限。更新界面不对外导出，只能从该面板进入。
- 相关源码：补丁中的 `update/ConfigUpdater.kt`、`update/ConfigUpdateActivity.kt`、`ime/switches/SwitchOptionWindow.kt` 中的入口。

## 构建与测试

整套产物（改版 APK、客户端库、守护进程）由 `trime/build_apk.sh` 一次完成。前提：JDK 17、Android NDK r27d（`27.3.13750724`）、CMake 3.31.6，以及 `../../rime-llm-mac-port/` 中的 llama.cpp 与转换后的 `rime_llm_mac.cpp`（见 [llm-mac/README.md](../llm-mac/README.md)）。

单独编译守护进程和客户端：

```bash
cmake -G Ninja -S llm-android -B build_android \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-30 \
  -DRIME_LLM_HOST_LIB=<librime_jni.so>
cmake --build build_android --target rimellmd rime_llm_client
```

`RIME_LLM_HOST_LIB` 指向 Trime 的 `librime_jni.so`，使加载器把客户端中的 `lua_*` 符号解析到它。`rime_llm` 目标是进程内版本的引擎，在手机端不再使用，保留用于对照测试。

`bench_android.lua`、`sweep.sh`、`prep_bench.sh` 是手机端的基准脚本，经 `adb push` 放到 `/data/local/tmp` 后由 `adb shell` 运行。`elfsyms.py` 用于在没有 `nm` 时读取 ELF 动态符号表。

线程数不得超过绑定的核数，手机端也不宜开过多线程。
