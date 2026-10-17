// rimellmd — 输入法 AI 重排的常驻推理进程（Android）。
// 以 shell 身份由 adb / Shizuku 拉起，监听 127.0.0.1，Trime 里的客户端 librime_llm.so 通过它打分。
// 引擎就是 macOS 上测过的那份（rime_llm_mac.cpp）：这里内嵌一个私有 Lua 状态，直接调用它的 score/prepare/…，
// 不改引擎，也就不引入新的推理/并发缺陷。
//
// 两种角色（同一个二进制）：
//   rimellmd --supervise <参数>   监督进程：拉起并看护子进程；子进程被杀/崩溃/无响应则带退避重启，并记录退出原因
//   rimellmd <参数>               工作进程：加载模型、处理请求、定期写状态文件
//
// 稳定性约束：所有 I/O 有时限；请求大小有上限；并发连接有上限；异常不外抛；SIGPIPE 忽略；
//            连接必须先通过令牌认证（令牌写在只有 Trime 能读的应用专属目录里）。
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include "llama.h"
#include "proto.h"

extern "C" int luaopen_rime_llm(lua_State * L);   // 来自 rime_llm_mac.cpp

namespace {

struct Options {
    bool supervise = false;
    int port = proto::kDefaultPort;
    std::string model;
    std::string student_vocab;                  // 非空 = 学生模式（字符级小模型），model 是学生的 GGUF
    std::string rime_dir;                       // 状态文件、令牌文件所在目录（Trime 的 rime 用户目录）
    std::string log_dir = "/data/local/tmp/rimellm";
    int threads = 4;
    int max_ctx = 10;
    int n_ctx = 0;                              // 0 = 用引擎默认（128）；手机上候选少，可以收紧以省内存
    int n_seq_max = 0;                          // 0 = 用引擎默认（12）
    int idle_sec = 0;                           // 屏幕亮着时的空闲卸载时限；0 = 不自动卸载
    int screen_off_sec = 0;                     // 熄屏后的空闲卸载时限；0 = 不单独设（手动启停为主，默认不自动卸载）
    int orphan_sec = 600;                       // 状态目录（Trime 的数据目录）消失超过这么久就自己退出；0 = 不检查
    int restarts = 0;
    std::string last_exit = "none";
};
Options g_opt;
std::vector<std::string> g_raw_args;            // 监督进程把原始参数原样传给子进程

std::atomic<bool> g_stop{false};
std::atomic<bool> g_orphan{false};            // 因为状态目录长期消失（Trime 被卸载）而退出：监督进程看到退出码 77 就不再重启
constexpr int kOrphanExit = 77;
void on_term(int) { g_stop.store(true); }

long long now_s() { return (long long)time(nullptr); }

void logf(const char * fmt, ...) __attribute__((format(printf, 1, 2)));
void logf(const char * fmt, ...) {
    char buf[512];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    time_t t = time(nullptr); struct tm tmv; localtime_r(&t, &tmv);
    char ts[32]; strftime(ts, sizeof ts, "%m-%d %H:%M:%S", &tmv);
    fprintf(stderr, "%s [%d] %s\n", ts, (int)getpid(), buf);
    fflush(stderr);
}

// 原子地写文本文件（先写临时文件再 rename；rename 失败则直接写）
void write_file_atomic(const std::string & path, const std::string & data, mode_t mode) {
    std::string tmp = path + ".tmp";
    int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    if (fd >= 0) {
        ssize_t w = write(fd, data.data(), data.size());
        fchmod(fd, mode);
        close(fd);
        if (w == (ssize_t)data.size() && rename(tmp.c_str(), path.c_str()) == 0) return;
        unlink(tmp.c_str());
    }
    fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    if (fd >= 0) { ssize_t w = write(fd, data.data(), data.size()); (void)w; close(fd); }
}

std::string json_escape(const std::string & s) {
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') { o.push_back('\\'); o.push_back(c); }
        else if ((unsigned char)c < 0x20) o.push_back(' ');
        else o.push_back(c);
    }
    return o;
}

long read_rss_kb() {
    FILE * f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256]; long v = -1;
    while (fgets(line, sizeof line, f)) if (sscanf(line, "VmRSS: %ld kB", &v) == 1) break;
    fclose(f);
    return v;
}

