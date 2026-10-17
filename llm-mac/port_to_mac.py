#!/usr/bin/env python3
"""把上游 rime_llm.cpp（Windows）机械转换成 macOS 版 rime_llm_mac.cpp。
保留推理核心与 Lua 绑定；光标上文读取（UIA/COM）换成不读任何文本的桩。
用法：python3 -I port_to_mac.py <上游 rime_llm.cpp> <输出 rime_llm_mac.cpp>
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
L = open(src, encoding="utf8").read().split("\n")


def find(pred, start=0):
    for i in range(start, len(L)):
        if pred(L[i]):
            return i
    raise SystemExit("marker not found")


def func_end(i):
    """从函数起始行 i 起，找到顶格的 '}' 行。"""
    return find(lambda s: s == "}", i)


out = []
# 1. 头部：去掉 windows/COM/UIA 的 include 与 pragma
h_end = find(lambda s: 'UIAutomationCore.lib' in s)
out.append("""/*
 * rime_llm_mac.cpp — rime-llm-rerank 的 macOS 移植（由 scripts/port_to_mac.py 从上游机械转换）
 * 上游：https://github.com/zhanghaozhecn/rime-llm-rerank （署名许可，作者 zhanghaozhecn）
 * 改动：去掉 Windows 的 UIA/COM 光标上文读取（换成不读任何文本的桩，Lua 侧回落 commit_history）；
 *       日志、默认模型路径改为 POSIX；不改推理与打分逻辑。
 */
#include <unistd.h>
#include <sys/stat.h>
#include <cstdio>
""")
i = h_end + 1

# 2. 从头部之后复制到 default_model_path 之前
dm = find(lambda s: s.startswith("static std::string default_model_path()"))
out += L[i:dm]
out.append("""static std::string default_model_path() {
  const char *home = getenv("HOME");
  if (home && *home)
    return std::string(home) + "/Library/Rime/Qwen3.5-0.8B-Q4_K_M.gguf";
  return "Qwen3.5-0.8B-Q4_K_M.gguf";
}""")
i = func_end(dm) + 1

# 3. log_msg 换成 POSIX 版（只记录调用方传入的格式化文本；上游调用点不含输入内容）
lm = find(lambda s: s.startswith("static void log_msg("), i)
out += L[i:lm]
out.append("""static void log_msg(const char * fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    std::string path;
    if (!g_log_dir.empty()) {
        path = g_log_dir + "/rime_llm_log.txt";
    } else {
        const char * t = getenv("TMPDIR");
        path = std::string(t && *t ? t : "/tmp/") + "rime_llm_log.txt";
    }
    // 日志轮转：>5MB 改名 .old（单文件轮转）
    struct stat st;
    if (stat(path.c_str(), &st) == 0 && st.st_size > 5ll * 1024 * 1024) {
        std::string oldp = path + ".old";
        remove(oldp.c_str());
        rename(path.c_str(), oldp.c_str());
    }
    FILE * f = fopen(path.c_str(), "a");
    if (f) { fprintf(f, "%s\\n", buf); fclose(f); }
}""")
i = func_end(lm) + 1

# 4. ctxlink 整段换成桩
ns_start = find(lambda s: s.startswith("namespace ctxlink {"), i)
# 往上回退到分隔注释块的起点（连续的以 // 开头的行）
cs = ns_start
while cs - 1 >= i and L[cs - 1].startswith("//"):
    cs -= 1
out += L[i:cs]
ns_end = find(lambda s: s.startswith("}  // namespace ctxlink"), ns_start)
out.append("""// ============================================================
// 光标上文旁路（macOS 版：桩）
// Windows 版通过 UIA/COM 读取前台应用光标前文本；macOS 版不读取任何应用文本，
// llm_context 恒返回 nil，Lua 侧回落 Rime 自己的 commit_history（本会话内上屏过的内容）。
// ============================================================
namespace ctxlink {
static void ensure_started() {}
static void kick() {}
static void edit_reset() {}
static bool pick(std::string &, const char *&) { return false; }
}  // namespace ctxlink""")
i = ns_end + 1

# 5. fg_changed / click_happened 换成桩
fg = find(lambda s: s.startswith("static int lua_fg_changed("), i)
out += L[i:fg]
out.append("""static int lua_fg_changed(lua_State * L) {
    // macOS：Squirrel 每个客户端应用/输入框独立会话，commit_history 本就不跨会话，无需检测
    lua_pushboolean(L, 0);
    return 1;
}""")
i = func_end(fg) + 1
ck = find(lambda s: s.startswith("static int lua_click_happened("), i)
out += L[i:ck]
out.append("""static int lua_click_happened(lua_State * L) {
    lua_pushboolean(L, 0);
    return 1;
}""")
i = func_end(ck) + 1

