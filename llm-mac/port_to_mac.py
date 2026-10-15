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
                    "mparams.load_mode = LLAMA_LOAD_MODE_MMAP;\n        mparams.n_gpu_layers = 0;  // CPU 推理（与上游一致）\n        mparams.use_extra_bufts = false;  // 关闭权重重排：权重直接用文件映射，不再复制成私有内存（省约 500 MB）")

# ---- 不阻塞输入：打分不在主线程上等锁，上文没预解码好时可选择直接跳过 ----
def patch(old, new):
    global text
    assert text.count(old) == 1, f"patch anchor not unique/found: {old[:60]!r}"
    text = text.replace(old, new)

# 跳过标志（仅主线程读写）
patch("static int g_score_log_cnt = 0;",
      "static int g_score_log_cnt = 0;\n"
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

open(dst, "w", encoding="utf8").write(text)
print("ok:", dst, len(text.split("\n")), "lines")