std::string status_path() { return g_opt.rime_dir.empty() ? "" : g_opt.rime_dir + "/ai_status.json"; }
std::string token_path()  { return g_opt.rime_dir.empty() ? "" : g_opt.rime_dir + "/llm_token"; }

// ============================================================ 工作进程

// 两个私有 Lua 状态（各自一把锁）：打分可能要几百毫秒（手机 CPU 上现场解码），
// 不能让心跳、touch、is_ready、prepare、配置这些轻量请求排在它后面。引擎本身的全局状态有自己的锁，两个状态可以同时调用。
lua_State *        g_L = nullptr;     // 打分专用
lua_State *        g_L2 = nullptr;    // 其余请求
std::mutex         g_lua_mu;          // Lua 状态不是线程安全的：同一个状态上的请求串行
std::mutex         g_lua2_mu;
int                g_mod_ref = LUA_NOREF, g_mod_ref2 = LUA_NOREF;
std::string        g_token;
long long          g_start_ms = 0;
std::atomic<int>   g_clients{0};
std::atomic<long long> g_requests{0}, g_errors{0}, g_scores{0}, g_skipped{0};
std::atomic<int>   g_last_score_ms{0}, g_max_score_ms{0};
std::atomic<long long> g_score_ms_sum{0};
std::atomic<bool>  g_screen_off{false};
std::atomic<long long> g_fast_status_until_ms{0};   // 手动切换后一小段时间内加快状态文件的刷新，让面板及时看到加载完成
std::atomic<bool>  g_enabled{true};      // 手动启停：false = 模型已卸载，拒绝一切推理（进程只剩待命）
std::atomic<int>   g_idle_normal{1200};
std::atomic<long long> g_last_req_s{0};
int                g_listen_fd = -1;

// ---- Lua 调用封装（调用方已持有 g_lua_mu） ----
struct StackGuard {
    lua_State * L; int top;
    explicit StackGuard(lua_State * l) : L(l), top(lua_gettop(l)) {}
    ~StackGuard() { lua_settop(L, top); }
};

void push_module(lua_State * L, int ref) { lua_rawgeti(L, LUA_REGISTRYINDEX, ref); }

void set_prop_int(const char * key, long long v) {
    std::lock_guard<std::mutex> lk(g_lua2_mu);
    StackGuard g(g_L2);
    push_module(g_L2, g_mod_ref2);
    lua_pushinteger(g_L2, (lua_Integer)v);
    lua_setfield(g_L2, -2, key);          // 键不在表里，走 __newindex → 引擎的 setter
}
void set_prop_str(const char * key, const std::string & v) {
    std::lock_guard<std::mutex> lk(g_lua2_mu);
    StackGuard g(g_L2);
    push_module(g_L2, g_mod_ref2);
    lua_pushstring(g_L2, v.c_str());
    lua_setfield(g_L2, -2, key);
}

bool call_is_ready() {
    std::lock_guard<std::mutex> lk(g_lua2_mu);
    StackGuard g(g_L2);
    push_module(g_L2, g_mod_ref2);
    lua_getfield(g_L2, -1, "is_ready");
    if (lua_pcall(g_L2, 0, 1, 0) != 0) { g_errors++; return false; }
    return lua_toboolean(g_L2, -1) != 0;
}

bool call_prepare(const std::string & ctx) {
    std::lock_guard<std::mutex> lk(g_lua2_mu);
    StackGuard g(g_L2);
    push_module(g_L2, g_mod_ref2);
    lua_getfield(g_L2, -1, "prepare");
    lua_pushlstring(g_L2, ctx.data(), ctx.size());
    if (lua_pcall(g_L2, 1, 1, 0) != 0) { g_errors++; return false; }
    return lua_toboolean(g_L2, -1) != 0;
}

void call_touch() {
    std::lock_guard<std::mutex> lk(g_lua2_mu);
    StackGuard g(g_L2);
    push_module(g_L2, g_mod_ref2);
    lua_getfield(g_L2, -1, "touch");
    if (lua_pcall(g_L2, 0, 0, 0) != 0) g_errors++;
}