rest = "\n".join(L[i:])
rest = rest.replace('extern "C" __declspec(dllexport) int luaopen_rime_llm',
                    'extern "C" __attribute__((visibility("default"))) int luaopen_rime_llm')
out.append(rest)
text = "\n".join(out)
assert "mparams.use_mmap = 1;" in text
# llama.cpp b11632 起 use_mmap 字段改为 load_mode 枚举
text = text.replace("mparams.use_mmap = 1;",
                    "mparams.load_mode = LLAMA_LOAD_MODE_MMAP;\n        mparams.n_gpu_layers = RIME_LLM_GPU_LAYERS;  // 0 = CPU 推理（默认，与上游一致）；cmake -DRIME_LLM_METAL=ON 时为 99\n        mparams.use_extra_bufts = g_use_repack;  // 默认关闭权重重排（Lua 属性 use_repack 可在加载前打开）：权重直接用文件映射，不再复制成私有内存（省约 500 MB）；-DRIME_LLM_REPACK=ON 可开启")

# ---- 不阻塞输入：打分不在主线程上等锁，上文没预解码好时可选择直接跳过 ----
def patch(old, new):
    global text
    assert text.count(old) == 1, f"patch anchor not unique/found: {old[:60]!r}"
    text = text.replace(old, new)

# 跳过标志（仅主线程读写）
patch("#include <cstdio>\n",
      "#include <cstdio>\n\n"
      "#ifndef RIME_LLM_REPACK\n"
      "#define RIME_LLM_REPACK 0       // 1 = 开启 llama.cpp 的 CPU 权重重排（更快，但模型变成私有内存，约多 500 MB）\n"
      "#endif\n"
      "#ifndef RIME_LLM_GPU_LAYERS\n"
      "#define RIME_LLM_GPU_LAYERS 0   // 0 = CPU；cmake -DRIME_LLM_METAL=ON 时由构建系统定义为 99\n"
      "#endif\n")

patch("static int g_score_log_cnt = 0;",
      "static int g_score_log_cnt = 0;\n"
      "static bool g_use_repack = (RIME_LLM_REPACK != 0);   // 是否做 CPU 权重重排：更快，但模型变成私有内存（约多 500 MB）；加载前设置才有效\n"
      "static bool g_score_skipped = false;       // 本次 score 被跳过（锁被占用 / 上文未预解码）\n"
      "static bool g_score_require_prep = false;  // 本次 score 要求上文已预解码，否则跳过\n"
      "static const char * g_score_skip_reason = \"\";  // 跳过原因：busy（后台预解码持锁）| unprepared（上文未预解码）")

# 1) 后台预解码持锁时不等待，直接放弃本次重排（候选保持原顺序）
patch("    std::lock_guard<std::mutex> lock(g_mutex);\n"
      "    auto t1 = std::chrono::high_resolution_clock::now();",
      "    // 不在主线程上等锁：后台预解码持锁时直接放弃本次重排，避免输入卡顿\n"
      "    std::unique_lock<std::mutex> lock(g_mutex, std::try_to_lock);\n"
      "    if (!lock.owns_lock()) { g_score_skipped = true; g_score_skip_reason = \"busy\"; return; }\n"
      "    auto t1 = std::chrono::high_resolution_clock::now();")

# 2) 要求预解码就绪时，没命中就不现场解码上文（约 40~55 ms），直接跳过
patch("    bool use_prep = g_prep_ready && ctx_ids == g_prep_ctx && g_seq0_gen == g_prep_gen;",
      "    bool use_prep = g_prep_ready && ctx_ids == g_prep_ctx && g_seq0_gen == g_prep_gen;\n"
      "    if (!use_prep && g_score_require_prep) { g_score_skipped = true; g_score_skip_reason = \"unprepared\"; return; }")

# 3) lua_score：可选第 3 个参数 allow_sync（false = 上文没预解码好就返回 nil），被跳过时返回 nil
patch("    std::vector<double> scores;\n    try {\n        score_batch(ctx_ids, cand_ids, scores);",
      "    std::vector<double> scores;\n"
      "    // 第 3 个参数 allow_sync（默认 true）：false 时，上文没有预解码好就不现场解码，直接返回 nil\n"
      "    g_score_require_prep = (lua_gettop(L) >= 3 && lua_isboolean(L, 3) && !lua_toboolean(L, 3));\n"
      "    g_score_skipped = false;\n"
      "    try {\n        score_batch(ctx_ids, cand_ids, scores);")
patch("    // 按分数降序排列\n",
      "    if (g_score_skipped) { lua_pushnil(L); lua_pushstring(L, g_score_skip_reason); return 2; }\n\n    // 按分数降序排列\n")


