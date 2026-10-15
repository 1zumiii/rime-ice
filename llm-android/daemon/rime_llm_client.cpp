// rime_llm_client — Trime 进程里的轻量客户端，对 Lua 暴露与 rime_llm.so 完全相同的接口，
// 实际推理由常驻进程 rimellmd 完成（见 rimellmd.cpp）。库名 librime_llm.so，随 APK 打包，
// 由 package.loadlib("librime_llm.so", "luaopen_rime_llm") 加载。
//
// 稳定性约束：
//  - 所有网络 I/O 都有总时限；连不上/超时就立刻返回"不可用"，输入法不会被拖慢（候选保持原顺序）；
//  - 失败后指数退避重连（0.5 s → 10 s），守护进程重启后自动恢复，无需任何手动操作；
//  - 每次按键都会调的 touch / is_ready 在本地合并/短缓存，不会每次都走一次 socket；
//  - 参数校验全部在加锁之前完成（Lua 报错用 longjmp，不能在持锁/有析构的帧里发生）。
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <regex>
#include <string>
#include <vector>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include "proto.h"

namespace {

std::mutex   g_mu;
int          g_fd = -1;
long long    g_retry_at = 0;
int          g_fail_streak = 0;
std::string  g_rime_dir;                       // 来自 log_dir：令牌文件所在目录
int          g_port = proto::kDefaultPort;
std::string  g_model_path;                     // 仅记录；模型路径由守护进程自己的参数决定
long long    g_max_ctx = 10, g_min_tokens = 1, g_n_threads = 4, g_idle_unload_sec = 0, g_n_ctx = 128, g_n_seq_max = 12;
std::map<std::string, long long> g_pending_cfg;   // 重连后重新下发
std::vector<std::pair<std::string, double>> g_last_scores;
long long    g_ready_at = -100000;
bool         g_ready = false;
long long    g_touch_sent_at = -100000;

constexpr int kConnectMs = 40;
constexpr int kHelloMs = 150;

void close_fd_locked() { if (g_fd >= 0) { close(g_fd); g_fd = -1; } }

void fail_locked() {
    close_fd_locked();
    g_fail_streak++;
    long long d = 500LL << (g_fail_streak > 5 ? 5 : g_fail_streak - 1);
    if (d > 10000) d = 10000;
    g_retry_at = proto::mono_ms() + d;
}

std::string read_token() {
    if (g_rime_dir.empty()) return "";
    FILE * f = fopen((g_rime_dir + "/llm_token").c_str(), "r");
    if (!f) return "";
    char b[128] = {0};
    size_t n = fread(b, 1, sizeof b - 1, f);
    fclose(f);
    std::string t(b, n);
    while (!t.empty() && (t.back() == '\n' || t.back() == '\r' || t.back() == ' ')) t.pop_back();
    return t;
}

bool connect_locked() {
    if (g_fd >= 0) return true;
    if (proto::mono_ms() < g_retry_at) return false;
    std::string token = read_token();
    if (token.empty()) { fail_locked(); return false; }     // 守护进程还没启动过（令牌文件不存在）
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) { fail_locked(); return false; }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons((uint16_t)g_port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int r = connect(fd, (struct sockaddr *)&a, sizeof a);
    if (r != 0 && errno != EINPROGRESS) { close(fd); fail_locked(); return false; }
    if (r != 0) {
        struct pollfd pf = {fd, POLLOUT, 0};
        if (poll(&pf, 1, kConnectMs) != 1) { close(fd); fail_locked(); return false; }
        int err = 0; socklen_t el = sizeof err;
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
        if (err != 0) { close(fd); fail_locked(); return false; }
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    std::vector<std::string> rep;
    if (!proto::send_frame(fd, {"H", token}, kHelloMs) || !proto::recv_frame(fd, rep, kHelloMs, kHelloMs) ||
        rep.empty() || rep[0] != "OK") { close(fd); fail_locked(); return false; }
    g_fd = fd;
    g_fail_streak = 0;
    for (auto & kv : g_pending_cfg) {                      // 重新下发配置（守护进程重启后默认值会丢）
        if (!proto::send_frame(g_fd, {"C", kv.first, std::to_string(kv.second)}, kHelloMs) ||
            !proto::recv_frame(g_fd, rep, kHelloMs, kHelloMs)) { fail_locked(); return false; }
    }
    return true;
}

// 一次请求/应答。连接在上一次之后才断（守护进程刚重启）的情况下，立即重连重试一次。
bool rpc_locked(const std::vector<std::string> & req, int timeout_ms, std::vector<std::string> & rep) {
    for (int attempt = 0; attempt < 2; attempt++) {
        bool was_connected = (g_fd >= 0);
        if (!connect_locked()) return false;
        long long t0 = proto::mono_ms();
        if (proto::send_frame(g_fd, req, timeout_ms) && proto::recv_frame(g_fd, rep, timeout_ms, timeout_ms)) return true;
        bool quick = (proto::mono_ms() - t0) < 30;          // 立刻失败 = 对端已关闭，而不是超时
        if (was_connected && quick && attempt == 0) { close_fd_locked(); g_retry_at = 0; continue; }
        fail_locked();
        return false;
    }
    return false;
}

// ---------------------------------------------------------------- Lua 接口

int l_score(lua_State * L) {
    size_t cl = 0;
    const char * ctx = luaL_checklstring(L, 1, &cl);
    luaL_checktype(L, 2, LUA_TTABLE);
    bool allow_sync = !(lua_gettop(L) >= 3 && lua_isboolean(L, 3) && !lua_toboolean(L, 3));
    std::vector<std::string> req = {"S", allow_sync ? "1" : "0", std::string(ctx, cl)};
    int n = (int)luaL_len(L, 2);
    if (n > (int)g_n_seq_max) n = (int)g_n_seq_max;
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 2, i);
        size_t sl = 0; const char * s = lua_tolstring(L, -1, &sl);
        if (s) req.emplace_back(s, sl);
        lua_pop(L, 1);
    }
    if (req.size() < 5) { lua_pushnil(L); return 1; }        // 少于 2 个候选
    std::vector<std::string> rep;
    bool ok;
    { std::lock_guard<std::mutex> lk(g_mu); ok = rpc_locked(req, allow_sync ? 600 : 200, rep); }
    if (!ok) { lua_pushnil(L); lua_pushstring(L, "down"); return 2; }
    if (rep.empty() || rep[0] != "R") {
        lua_pushnil(L);
        if (rep.size() >= 2 && !rep[1].empty()) { lua_pushlstring(L, rep[1].data(), rep[1].size()); return 2; }
        return 1;
    }
    std::vector<std::pair<std::string, double>> sc;
    lua_newtable(L);
    int k = 0;
    for (size_t i = 1; i + 1 < rep.size(); i += 2) {
        lua_pushlstring(L, rep[i].data(), rep[i].size());
        lua_rawseti(L, -2, ++k);
        sc.emplace_back(rep[i], atof(rep[i + 1].c_str()));
    }
    { std::lock_guard<std::mutex> lk(g_mu); g_last_scores.swap(sc); }
    return 1;
}