// 返回回复字段："R" c1 s1 c2 s2 …（已按分数降序）或 "N" 原因
std::vector<std::string> call_score(const std::string & ctx, const std::vector<std::string> & cands, bool allow_sync) {
    std::lock_guard<std::mutex> lk(g_lua_mu);
    StackGuard g(g_L);
    long long t0 = proto::mono_ms();
    push_module(g_L, g_mod_ref);
    int mod = lua_gettop(g_L);
    lua_getfield(g_L, mod, "score");
    lua_pushlstring(g_L, ctx.data(), ctx.size());
    lua_createtable(g_L, (int)cands.size(), 0);
    for (size_t i = 0; i < cands.size(); i++) {
        lua_pushlstring(g_L, cands[i].data(), cands[i].size());
        lua_rawseti(g_L, -2, (lua_Integer)i + 1);
    }
    lua_pushboolean(g_L, allow_sync ? 1 : 0);
    if (lua_pcall(g_L, 3, 2, 0) != 0) { g_errors++; return {"N", "error"}; }
    int r1 = lua_gettop(g_L) - 1, r2 = lua_gettop(g_L);
    if (!lua_istable(g_L, r1)) {
        g_skipped++;
        const char * why = lua_isstring(g_L, r2) ? lua_tostring(g_L, r2) : "";
        return {"N", why};
    }
    std::vector<std::string> ranked;
    int n = (int)lua_rawlen(g_L, r1);
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(g_L, r1, i);
        size_t len = 0; const char * s = lua_tolstring(g_L, -1, &len);
        ranked.emplace_back(s ? std::string(s, len) : std::string());
        lua_pop(g_L, 1);
    }
    // 取分数（引擎的 get_scores：候选文本 → 分数）
    lua_getfield(g_L, mod, "get_scores");
    bool have_scores = (lua_pcall(g_L, 0, 1, 0) == 0 && lua_istable(g_L, -1));
    std::vector<std::string> out;
    out.push_back("R");
    for (auto & c : ranked) {
        out.push_back(c);
        char buf[40]; double sc = 0;
        if (have_scores) { lua_getfield(g_L, -1, c.c_str()); sc = lua_tonumber(g_L, -1); lua_pop(g_L, 1); }
        snprintf(buf, sizeof buf, "%.9g", sc);
        out.push_back(buf);
    }
    int ms = (int)(proto::mono_ms() - t0);
    g_scores++;
    g_last_score_ms.store(ms);
    g_score_ms_sum += ms;
    int mx = g_max_score_ms.load();
    while (ms > mx && !g_max_score_ms.compare_exchange_weak(mx, ms)) {}
    return out;
}

// 空闲卸载时限：熄屏时用熄屏时限（0 = 不单独设，沿用亮屏时限）；时限 0 = 不自动卸载
int effective_idle() {
    return (g_screen_off.load() && g_opt.screen_off_sec > 0) ? g_opt.screen_off_sec : g_idle_normal.load();
}
void apply_idle() { set_prop_int("idle_unload_sec", effective_idle()); }

// 手动启停：关 = 把模型路径清空（引擎会立刻卸载已加载的模型），并让后面的推理请求直接被拒；开 = 还原路径，下次 prepare 时按需加载
void set_enabled(bool on) {
    if (g_enabled.exchange(on) == on) return;
    set_prop_str("model_path", on ? g_opt.model : std::string());
    g_fast_status_until_ms.store(proto::mono_ms() + 15000);
    if (on) call_prepare("。");     // 手动开启 = 马上要用：立刻开始加载模型，不等第一次按键（模型没加载时 prepare 只触发加载）
    logf("AI %s (manual)", on ? "enabled" : "disabled");
}

std::string build_status(const char * role, const char * state) {
    long long up = (proto::mono_ms() - g_start_ms) / 1000;
    long long sc = g_scores.load();
    char buf[1500];
    bool ready = (g_L != nullptr) && call_is_ready();
    snprintf(buf, sizeof buf,
        "{\"ts\":%lld,\"role\":\"%s\",\"state\":\"%s\",\"pid\":%d,\"version\":\"%s\",\"uptime_s\":%lld,"
        "\"enabled\":%s,\"model_loaded\":%s,\"rss_kb\":%ld,\"clients\":%d,\"requests\":%lld,\"errors\":%lld,"
        "\"scores\":%lld,\"skipped\":%lld,\"last_score_ms\":%d,\"avg_score_ms\":%.1f,\"max_score_ms\":%d,"
        "\"student\":%s,\"screen\":\"%s\",\"idle_unload_sec\":%d,\"restarts\":%d,\"last_exit\":\"%s\",\"last_request_s\":%lld,\"port\":%d}",
        now_s(), role, state, (int)getpid(), proto::kVersion, up, g_enabled.load() ? "true" : "false", ready ? "true" : "false", read_rss_kb(),
        g_clients.load(), g_requests.load(), g_errors.load(), sc, g_skipped.load(), g_last_score_ms.load(),
        sc ? (double)g_score_ms_sum.load() / (double)sc : 0.0, g_max_score_ms.load(),
        g_opt.student_vocab.empty() ? "false" : "true",
        g_screen_off.load() ? "off" : "on", effective_idle(),
        g_opt.restarts, json_escape(g_opt.last_exit).c_str(), g_last_req_s.load(), g_opt.port);
    return buf;
}