# ---- 退出时释放模型与上下文（Metal 后端的设备对象在静态析构时断言缓冲已释放，否则进程退出时 abort）----
patch("static void load_model_async() {",
      "static void unload_model();   // 前向声明\n"
      "static std::atomic<bool> g_atexit_registered{false};\n"
      "// 进程退出时先于 ggml 的静态析构释放模型：atexit 要在模型加载之后（设备对象构造之后）注册，\n"
      "// 后注册的先执行。否则 ggml_metal_device_free 的断言会让进程在退出时 abort。\n"
      "static void cleanup_at_exit() {\n"
      "    unload_model();\n"
      "    llama_backend_free();\n"
      "}\n"
      "static int lua_gc_module(lua_State *) { cleanup_at_exit(); return 0; }\n\n"
      "static void load_model_async() {")
patch("        g_loaded.store(true);\n        g_loading.store(false);\n        log_msg(\"model ready",
      "        if (!g_atexit_registered.exchange(true)) std::atexit(cleanup_at_exit);\n"
      "        g_loaded.store(true);\n        g_loading.store(false);\n        log_msg(\"model ready")
patch("    lua_pushcfunction(L, lua_newindex);\n    lua_setfield(L, -2, \"__newindex\");",
      "    lua_pushcfunction(L, lua_newindex);\n    lua_setfield(L, -2, \"__newindex\");\n"
      "    lua_pushcfunction(L, lua_gc_module);   // 模块卸载 / Lua 状态关闭时释放模型\n"
      "    lua_setfield(L, -2, \"__gc\");")


# ---- 空闲自动卸载：超过 idle_unload_sec 没有任何 score/prepare 调用，就释放模型与上下文 ----
# 下次 prepare/score 会懒加载回来（约 0.5~1 秒，期间不重排，不阻塞输入）。0 = 关闭（默认，Lua 侧按配置设置）。
patch("static std::atomic<bool> g_atexit_registered{false};",
      r"""// ---- 空闲自动卸载 ----
static std::atomic<long long> g_last_use_ms{0};
static std::atomic<long long> g_idle_unload_ms{0};
static std::atomic<bool>      g_idle_stop{false};
static std::atomic<bool>      g_idle_thread_started{false};
// 这两个对象故意泄漏（堆上分配、不析构）：进程退出时 detached 线程可能还在用它们，不能让静态析构先销毁
static std::mutex              & g_idle_mu = *new std::mutex;
static std::condition_variable & g_idle_cv = *new std::condition_variable;

static long long now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
static void touch_use() { g_last_use_ms.store(now_ms()); }

static void idle_watchdog() {
    std::unique_lock<std::mutex> lk(g_idle_mu);
    while (!g_idle_stop.load()) {
        long long limit = g_idle_unload_ms.load();
        if (limit <= 0 || !g_loaded.load()) { g_idle_cv.wait(lk); continue; }   // 没有要盯的：一直睡到被唤醒
        long long since = now_ms() - g_last_use_ms.load();
        if (since < limit) {                                                   // 睡到最早可能过期的时刻再看
            g_idle_cv.wait_for(lk, std::chrono::milliseconds(limit - since + 50));
            continue;
        }
        // 超过空闲时限：只在没有人持锁（没有打分/预解码在跑）时卸载，并在锁内再确认一次
        std::unique_lock<std::mutex> m(g_mutex, std::try_to_lock);
        if (m.owns_lock() && g_loaded.load() && now_ms() - g_last_use_ms.load() >= limit) {
            if (g_ctx)   { llama_free(g_ctx); g_ctx = nullptr; }
            if (g_model) { llama_model_free(g_model); g_model = nullptr; }
            g_vocab = nullptr;
            g_loaded.store(false);
            g_prep_ready = false;
            g_prep_ctx.clear();
            g_prep_logits.clear();
            log_msg("model unloaded (idle %lld s)", limit / 1000);
        } else {
            g_idle_cv.wait_for(lk, std::chrono::seconds(5));                   // 有人在用：稍后再看
        }
    }
}
static void ensure_idle_watchdog() {
    if (!g_idle_thread_started.exchange(true)) std::thread(idle_watchdog).detach();
    g_idle_cv.notify_all();
}

static std::atomic<bool> g_atexit_registered{false};""")
patch("static void cleanup_at_exit() {\n    unload_model();",
      "static void cleanup_at_exit() {\n    g_idle_stop.store(true);\n    g_idle_cv.notify_all();\n    unload_model();")
patch("        if (!g_atexit_registered.exchange(true)) std::atexit(cleanup_at_exit);\n",
      "        if (!g_atexit_registered.exchange(true)) std::atexit(cleanup_at_exit);\n        touch_use();\n        ensure_idle_watchdog();   // 模型已加载：唤醒空闲计时线程\n")