int l_get_scores(lua_State * L) {
    std::vector<std::pair<std::string, double>> sc;
    { std::lock_guard<std::mutex> lk(g_mu); sc = g_last_scores; }
    lua_newtable(L);
    for (auto & p : sc) {
        lua_pushnumber(L, p.second);
        lua_setfield(L, -2, p.first.c_str());
    }
    return 1;
}

int l_prepare(lua_State * L) {
    size_t cl = 0;
    const char * ctx = luaL_checklstring(L, 1, &cl);
    std::vector<std::string> req = {"P", std::string(ctx, cl)}, rep;
    bool ok;
    { std::lock_guard<std::mutex> lk(g_mu); ok = rpc_locked(req, 100, rep); }
    lua_pushboolean(L, ok && !rep.empty() && rep[0] == "1");
    return 1;
}

int l_is_ready(lua_State * L) {
    long long now = proto::mono_ms();
    if (now - g_ready_at >= 300) {                          // 短缓存：每次按键都会问
        std::vector<std::string> rep;
        bool ok;
        { std::lock_guard<std::mutex> lk(g_mu); ok = rpc_locked({"I"}, 100, rep); }
        g_ready = ok && !rep.empty() && rep[0] == "1";
        g_ready_at = proto::mono_ms();
    }
    lua_pushboolean(L, g_ready);
    return 1;
}