void status_thread() {
    long long next = 0, missing_since = 0;
    while (!g_stop.load()) {
        long long now = proto::mono_ms();
        // 孤儿保护：Trime 被卸载后，它的数据目录会消失，没人能再关掉这个进程，模型就一直占着内存。
        // 目录持续不在超过 orphan_sec 就自己退出（监督进程也跟着结束）；重新安装 Trime 后，点红色徽标即可再次拉起。
        if (g_opt.orphan_sec > 0 && !g_opt.rime_dir.empty()) {
            if (access(g_opt.rime_dir.c_str(), F_OK) == 0) missing_since = 0;
            else if (missing_since == 0) { missing_since = now; logf("rime dir %s is gone; will exit in %ds unless it comes back", g_opt.rime_dir.c_str(), g_opt.orphan_sec); }
            else if (now - missing_since >= (long long)g_opt.orphan_sec * 1000) { logf("rime dir gone for %ds: orphaned, exiting", g_opt.orphan_sec); g_orphan.store(true); g_stop.store(true); break; }
        }
        if (now >= next) {
            std::string p = status_path();
            if (!p.empty()) write_file_atomic(p, build_status("daemon", "running"), 0664);
            // 平时 5 秒一次（/sdcard 是 fuse，写得越少越省）；手动切换后的 15 秒内 0.3 秒一次
            next = now + (now < g_fast_status_until_ms.load() ? 300 : 5000);
        }
        usleep(100 * 1000);
    }
}

bool token_ok(const std::string & t) {
    if (t.size() != g_token.size()) return false;
    unsigned char d = 0;
    for (size_t i = 0; i < t.size(); i++) d |= (unsigned char)(t[i] ^ g_token[i]);
    return d == 0;
}

void handle_conn(int fd) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    bool authed = false;
    std::vector<std::string> f;
    for (;;) {
        // 空闲 120 秒没有任何请求就断开（客户端会按需自动重连）；整帧必须在 3 秒内到齐
        if (g_stop.load() || !proto::recv_frame(fd, f, 120000, 3000) || f.empty() || f[0].empty()) break;
        g_requests++;
        g_last_req_s.store(now_s());
        char op = f[0][0];
        std::vector<std::string> reply;
        if (op == 'B') {                                      // 心跳：不需要认证、不碰引擎（监督进程用）
            reply = {"PONG"};
        } else if (op == 'H') {
            if (f.size() >= 2 && token_ok(f[1])) {
                authed = true;
                reply = {"OK", std::to_string((int)getpid()), proto::kVersion};
            } else {
                proto::send_frame(fd, {"ERR", "auth"}, 1000);
                break;
            }
        } else if (!authed) {
            break;
        } else if (op == 'P' && f.size() >= 2) {
            reply = {(g_enabled.load() && call_prepare(f[1])) ? "1" : "0"};
        } else if (op == 'S' && f.size() >= 3) {
            if (!g_enabled.load()) { reply = {"N", "off"}; }
            else {
                std::vector<std::string> cands(f.begin() + 3, f.end());
                reply = call_score(f[2], cands, f[1] == "1");
            }
        } else if (op == 'I') {
            reply = {call_is_ready() ? "1" : "0"};
        } else if (op == 'T') {
            call_touch();
            reply = {"OK"};
        } else if (op == 'C' && f.size() >= 3) {
            long long v = atoll(f[2].c_str());
            if (f[1] == "idle_unload_sec" && v >= 0 && v <= 86400) { g_idle_normal.store((int)v); apply_idle(); }
            else if (f[1] == "max_ctx" && v >= 2 && v <= 64) set_prop_int("max_ctx", v);
            else if (f[1] == "min_tokens" && v >= 0 && v <= 64) set_prop_int("min_tokens", v);
            else if (f[1] == "n_threads" && v >= 1 && v <= 8) set_prop_int("n_threads", v);   // 下次加载模型时生效
            else if (f[1] == "enabled") set_enabled(v != 0);
            reply = {"OK"};
        } else if (op == 'Z' && f.size() >= 2) {              // 屏幕状态：熄屏后缩短空闲卸载时限
            g_screen_off.store(f[1] == "1");
            apply_idle();
            reply = {"OK"};
        } else if (op == 'G') {
            reply = {build_status("daemon", "running")};
        } else {
            reply = {"ERR", "op"};
        }
        if (!proto::send_frame(fd, reply, 2000)) break;
    }
    close(fd);
    g_clients--;
}