patch("static int lua_prepare(lua_State * L) {\n", "static int lua_prepare(lua_State * L) {\n    touch_use();\n")
patch("static int lua_score(lua_State * L) {\n",   "static int lua_score(lua_State * L) {\n    touch_use();\n")
patch("static int lua_index(lua_State * L) {",
      "// 高精度单调时钟（毫秒，带小数），测试用：量 P50/P95 延迟\n"
      "static int lua_now_ms(lua_State * L) {\n"
      "    lua_pushnumber(L, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count());\n"
      "    return 1;\n"
      "}\n\n"
      "// 每次按键由 Lua 处理器调用：刷新“最近使用”时间（只做一次原子写，几乎没有开销）\n"
      "static int lua_touch(lua_State * L) { (void)L; touch_use(); return 0; }\n\n"
      "static int lua_index(lua_State * L) {")
patch("    else if (strcmp(key, \"n_seq_max\") == 0) lua_pushinteger(L, g_n_seq_max);\n    else lua_pushnil(L);",
      "    else if (strcmp(key, \"n_seq_max\") == 0) lua_pushinteger(L, g_n_seq_max);\n    else if (strcmp(key, \"touch\") == 0) lua_pushcfunction(L, lua_touch);\n    else if (strcmp(key, \"use_repack\") == 0) lua_pushboolean(L, g_use_repack ? 1 : 0);\n    else if (strcmp(key, \"now_ms\") == 0) lua_pushcfunction(L, lua_now_ms);\n    else if (strcmp(key, \"idle_unload_sec\") == 0) lua_pushinteger(L, (lua_Integer)(g_idle_unload_ms.load() / 1000));\n    else lua_pushnil(L);")
patch("    else if (strcmp(key, \"log_dir\") == 0)    g_log_dir = luaL_checkstring(L, 3);  // RIME 用户目录",
      "    else if (strcmp(key, \"log_dir\") == 0)    g_log_dir = luaL_checkstring(L, 3);  // RIME 用户目录\n"
      "    else if (strcmp(key, \"use_repack\") == 0) g_use_repack = lua_toboolean(L, 3) != 0;\n"
      "    else if (strcmp(key, \"idle_unload_sec\") == 0) {   // 空闲多少秒后卸载模型，0 = 不卸载\n"
      "        g_idle_unload_ms.store((long long)luaL_checkinteger(L, 3) * 1000);\n"
      "        touch_use();\n"
      "        ensure_idle_watchdog();\n"
      "    }")


# ---- 预解码：被丢弃的最新请求要记下来，等当前预解码结束后接着做 ----
# 原版在 try_lock 失败时直接放弃，如果持锁的是另一个（已过期的）预解码，留下的就是旧上文的结果。
patch("static std::atomic<bool> g_atexit_registered{false};",
      r"""// ---- 预解码的“最新待办” ----
static std::mutex                g_pending_mu;
static std::vector<llama_token>  g_pending_ctx;
static int                       g_pending_seq = 0;   // 0 = 没有待办

static std::atomic<bool> g_atexit_registered{false};""")
patch("static void prepare(const std::vector<llama_token> & ctx_ids, int seq) {",
      "static void prepare_impl(const std::vector<llama_token> & ctx_ids, int seq) {")
patch("""    if (!lock.owns_lock()) {
        log_msg("prepare: SKIP score in progress (seq=%d ctx_tok=%d)",
                seq, (int)ctx_ids.size());
        return;
    }""",
      """    if (!lock.owns_lock()) {
        // 有人持锁（打分，或另一个预解码）：不丢掉，记成“最新待办”，由持锁的预解码结束后接着做
        std::lock_guard<std::mutex> pl(g_pending_mu);
        g_pending_ctx = ctx_ids;
        g_pending_seq = seq;
        return;
    }""")
patch("static int lua_prepare(lua_State * L) {\n    touch_use();\n",
      r"""// 执行预解码；执行期间如果有更新的请求被挡在外面，就接着做最新的那一个（过期的跳过）。
// 再次被挡住（持锁的是打分）就停下，待办留给下一次 prepare 调用。
static void prepare(const std::vector<llama_token> & ctx_ids, int seq) {
    prepare_impl(ctx_ids, seq);
    for (;;) {
        std::vector<llama_token> c;
        int sq = 0;
        {
            std::lock_guard<std::mutex> pl(g_pending_mu);
            if (g_pending_seq == 0) break;
            c = std::move(g_pending_ctx);
            sq = g_pending_seq;
            g_pending_seq = 0;
        }
        if (sq != g_prep_seq.load()) continue;     // 已被更新的请求取代
        prepare_impl(c, sq);
        std::lock_guard<std::mutex> pl(g_pending_mu);
        if (g_pending_seq != 0) break;               // 又被挡住了：留给下一次
    }
}

static int lua_prepare(lua_State * L) {
    touch_use();
""")


# ---- 并发加固：模型生命周期读写锁、拿锁后再确认模型还在、可等待的计时线程停止、可重新初始化 ----
patch("#include <condition_variable>\n", "#include <condition_variable>\n#include <shared_mutex>\n")

