# rime-llm-rerank 的 Android 移植（实验，进行中）

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

**尚未验证**：在手机上实际打字时这些 Lua 过滤器是否都正常加载（需要在 Trime 里用 `rime_ice` 方案打字，看最近使用优先、emoji 在第二页、模糊音、语法模型等是否生效）；AI 重排在手机上还没有接入（`rime_llm.so` 没有放进去，相关组件会安静地什么也不做）。

## 设计结论（待实现）

- **每个按键的开销很小（约 6 ms），耗电发热的大头是上屏后的后台预解码**。手机上可考虑降低 `max_tokens`（10 → 6）缩短预解码。
- 四字两阶段的第二阶段要现场解码，在手机上偏重，建议默认关闭。
- 熄屏联动：前端在熄屏时调用 `setRimeOption("screen_off", true)`，Lua 通过 `option_update_notifier` 收到后临时缩短空闲超时（原来的 20 分钟超时保留作兜底）。需要给 Trime 加一个广播接收器。
- 崩溃隔离：把推理放进同一应用里的独立进程服务，输入法进程通过本地套接字请求；服务崩溃/被杀只意味着「这次不重排」，由 Binder 死亡回调自动拉起。
- 状态面板：读取 `ActivityManager.getHistoricalProcessExitReasons()`（Android 11+）显示进程每次退出的系统原因，加上服务心跳、加载/卸载原因、延迟分布、跳过次数、内存/温度/省电状态，以及应用是否被厂商电池优化限制。

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