std::string make_token() {
    unsigned char b[16] = {0};
    FILE * f = fopen("/dev/urandom", "rb");
    if (f) { size_t r = fread(b, 1, sizeof b, f); (void)r; fclose(f); }
    static const char * hex = "0123456789abcdef";
    std::string t;
    for (unsigned char c : b) { t.push_back(hex[c >> 4]); t.push_back(hex[c & 15]); }
    return t;
}

int run_daemon() {
    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_term; sigaction(SIGTERM, &sa, nullptr); sigaction(SIGINT, &sa, nullptr);
    g_start_ms = proto::mono_ms();
    mkdir(g_opt.log_dir.c_str(), 0775);
    // llama.cpp 默认把每次加载的计算图细节都打到 stderr，几天就把日志撑满：只留警告和错误
    llama_log_set([](ggml_log_level lvl, const char * text, void *) {
        if (lvl == GGML_LOG_LEVEL_WARN || lvl == GGML_LOG_LEVEL_ERROR) fputs(text, stderr);
    }, nullptr);

    g_L = luaL_newstate();
    if (!g_L) { logf("cannot create lua state"); return 3; }
    luaopen_rime_llm(g_L);
    g_mod_ref = luaL_ref(g_L, LUA_REGISTRYINDEX);
    g_L2 = luaL_newstate();
    if (!g_L2) { logf("cannot create second lua state"); return 3; }
    luaopen_rime_llm(g_L2);                      // 同一份引擎（引擎状态是进程级全局的），只是另一个 Lua 入口
    g_mod_ref2 = luaL_ref(g_L2, LUA_REGISTRYINDEX);
    g_idle_normal.store(g_opt.idle_sec);
    set_prop_str("log_dir", g_opt.log_dir);
    set_prop_str("model_path", g_opt.model);
    if (!g_opt.student_vocab.empty()) set_prop_str("student_vocab", g_opt.student_vocab);
    set_prop_int("n_threads", g_opt.threads);
    set_prop_int("max_ctx", g_opt.max_ctx);
    if (g_opt.n_ctx > 0) set_prop_int("n_ctx", g_opt.n_ctx);
    if (g_opt.n_seq_max > 0) set_prop_int("n_seq_max", g_opt.n_seq_max);
    apply_idle();

    g_token = make_token();
    if (!token_path().empty()) write_file_atomic(token_path(), g_token, 0660);

    g_listen_fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    int one = 1;
    setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)g_opt.port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(g_listen_fd, (struct sockaddr *)&a, sizeof a) != 0 || listen(g_listen_fd, 8) != 0) {
        logf("bind/listen 127.0.0.1:%d failed: %s", g_opt.port, strerror(errno));
        return 2;
    }
    logf("listening on 127.0.0.1:%d model=%s threads=%d idle=%ds restarts=%d last_exit=%s",
         g_opt.port, g_opt.model.c_str(), g_opt.threads, g_opt.idle_sec, g_opt.restarts, g_opt.last_exit.c_str());

    std::thread(status_thread).detach();

    while (!g_stop.load()) {
        struct pollfd pf = {g_listen_fd, POLLIN, 0};
        int r = poll(&pf, 1, 500);
        if (r <= 0) continue;                                  // 超时/EINTR：回去检查 g_stop
        int fd = accept4(g_listen_fd, nullptr, nullptr, SOCK_CLOEXEC);
        if (fd < 0) { if (errno == EMFILE || errno == ENFILE) usleep(200 * 1000); continue; }
        if (g_clients.load() >= 8) { close(fd); continue; }    // 连接数上限：客户端通常只有 1 个
        g_clients++;
        std::thread(handle_conn, fd).detach();
    }
    logf("stopping");
    if (!status_path().empty()) write_file_atomic(status_path(), build_status("daemon", "stopped"), 0664);
    close(g_listen_fd);
    fflush(stderr);
    exit(g_orphan.load() ? kOrphanExit : 0);   // 触发引擎的 atexit 清理（释放模型）
    return 0;
}

