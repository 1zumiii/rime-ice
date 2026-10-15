# rime-llm-rerank 的 Android 移植（Trime，已可日常使用）

目标设备：ASUS Zenfone 10（骁龙 8 Gen 2，16 GB，Android 15）。目标前端：[Trime（同文输入法）](https://github.com/osfans/trime)。

## 已验证的事实

**Trime 的 nightly 构建**（arm64，v3.3.12-73）：

- 内嵌 **librime 1.17.0**、**librime-lua（Lua 5.4.6）**、**librime-octagram**、**librime-predict**，全部静态链接在 `librime_jni.so` 里。
- `librime_jni.so` **导出了 155 个 Lua 符号**（`lua_*` / `luaL_*` / `luaopen_*`），我们的 `rime_llm.so` 需要的全部都在；并且导入了 `dlopen`/`dlsym`，说明内嵌的 Lua 开了 C 模块动态加载。
- 用户数据目录：`/sdcard/Android/data/com.osfans.trime/files/rime`。
- 尚未验证：从应用私有目录 `dlopen` 我们的 `.so` 在 Android 15 上是否被允许（Android 14 起要求动态加载的文件只读）。

**推理核心在手机上能跑**（`rime_llm.so` 用 NDK r27d 交叉编译，arm64，`+dotprod+i8mm+fp16`）：

| 项目 | 结果 |
| --- | --- |
| 正确性 | 10 条同音词用例首选 **10/10**，与 Mac 完全一致 |
| 加载 | 约 0.7 秒（系统缓存热的时候） |
| 内存 | 私有脏页约 362 MB，模型文件映射约 501 MB（可回收） |
| 预解码之后只打分 | **约 6 ms**（P95 6.6 ms） |
| 预解码本身（上屏后后台跑） | 约 100~150 ms（4 线程） |
| 同步全流程（现场解码上文再打分） | 约 63~130 ms，同一配置前后差一倍（手机调度和限频波动很大） |

**线程数与绑核**（同步全流程，P50 / P95）：

- **4 线程、不绑核最稳**：约 64 / 90 ms。
- 线程越多越糟：6 线程 93 / 225 ms，7 线程 113 / 334 ms，8 线程 241 / 1799 ms（最大 2.4 秒）。原因是 3 个 A510 小核加上 ggml 线程池的忙等待。
- **线程数超过绑定的核数会直接卡死**（绑 4 个核开 5 个线程，跑了 8 分钟没结果）。
- 绑大核比不绑核更慢。
- **权重重排（`use_repack`）在手机上不值得**：延迟没有改善（P50 85 ms），私有内存却多约 500 MB。保持关闭。

## 第一档配置在 Trime 上已部署并编译成功

用 `llm-android/deploy_trime.sh` 把本仓库的配置推到手机（`adb push` 到 `/sdcard/Android/data/com.osfans.trime/files/rime`），再通过 Trime 自带的广播 `com.osfans.trime.action.DEPLOY` 触发部署，不需要在手机上点界面：

```bash
llm-android/deploy_trime.sh --with-gram        # 首次：配置 + 语法模型（约 380 MB）
llm-android/deploy_trime.sh                    # 之后改了配置：只推配置
```

前提：Trime 已安装，并且走完首次启动引导，在第 1 步选「**使用应用专属存储空间**」。

手机上编译（骁龙 8 Gen 2，约 12~20 秒）出来的结果与 Mac 一致：

| 检查项 | 手机 | Mac |
| --- | --- | --- |
| `rime_ice.table.bin` 大小 | 60,656,260 字节 | 60,656,260 字节 |
| 拼写规则 / 简拼规则 | 55 / 2 | 55 / 2 |
| 过滤器、处理器顺序 | 一致 | |
| librime 版本 | **1.17.0** | 1.16.0 |

Trime 的 librime 1.17.0 比鼠须管的 1.16.0 新，所以 `translator/max_sentences`（长句候选数）可以在手机上启用。

## 已实现的方案：常驻推理进程 + 改版 Trime

Trime 的数据目录挂载为 `noexec`，Trime 也不可调试（`run-as` 被拒），所以 `rime_llm.so` 没法从外面放进去，必须进 APK。再加上稳定性方面的考虑，最后做成**推理在独立进程、Trime 里只放一个薄客户端**：

```
Trime（改版 APK）                              rimellmd（shell 身份，adb / Shizuku 拉起）
  Lua 脚本（和 Mac/PC 同一份）                    监督进程：看护工作进程，被杀/崩溃/无响应则退避重启，记录退出原因
    └ librime_llm.so（客户端，140 KB）  ──socket──▶  工作进程：llama.cpp 引擎（与 Mac 同一份）+ 状态文件
  工具栏 AI 徽标（状态/启停/Shizuku 启动）          127.0.0.1:17920，令牌认证
```

- **客户端**（`daemon/rime_llm_client.cpp`）对 Lua 暴露与 `rime_llm.so` 完全相同的接口，所以 `ai_rerank_*.lua` 基本不用改。所有 I/O 都有时限，连不上就返回「不可用」（候选保持原顺序，输入不被拖慢），指数退避重连。
- **守护进程**（`daemon/rimellmd.cpp`）内嵌一个私有 Lua 状态直接调用 Mac 上测过的引擎，不重写推理。打分和轻量请求（心跳、touch、is_ready、prepare、配置）用两个 Lua 状态、两把锁，慢打分不会挡住它们。
- **认证**：每次启动生成随机令牌，写进 Trime 的应用专属目录（其他应用读不到）；只监听 127.0.0.1。Trime 需要 `INTERNET` 权限（改版 APK 已加）。
- **手动启停**：工具栏的 `● AI` 徽标，点一下切换方案开关 `ai_rerank`；关闭时守护进程立刻卸载模型并拒绝推理（只剩几 MB 待命），开启时立刻加载。不再有自动卸载。选择会被记住（`save_options`），**新装默认关闭**。长按看详情。
- **状态面板**：守护进程每 5 秒（手动切换后 15 秒内 0.3 秒一次）写 `ai_status.json`，徽标读它：绿 = 在线，黄 = 加载/重启中，灰 = 已关闭/待机，红 = 离线。详情里有内存、打分延迟、跳过/错误次数、累计重启次数和上次退出原因。
- **自动拉起**：徽标变红（离线）时，点一下经 Shizuku 以 shell 身份启动守护进程（首次会弹 Shizuku 授权）；键盘弹出时发现离线，每分钟最多自动尝试一次。重启手机后需要先启动 Shizuku。
- **熄屏联动**：Trime 在亮屏/熄屏时设置 Rime 选项 `screen_off`，Lua 转给守护进程（默认没有单独的熄屏时限，保留接口）。

### 手机上的调优结论（实测，Zenfone 10 / 骁龙 8 Gen 2，空闲时、每次换一组新候选）

- **该模型有按顺序处理的循环层**，打分约 100 ms 的下限与线程数基本无关（1/2/3 线程都是约 133 ms）。**4 线程会因预解码和打分同时忙等而偶发数秒卡顿**，2~3 线程没有，所以默认 2 线程。
- 候选数是最有效的旋钮：5 个候选 p50≈118 ms，3 个≈78 ms，2 个≈61 ms。手机上用 3 个。
- 四字词的第二阶段要现场解码，每次 100~500 ms，**手机上关闭**（Mac/PC 不受影响）。
- 引擎默认按 128 上下文 / 12 并发序列预留，手机上收紧到 96 / 6：堆内存 374→234 MB，延迟不变。RSS 里另有约 512 MB 是模型文件映射页（干净页，可被内核随时回收）。
- 上文 token 10→6，缩短上屏后的后台预解码。

这些手机专属设置不改仓库里的 Mac/PC 配置，而是放在 `trime/*.overlay.yaml`，部署时追加到暂存的 `*.custom.yaml`（`deploy_trime.sh`）。

### 文件

| 路径 | 作用 |
| --- | --- |
| `daemon/rimellmd.cpp` | 守护进程（监督 + 工作） |
| `daemon/rime_llm_client.cpp` | Trime 里的客户端库（`librime_llm.so`） |
| `daemon/proto.h` | 线路协议（带总时限的帧读写） |
| `daemon/rimellmctl.sh` | 电脑端 `deploy / start / stop / restart / status / log` |
| `daemon/test_daemon.py` | 端到端测试：认证、非法输入、正确性、并发；`--chaos` 再做 `kill -9` 和 `SIGSTOP` 恢复测试 |
| `daemon/bench_daemon.py` | 真实打分延迟基准（每次换新候选） |
| `trime/patches/0001-ai-rerank-daemon.patch` | 对 Trime `ad5a14be` 的改动：`INTERNET`、亮灭屏接收器、AI 徽标、Shizuku 启动 |
| `trime/build_apk.sh` | 从源码到签名 APK 的完整流程；`trime/sign_apk.sh` 只做对齐和签名 |
| `trime/*.overlay.yaml`、`trime/trime.custom.yaml` | 手机专属配置叠加、键盘高度补丁 |
| `deploy_trime.sh` | 推送配置并触发部署 |

注意：覆盖安装改版 APK 之后，输入法服务要等键盘弹出才会起来，**部署广播只有服务在运行时才会被接收**，所以装完要先点开一个输入框再部署。换签名密钥必须先卸载原来的 Trime（会清空它的数据目录，先备份用户词库）。

## 构建与测试

需要 Android NDK r27d（`27.3.13750724`）。

```bash
# 交叉编译 rime_llm.so（llama.cpp 与转换后的 rime_llm_mac.cpp 在 ../../rime-llm-mac-port/，见 llm-mac/README.md）
cmake -G Ninja -S llm-android -B build_android \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-30 -DANDROID_STL=c++_static
cmake --build build_android --target rime_llm
```

对接 Trime 时，把 `-DRIME_LLM_HOST_LIB=<librime_jni.so>` 传给 CMake，让加载器把 `lua_*` 解析到它。

`bench_android.lua`、`sweep.sh`、`prep_bench.sh` 是手机上的基准脚本（用 `adb push` 到 `/data/local/tmp`，由 `adb shell` 运行）；`elfsyms.py` 是没有 `nm` 时读 ELF 动态符号表的小工具。

注意：不要让线程数超过绑定的核数，也不要在手机上开太多线程。