int l_touch(lua_State *) {
    long long now = proto::mono_ms();
    if (now - g_touch_sent_at < 1500) return 0;             // 合并：守护进程的空闲时限是分钟级，1.5 秒一次足够
    g_touch_sent_at = now;
    std::vector<std::string> rep;
    std::lock_guard<std::mutex> lk(g_mu);
    rpc_locked({"T"}, 60, rep);
    return 0;
}

int l_screen_off(lua_State * L) {
    bool off = lua_toboolean(L, 1) != 0;
    std::vector<std::string> rep;
    bool ok;
    { std::lock_guard<std::mutex> lk(g_mu); ok = rpc_locked({"Z", off ? "1" : "0"}, 150, rep); }
    lua_pushboolean(L, ok);
    return 1;
}

// 守护进程状态（JSON 字符串）；连不上返回 nil
int l_status(lua_State * L) {
    std::vector<std::string> rep;
    bool ok;
    { std::lock_guard<std::mutex> lk(g_mu); ok = rpc_locked({"G"}, 200, rep); }
    if (!ok || rep.empty()) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, rep[0].data(), rep[0].size());
    return 1;
}

// 手动启停：关 = 守护进程立刻卸载模型并拒绝推理；开 = 允许按需加载。记入待下发配置，守护进程重启后自动重新同步
int l_set_enabled(lua_State * L) {
    long long v = lua_toboolean(L, 1) ? 1 : 0;
    g_pending_cfg["enabled"] = v;
    std::vector<std::string> rep;
    bool ok;
    { std::lock_guard<std::mutex> lk(g_mu); ok = rpc_locked({"C", "enabled", std::to_string(v)}, 300, rep); }
    g_ready_at = -100000;                       // 使 is_ready 缓存失效
    lua_pushboolean(L, ok);
    return 1;
}

int l_connected(lua_State * L) { lua_pushboolean(L, g_fd >= 0); return 1; }

// 以下与 macOS/Windows 版保持接口一致（Android 上没有对应能力）
int l_nil(lua_State * L) { lua_pushnil(L); return 1; }
int l_noop(lua_State *) { return 0; }
int l_false(lua_State * L) { lua_pushboolean(L, 0); return 1; }

const char * kDefaultCodePattern = ".{4}";