// ============================================================ 监督进程

bool ping_child() {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)g_opt.port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    int r = connect(fd, (struct sockaddr *)&a, sizeof a);
    bool ok = false;
    if (r == 0 || errno == EINPROGRESS) {
        struct pollfd pf = {fd, POLLOUT, 0};
        if (poll(&pf, 1, 1000) == 1) {
            int err = 0; socklen_t el = sizeof err;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
            if (err == 0 && proto::send_frame(fd, {"B"}, 1000)) {
                std::vector<std::string> rep;
                ok = proto::recv_frame(fd, rep, 1500, 1500) && !rep.empty() && rep[0] == "PONG";
            }
        }
    }
    close(fd);
    return ok;
}

std::string describe_status(int st) {
    char b[64];
    if (WIFEXITED(st)) { snprintf(b, sizeof b, "exit %d", WEXITSTATUS(st)); return b; }
    if (WIFSIGNALED(st)) {
        int s = WTERMSIG(st);
        const char * n = s == SIGKILL ? "SIGKILL" : s == SIGSEGV ? "SIGSEGV" : s == SIGABRT ? "SIGABRT" :
                         s == SIGBUS ? "SIGBUS" : s == SIGTERM ? "SIGTERM" : s == SIGILL ? "SIGILL" : "signal";
        snprintf(b, sizeof b, "signal %d (%s)", s, n);
        return b;
    }
    return "unknown";
}

bool sleep_interruptible(int ms) {
    for (int i = 0; i < ms / 100 && !g_stop.load(); i++) usleep(100 * 1000);
    return !g_stop.load();
}

void write_supervisor_status(const char * state, int backoff_s) {
    if (status_path().empty()) return;
    char buf[600];
    snprintf(buf, sizeof buf,
        "{\"ts\":%lld,\"role\":\"supervisor\",\"state\":\"%s\",\"pid\":%d,\"version\":\"%s\",\"model_loaded\":false,"
        "\"restarts\":%d,\"last_exit\":\"%s\",\"backoff_s\":%d,\"port\":%d}",
        now_s(), state, (int)getpid(), proto::kVersion, g_opt.restarts, json_escape(g_opt.last_exit).c_str(), backoff_s, g_opt.port);
    write_file_atomic(status_path(), buf, 0664);
}