# 1) 用「生命周期读写锁 + 可 join 的计时线程」替换前面写的计时线程实现
_a = text.index("static void idle_watchdog() {")
_b = text.index("// ---- 预解码的“最新待办” ----")
text = text[:_a] + r"""// 模型生命周期读写锁：使用方（分词 / 打分 / 预解码）持共享锁，卸载方（空闲卸载、改 model_path、退出）持独占锁。
// 保证：有人在用就不卸载；卸载进行时没人能用（拿不到共享锁就跳过这一次，而不是访问已释放的模型）。
static std::shared_mutex g_life;
static std::atomic<bool> g_shutting_down{false};   // 只在进程退出的 atexit 里置位，之后不再启动计时线程
static std::thread * g_idle_thread = nullptr;       // 受 g_idle_mu 保护；由 stop_idle_watchdog 回收

// 在已持有 g_life 独占锁时释放模型与上下文
static void free_model_exclusive() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_ctx)   { llama_free(g_ctx); g_ctx = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
    g_vocab = nullptr;
    g_loaded.store(false);
    g_prep_ready = false;
    g_prep_ctx.clear();
    g_prep_logits.clear();
}

static void idle_watchdog() {
    std::unique_lock<std::mutex> lk(g_idle_mu);
    while (!g_idle_stop.load()) {
        long long limit = g_idle_unload_ms.load();
        if (limit <= 0 || !g_loaded.load()) { g_idle_cv.wait(lk); continue; }   // 没有要盯的：一直睡到被唤醒
        long long since = now_ms() - g_last_use_ms.load();
        if (since < limit) {                                                   // 睡到最早可能过期的时刻再看
            g_idle_cv.wait_for(lk, std::chrono::milliseconds(limit - since + 50));
            continue;
        }
        // 超过空闲时限：拿独占锁（任何使用方持着共享锁时拿不到，说明有人在用），并在锁内再确认一次
        std::unique_lock<std::shared_mutex> life(g_life, std::try_to_lock);
        if (life.owns_lock() && g_loaded.load() && now_ms() - g_last_use_ms.load() >= limit) {
            if (const char * d = getenv("RIME_LLM_TEST_UNLOAD_DELAY_MS"))       // 仅测试用：拉长卸载窗口以复现竞态
                std::this_thread::sleep_for(std::chrono::milliseconds(atoi(d)));
            free_model_exclusive();
            log_msg("model unloaded (idle %lld s)", limit / 1000);
        } else {
            g_idle_cv.wait_for(lk, std::chrono::seconds(5));                   // 有人在用：稍后再看
        }
    }
}

// 停止计时线程并等它真正退出。停止标志在锁内置位，避免丢失唤醒；返回前把状态归零，允许之后重新启动
// （模块被重新初始化时 ensure_idle_watchdog 会再起一个）。
static void stop_idle_watchdog() {
    std::thread * t = nullptr;
    {
        std::lock_guard<std::mutex> l(g_idle_mu);
        g_idle_stop.store(true);
        t = g_idle_thread;
        g_idle_thread = nullptr;
    }
    g_idle_cv.notify_all();
    if (t) { if (t->joinable()) t->join(); delete t; }
    g_idle_stop.store(false);
}

static void ensure_idle_watchdog() {
    if (g_shutting_down.load()) return;
    {
        std::lock_guard<std::mutex> l(g_idle_mu);
        if (!g_idle_thread) { g_idle_stop.store(false); g_idle_thread = new std::thread(idle_watchdog); }
    }
    g_idle_cv.notify_all();
}

""" + text[_b:]

# 2) 退出 / 模块卸载：先停计时线程（等它退出），再卸载模型
patch("static void cleanup_at_exit() {\n    g_idle_stop.store(true);\n    g_idle_cv.notify_all();\n    unload_model();\n    llama_backend_free();\n}",
      "static void cleanup(bool final_exit) {\n"
      "    if (final_exit) g_shutting_down.store(true);\n"
      "    stop_idle_watchdog();\n"
      "    unload_model();\n"
      "    llama_backend_free();\n"
      "}\n"
      "static void cleanup_at_exit() { cleanup(true); }")
patch("static int lua_gc_module(lua_State *) { cleanup_at_exit(); return 0; }",
      "static int lua_gc_module(lua_State *) { cleanup(false); return 0; }   // 模块被卸载/重新初始化：不是进程退出，之后允许重新启动")

# 3) unload_model 持独占锁：等所有使用方（共享锁）结束再释放
patch("    while (g_loading.load())\n        std::this_thread::sleep_for(std::chrono::milliseconds(20));\n    std::lock_guard<std::mutex> lock(g_mutex);",
      "    while (g_loading.load())\n        std::this_thread::sleep_for(std::chrono::milliseconds(20));\n"
      "    std::unique_lock<std::shared_mutex> life(g_life);   // 等所有使用方结束，卸载期间没人能用模型\n"
      "    std::lock_guard<std::mutex> lock(g_mutex);")