int l_match_code(lua_State * L) {
    const char * pat = luaL_optstring(L, 1, NULL);
    const char * code = luaL_optstring(L, 2, "");
    if (!pat || !*pat) { lua_pushboolean(L, 1); return 1; }
    static std::string last_pat;
    static std::regex re;
    static bool re_valid = false;
    if (last_pat != pat || (!re_valid && last_pat.empty())) {
        last_pat = pat;
        try { re = std::regex(pat, std::regex::ECMAScript); re_valid = true; }
        catch (const std::regex_error &) {
            try { last_pat = kDefaultCodePattern; re = std::regex(kDefaultCodePattern, std::regex::ECMAScript); re_valid = true; }
            catch (...) { re_valid = false; }
        }
    }
    bool ok = false;
    if (re_valid) { try { ok = std::regex_match(std::string(code), re); } catch (...) { ok = false; } }
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

int l_now_ms(lua_State * L) {
    lua_pushnumber(L, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count());
    return 1;
}

void send_cfg(const char * key, long long v) {
    g_pending_cfg[key] = v;
    std::vector<std::string> rep;
    std::lock_guard<std::mutex> lk(g_mu);
    if (g_fd >= 0) rpc_locked({"C", key, std::to_string(v)}, 100, rep);   // 没连上就等重连时下发
}

int l_index(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if      (!strcmp(key, "model_path"))      lua_pushstring(L, g_model_path.c_str());
    else if (!strcmp(key, "max_ctx"))         lua_pushinteger(L, g_max_ctx);
    else if (!strcmp(key, "min_tokens"))      lua_pushinteger(L, g_min_tokens);
    else if (!strcmp(key, "n_threads"))       lua_pushinteger(L, g_n_threads);
    else if (!strcmp(key, "n_ctx"))           lua_pushinteger(L, g_n_ctx);
    else if (!strcmp(key, "n_seq_max"))       lua_pushinteger(L, g_n_seq_max);
    else if (!strcmp(key, "idle_unload_sec")) lua_pushinteger(L, g_idle_unload_sec);
    else if (!strcmp(key, "log_dir"))         lua_pushstring(L, g_rime_dir.c_str());
    else if (!strcmp(key, "port"))            lua_pushinteger(L, g_port);
    else if (!strcmp(key, "use_repack"))      lua_pushboolean(L, 0);
    else lua_pushnil(L);
    return 1;
}

int l_newindex(lua_State * L) {
    const char * key = luaL_checkstring(L, 2);
    if (!strcmp(key, "model_path")) { g_model_path = luaL_checkstring(L, 3); }                    // 模型由守护进程决定
    else if (!strcmp(key, "max_ctx"))         { g_max_ctx = luaL_checkinteger(L, 3);         send_cfg("max_ctx", g_max_ctx); }
    else if (!strcmp(key, "min_tokens"))      { g_min_tokens = luaL_checkinteger(L, 3);      send_cfg("min_tokens", g_min_tokens); }
    else if (!strcmp(key, "n_threads"))       { g_n_threads = luaL_checkinteger(L, 3);       send_cfg("n_threads", g_n_threads); }
    else if (!strcmp(key, "idle_unload_sec")) { g_idle_unload_sec = luaL_checkinteger(L, 3); send_cfg("idle_unload_sec", g_idle_unload_sec); }
    else if (!strcmp(key, "n_ctx"))           g_n_ctx = luaL_checkinteger(L, 3);
    else if (!strcmp(key, "n_seq_max"))       g_n_seq_max = luaL_checkinteger(L, 3);
    else if (!strcmp(key, "log_dir")) {
        std::string d = luaL_checkstring(L, 3);
        std::lock_guard<std::mutex> lk(g_mu);
        g_rime_dir = d; g_retry_at = 0; g_fail_streak = 0;                                         // 目录变了：令牌路径变了，立刻允许重连
    }
    else if (!strcmp(key, "port")) { int p = (int)luaL_checkinteger(L, 3); std::lock_guard<std::mutex> lk(g_mu); g_port = p; close_fd_locked(); g_retry_at = 0; }
    return 0;
}

int l_gc(lua_State *) { std::lock_guard<std::mutex> lk(g_mu); close_fd_locked(); return 0; }

}  // namespace

extern "C" __attribute__((visibility("default"))) int luaopen_rime_llm(lua_State * L) {
    lua_newtable(L);
    struct { const char * n; lua_CFunction f; } fns[] = {
        {"score", l_score}, {"get_scores", l_get_scores}, {"prepare", l_prepare}, {"is_ready", l_is_ready},
        {"touch", l_touch}, {"screen_off", l_screen_off}, {"set_enabled", l_set_enabled}, {"status", l_status}, {"connected", l_connected},
        {"llm_context", l_nil}, {"kick_context", l_noop}, {"edit_reset_context", l_noop},
        {"fg_changed", l_false}, {"click_happened", l_false}, {"match_code", l_match_code}, {"now_ms", l_now_ms},
    };
    for (auto & e : fns) { lua_pushcfunction(L, e.f); lua_setfield(L, -2, e.n); }
    lua_pushstring(L, kDefaultCodePattern);
    lua_setfield(L, -2, "default_code_pattern");
    lua_pushstring(L, "daemon-client");
    lua_setfield(L, -2, "backend");
    lua_newtable(L);                                   // 同引擎版：可写属性必须走 __index/__newindex，不能预填充
    lua_pushcfunction(L, l_index);    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, l_newindex); lua_setfield(L, -2, "__newindex");
    lua_pushcfunction(L, l_gc);       lua_setfield(L, -2, "__gc");
    lua_setmetatable(L, -2);
    return 1;
}