int run_supervisor(char ** argv) {
    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_term; sigaction(SIGTERM, &sa, nullptr); sigaction(SIGINT, &sa, nullptr);
    mkdir(g_opt.log_dir.c_str(), 0775);
    char self[512]; ssize_t n = readlink("/proc/self/exe", self, sizeof self - 1);
    if (n <= 0) { logf("readlink /proc/self/exe failed"); return 1; }
    self[n] = 0;
    int backoff = 1;
    logf("supervisor up, child=%s", self);
    while (!g_stop.load()) {
        std::vector<std::string> args = {self, "--child", "--restarts", std::to_string(g_opt.restarts), "--last-exit", g_opt.last_exit};
        for (auto & a : g_raw_args) args.push_back(a);
        std::vector<char *> av;
        for (auto & s : args) av.push_back(const_cast<char *>(s.c_str()));
        av.push_back(nullptr);
        pid_t pid = fork();
        if (pid < 0) { logf("fork failed: %s", strerror(errno)); sleep_interruptible(2000); continue; }
        if (pid == 0) { execv(self, av.data()); _exit(127); }
        (void)argv;
        long long start = proto::mono_ms();
        int fails = 0, st = 0;
        std::string reason;
        long long next_ping = start + 10000;     // 给模型、监听留足启动时间
        for (;;) {
            pid_t w = waitpid(pid, &st, WNOHANG);
            if (w == pid) { reason = describe_status(st); break; }
            if (g_stop.load()) {
                kill(pid, SIGTERM);
                for (int i = 0; i < 30; i++) { if (waitpid(pid, &st, WNOHANG) == pid) break; usleep(100 * 1000); }
                kill(pid, SIGKILL); waitpid(pid, &st, 0);
                logf("supervisor stopped");
                return 0;
            }
            long long now = proto::mono_ms();
            if (now >= next_ping) {
                next_ping = now + 3000;
                fails = ping_child() ? 0 : fails + 1;
                if (fails >= 3) {                 // 连续 3 次心跳无应答（约 10 秒）：判定无响应，强杀重启
                    logf("child %d unresponsive, killing", (int)pid);
                    kill(pid, SIGKILL); waitpid(pid, &st, 0);
                    reason = "hung (no heartbeat, killed by supervisor)";
                    break;
                }
            }
            usleep(200 * 1000);
        }
        if (WIFEXITED(st) && WEXITSTATUS(st) == kOrphanExit) {      // 工作进程因为 Trime 不见了而退出：监督进程也结束，不再重启
            logf("child exited as orphan (Trime data dir gone); supervisor exiting");
            return 0;
        }
        long long up_s = (proto::mono_ms() - start) / 1000;
        g_opt.restarts++;
        g_opt.last_exit = reason + " after " + std::to_string(up_s) + "s";
        backoff = (up_s >= 60) ? 1 : (backoff * 2 > 30 ? 30 : backoff * 2);
        logf("child exited: %s; restart in %ds (restarts=%d)", g_opt.last_exit.c_str(), backoff, g_opt.restarts);
        write_supervisor_status("restarting", backoff);
        if (!sleep_interruptible(backoff * 1000)) break;
    }
    return 0;
}

void usage() {
    fprintf(stderr,
        "usage: rimellmd [--supervise] --model PATH [--rime-dir DIR] [--port N] [--log-dir DIR] [--threads N]\n"
        "                [--max-ctx N] [--idle-sec N] [--screen-off-sec N]\n");
}

}  // namespace

int main(int argc, char ** argv) {
    bool child = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto need = [&](const char * name) -> const char * {
            if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", name); usage(); exit(64); }
            return argv[++i];
        };
        // 监督进程 → 子进程的专用参数不进入 g_raw_args
        if (a == "--supervise") { g_opt.supervise = true; continue; }
        if (a == "--child") { child = true; continue; }
        if (a == "--restarts") { g_opt.restarts = atoi(need("--restarts")); continue; }
        if (a == "--last-exit") { g_opt.last_exit = need("--last-exit"); continue; }
        std::string v;
        if (a == "--port")            { v = need("--port");            g_opt.port = atoi(v.c_str()); }
        else if (a == "--model")      { v = need("--model");           g_opt.model = v; }
        else if (a == "--student-vocab") { v = need("--student-vocab"); g_opt.student_vocab = v; }
        else if (a == "--rime-dir")   { v = need("--rime-dir");        g_opt.rime_dir = v; }
        else if (a == "--log-dir")    { v = need("--log-dir");         g_opt.log_dir = v; }
        else if (a == "--threads")    { v = need("--threads");         g_opt.threads = atoi(v.c_str()); }
        else if (a == "--max-ctx")    { v = need("--max-ctx");         g_opt.max_ctx = atoi(v.c_str()); }
        else if (a == "--orphan-sec") { v = need("--orphan-sec");      g_opt.orphan_sec = atoi(v.c_str()); }
        else if (a == "--n-ctx")      { v = need("--n-ctx");           g_opt.n_ctx = atoi(v.c_str()); }
        else if (a == "--n-seq-max")  { v = need("--n-seq-max");       g_opt.n_seq_max = atoi(v.c_str()); }
        else if (a == "--idle-sec")   { v = need("--idle-sec");        g_opt.idle_sec = atoi(v.c_str()); }
        else if (a == "--screen-off-sec") { v = need("--screen-off-sec"); g_opt.screen_off_sec = atoi(v.c_str()); }
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); usage(); return 64; }
        g_raw_args.push_back(a);
        g_raw_args.push_back(v);
    }
    (void)child;
    if (g_opt.model.empty()) { usage(); return 64; }
    if (g_opt.supervise) return run_supervisor(argv);
    return run_daemon();
}