# 4) lua_score / lua_prepare：整个调用期间持共享锁（分词用的 g_vocab 属于模型）
patch("static int lua_score(lua_State * L) {\n    touch_use();\n",
      "static int lua_score(lua_State * L) {\n    touch_use();\n"
      "    // 整个调用期间持共享锁：分词用到的 g_vocab 属于模型，卸载线程拿不到独占锁就不会释放它；\n"
      "    // 卸载正在进行时拿不到共享锁，这次直接跳过。\n"
      "    std::shared_lock<std::shared_mutex> life(g_life, std::try_to_lock);\n"
      "    if (!life.owns_lock()) { lua_pushnil(L); lua_pushstring(L, \"busy\"); return 2; }\n")
patch("static int lua_prepare(lua_State * L) {\n    touch_use();\n",
      "static int lua_prepare(lua_State * L) {\n    touch_use();\n"
      "    std::shared_lock<std::shared_mutex> life(g_life, std::try_to_lock);   // 同上：分词期间模型不能被卸载\n"
      "    if (!life.owns_lock()) { lua_pushboolean(L, 0); return 1; }            // 正在卸载：返回 false，处理器下次按键再请求\n")

# 5) 预解码线程：持共享锁，并且在拿到锁之后再确认模型还在
patch("    std::unique_lock<std::mutex> lock(g_mutex, std::try_to_lock);\n    if (!lock.owns_lock()) {\n        // 有人持锁（打分，或另一个预解码）",
      "    // 持共享锁：卸载线程拿不到独占锁就不会释放模型；卸载进行中、或模型还没加载好，直接放弃（之后会重新请求）\n"
      "    std::shared_lock<std::shared_mutex> life(g_life, std::try_to_lock);\n"
      "    if (!life.owns_lock() || !g_loaded.load() || !g_ctx || !g_vocab) return;\n"
      "    std::unique_lock<std::mutex> lock(g_mutex, std::try_to_lock);\n    if (!lock.owns_lock()) {\n        // 有人持锁（打分，或另一个预解码）")

# 6) 打分：拿到解码锁之后再确认模型还在
patch("    if (!lock.owns_lock()) { g_score_skipped = true; g_score_skip_reason = \"busy\"; return; }",
      "    if (!lock.owns_lock()) { g_score_skipped = true; g_score_skip_reason = \"busy\"; return; }\n"
      "    if (!g_loaded.load() || !g_ctx || !g_vocab) { g_score_skipped = true; g_score_skip_reason = \"unloaded\"; return; }")

# 7) 加载：检查并置位要原子
patch("    if (g_loaded.load() || g_loading.load()) return;\n    g_loading.store(true);",
      "    if (g_loaded.load()) return;\n    if (g_loading.exchange(true)) return;   // 原子地「检查并置位」，不会重复创建模型")


# ---- 学生模式（输入法专用小模型，字符级词表；由 Lua 属性 student_vocab 开启，llm-android 使用）----
# 词表文件一行一个字符，行号即编号（0=<pad> 1=<unk> 2=<bos>）；输入 = <bos> + 上文最后 N 个字 + 候选的字，
# 打分 = 候选各字在上文之后的对数概率之和（各位置权重均为 1，与蒸馏评测同口径）。
patch("#include <cstdio>\n",
      "#include <cstdio>\n#include <fstream>\n#include <unordered_map>\n")
patch("static int g_score_log_cnt = 0;",
      "static int g_score_log_cnt = 0;\n"
      "static bool g_student = false;                          // 学生模式：字符级词表，不用 llama 的分词器\n"
      "static std::string g_student_vocab_path;\n"
      "static std::unordered_map<std::string, int> g_student_map;\n"
      "static int g_student_ctx_chars = 30;                    // 上文最多取最后 N 个字（训练时的上限）\n"
      "static constexpr int kStudentCandMax = 12;              // 候选最多打分的字数\n"
      "static constexpr int kStudentSeqCells = 48;             // 每条序列的 KV 格数（>= <bos> + 30 + 12）")
patch("        int n_thr = g_n_threads;\n",
      "        int n_thr = g_n_threads;\n"
      "        if (g_student) {\n"
      "            g_student_map.clear();\n"
      "            std::ifstream vf(g_student_vocab_path);\n"
      "            std::string line; int id = 0;\n"
      "            while (std::getline(vf, line)) {\n"
      "                if (!line.empty() && line.back() == '\\r') line.pop_back();\n"
      "                g_student_map.emplace(line, id++);\n"
      "            }\n"
      "            if (id < 8) {\n"
      "                log_msg(\"ERROR: student vocab unreadable: %s\", g_student_vocab_path.c_str());\n"
      "                llama_model_free(g_model); g_model = nullptr; g_vocab = nullptr;\n"
      "                g_loading.store(false);\n"
      "                return;\n"
      "            }\n"
      "            log_msg(\"student mode: vocab=%d ctx_chars=%d\", id, g_student_ctx_chars);\n"
      "        }\n")
patch("        cparams.n_ctx           = g_n_ctx;",
      "        cparams.n_ctx           = g_student ? g_n_seq_max * kStudentSeqCells : g_n_ctx;")
patch("static std::vector<llama_token> tokenize(const char * text) {\n",
      "// 学生模式分词：按 UTF-8 字符查表，查不到记 <unk>\n"
      "static std::vector<llama_token> student_chars(const char * text) {\n"
      "    std::vector<llama_token> out;\n"
      "    const unsigned char * p = (const unsigned char *)text;\n"
      "    while (*p) {\n"
      "        int len = (*p < 0x80) ? 1 : (*p >> 5) == 6 ? 2 : (*p >> 4) == 14 ? 3 : (*p >> 3) == 30 ? 4 : 1;\n"
      "        std::string ch((const char *)p, len);\n"
      "        auto it = g_student_map.find(ch);\n"
      "        out.push_back(it == g_student_map.end() ? 1 : it->second);\n"
      "        for (int i = 0; i < len && *p; i++) p++;\n"
      "    }\n"
      "    return out;\n"
      "}\n\n"
      "static std::vector<llama_token> tokenize(const char * text) {\n"
      "    if (g_student) return student_chars(text);\n")
patch("static std::vector<llama_token> ctx_token_ids(const char * context) {\n",
      "static std::vector<llama_token> ctx_token_ids(const char * context) {\n"
      "    if (g_student) {\n"
      "        auto ids = student_chars(context);\n"
      "        if (ids.size() < 2) return {};                       // 上文不足两个字：不重排（与训练时 min_ctx 一致）\n"
      "        if ((int)ids.size() > g_student_ctx_chars) ids.erase(ids.begin(), ids.end() - g_student_ctx_chars);\n"
      "        ids.insert(ids.begin(), 2);                          // <bos>\n"
      "        return ids;\n"
      "    }\n")
# 学生模式的打分：逐字位置并行解码，各位置权重 1
patch("static void score_batch(const std::vector<llama_token> & ctx_ids,",
      "static void score_student_locked(const std::vector<llama_token> & ctx_ids,\n"
      "                                 const std::vector<std::vector<llama_token>> & cands,\n"
      "                                 std::vector<double> & out) {\n"
      "    int n = (int)cands.size(), ctx_len = (int)ctx_ids.size(), vs = llama_n_vocab(g_vocab);\n"
      "    auto * mem = llama_get_memory(g_ctx);\n"
      "    bool use_prep = g_prep_ready && ctx_ids == g_prep_ctx && g_seq0_gen == g_prep_gen;\n"
      "    std::vector<float> ctx_logits;\n"
      "    if (!use_prep) {\n"
      "        llama_memory_clear(mem, false);\n"
      "        llama_batch cb = llama_batch_init(ctx_len, 0, 1);\n"
      "        for (int j = 0; j < ctx_len; j++) { cb.token[j] = ctx_ids[j]; cb.pos[j] = j; cb.n_seq_id[j] = 1; cb.seq_id[j][0] = 0; }\n"
      "        cb.logits[ctx_len - 1] = 1; cb.n_tokens = ctx_len;\n"
      "        if (llama_decode(g_ctx, cb) == 0) {\n"
      "            g_seq0_gen++;\n"
      "            float * cl = llama_get_logits_ith(g_ctx, ctx_len - 1);\n"
      "            if (cl) ctx_logits.assign(cl, cl + vs);\n"
      "        }\n"
      "        llama_batch_free(cb);\n"
      "        if (ctx_logits.empty()) return;\n"
      "        g_prep_gen = g_seq0_gen; g_prep_ctx = ctx_ids; g_prep_logits = ctx_logits; g_prep_ready = true;\n"
      "    } else {\n"
      "        ctx_logits = g_prep_logits;\n"
      "    }\n"
      "    std::vector<double> ce(n, 0);\n"
      "    float m0; double lse0;\n"
      "    logits_normalizer(ctx_logits.data(), vs, m0, lse0);\n"
      "    for (int i = 0; i < n; i++) ce[i] = ce_target(ctx_logits.data(), cands[i][0], m0, lse0);\n"
      "    std::vector<int> act, seq_of(n, -1);\n"
      "    int maxlen = 1;\n"
      "    for (int i = 0; i < n; i++) if (cands[i].size() >= 2) { seq_of[i] = (int)act.size() + 1; act.push_back(i); maxlen = std::max(maxlen, (int)cands[i].size()); }\n"
      "    maxlen = std::min(maxlen, kStudentCandMax);\n"
      "    for (int ci : act) llama_memory_seq_cp(mem, 0, seq_of[ci], 0, -1);\n"
      "    bool failed = false;\n"
      "    for (int p = 1; p < maxlen && !failed; p++) {\n"
      "        std::vector<int> cur;\n"
      "        for (int ci : act) if ((int)cands[ci].size() > p) cur.push_back(ci);\n"
      "        if (cur.empty()) break;\n"
      "        llama_batch b = llama_batch_init((int)cur.size(), 0, (int)cur.size());\n"
      "        for (int k = 0; k < (int)cur.size(); k++) {\n"
      "            int ci = cur[k];\n"
      "            b.token[k] = cands[ci][p - 1]; b.pos[k] = ctx_len + p - 1;\n"
      "            b.n_seq_id[k] = 1; b.seq_id[k][0] = seq_of[ci]; b.logits[k] = 1;\n"
      "        }\n"
      "        b.n_tokens = (int)cur.size();\n"
      "        if (llama_decode(g_ctx, b) == 0) {\n"
      "            for (int k = 0; k < (int)cur.size(); k++) {\n"
      "                float * l = llama_get_logits_ith(g_ctx, k);\n"
      "                if (l) ce[cur[k]] += cross_entropy(l, vs, cands[cur[k]][p]); else ce[cur[k]] = 1e10;\n"
      "            }\n"
      "        } else {\n"
      "            failed = true; g_prep_ready = false;\n"
      "            log_msg(\"WARN: student decode failed at position %d\", p);\n"
      "        }\n"
      "        llama_batch_free(b);\n"
      "    }\n"
      "    for (int ci : act) llama_memory_seq_rm(mem, seq_of[ci], 0, -1);\n"
      "    for (int i = 0; i < n; i++) out[i] = (!failed && ce[i] < 1e9) ? -ce[i] : -1e10;\n"
      "}\n\n"
      "static void score_batch(const std::vector<llama_token> & ctx_ids,")
patch("    if (!g_loaded.load() || !g_ctx || !g_vocab) { g_score_skipped = true; g_score_skip_reason = \"unloaded\"; return; }\n    auto t1",
      "    if (!g_loaded.load() || !g_ctx || !g_vocab) { g_score_skipped = true; g_score_skip_reason = \"unloaded\"; return; }\n"
      "    if (g_student) { score_student_locked(ctx_ids, cands, scores_out); return; }\n    auto t1")
# 候选数上限：工作序列要占 seq 1..M，所以最多 n_seq_max - 1 个（原写法在候选数 = n_seq_max 时会越界）
patch("    if (n > g_n_seq_max) n = g_n_seq_max;",
      "    if (n > g_n_seq_max - 1) n = g_n_seq_max - 1;")
patch("    else if (strcmp(key, \"use_repack\") == 0) g_use_repack = lua_toboolean(L, 3) != 0;",
      "    else if (strcmp(key, \"use_repack\") == 0) g_use_repack = lua_toboolean(L, 3) != 0;\n"
      "    else if (strcmp(key, \"student_vocab\") == 0) { g_student_vocab_path = luaL_checkstring(L, 3); g_student = !g_student_vocab_path.empty(); }\n"
      "    else if (strcmp(key, \"student_ctx\") == 0) g_student_ctx_chars = (int)luaL_checkinteger(L, 3);")

# 学生模型的 GGUF 自带的 SPM 词表没有换行符，llama_tokenize 会抛异常：预热改为直接解码一个 <bos>
patch("            int n_tokens = llama_tokenize(g_vocab, warmup, (int)strlen(warmup),\n"
      "                                           tokens, 4, true, true);",
      "            int n_tokens = 0;\n"
      "            if (g_student) { tokens[0] = 2; n_tokens = 1; }   // <bos>\n"
      "            else n_tokens = llama_tokenize(g_vocab, warmup, (int)strlen(warmup),\n"
      "                                           tokens, 4, true, true);")

# 学生模型解码一次上文只要几毫秒：打分时遇到后台预解码持锁，最多等 30 ms 而不是直接跳过；
# 上文没预解码好也现场解码（0.8B 的这两条保护是因为它解码上文要 40~55 ms）。
patch("    std::unique_lock<std::mutex> lock(g_mutex, std::try_to_lock);\n"
      "    if (!lock.owns_lock()) { g_score_skipped = true; g_score_skip_reason = \"busy\"; return; }",
      "    std::unique_lock<std::mutex> lock(g_mutex, std::try_to_lock);\n"
      "    if (g_student) {\n"
      "        for (int i = 0; i < 60 && !lock.owns_lock(); i++) {\n"
      "            std::this_thread::sleep_for(std::chrono::microseconds(500));\n"
      "            lock.try_lock();\n"
      "        }\n"
      "    }\n"
      "    if (!lock.owns_lock()) { g_score_skipped = true; g_score_skip_reason = \"busy\"; return; }")
open(dst, "w", encoding="utf8").write(text)
print("ok:", dst, len(text.split("\n")), "lines")
