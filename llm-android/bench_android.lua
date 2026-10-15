-- 手机上的基准：加载、打分合理性、P50/P95 延迟、内存。用法：
--   LD_LIBRARY_PATH=. ./lua bench_android.lua <so目录> <模型> <日志目录> <线程数> [迭代数]
local so_dir, model, log_dir, threads, iters = arg[1], arg[2], arg[3], tonumber(arg[4] or "4"), tonumber(arg[5] or "200")
package.cpath = so_dir .. "/?.so;" .. package.cpath
local m = require("rime_llm")
if os.getenv("REPACK") == "1" then m.use_repack = true end
local QUIET = os.getenv("QUIET") == "1"
m.log_dir = log_dir; m.model_path = model; m.n_threads = threads

local function rss_mb()
  local f = io.open("/proc/self/status"); if not f then return -1 end
  local s = f:read("*a"); f:close()
  local kb = s:match("VmRSS:%s*(%d+)"); return kb and math.floor(tonumber(kb) / 1024) or -1
end
local function pss_mb()
  local f = io.open("/proc/self/smaps_rollup"); if not f then return -1 end
  local s = f:read("*a"); f:close()
  local kb = s:match("Pss:%s*(%d+)"); return kb and math.floor(tonumber(kb) / 1024) or -1
end

local cases = {
  { "他在公司当", { "经理", "经历", "精力" }, "经理" },
  { "我最近没有太多", { "经理", "经历", "精力" }, "精力" },
  { "这段难忘的", { "经理", "经历", "精力" }, "经历" },
  { "他生病后住进了", { "医院", "议员", "意愿" }, "医院" },
  { "国会里的一位", { "医院", "议员", "意愿" }, "议员" },
  { "这是一起严重的", { "时间", "事件", "实践" }, "事件" },
  { "理论必须联系", { "时间", "事件", "实践" }, "实践" },
  { "老师给了我很多", { "知道", "指导", "之道" }, "指导" },
  { "他对这个方案提出了", { "意义", "异议", "一一" }, "异议" },
  { "数学课上老师讲了", { "公式", "共识", "公示" }, "公式" },
}

local t0 = m.now_ms()
while not m.score(cases[1][1], cases[1][2]) do
  local t = m.now_ms(); while m.now_ms() - t < 20 do end
  if m.now_ms() - t0 > 120000 then print("FAIL: model not ready in 120 s"); os.exit(1) end
end
local load_ms = m.now_ms() - t0
if not QUIET then print(string.format("threads=%d  load: %.0f ms  RSS=%d MB  PSS=%d MB", threads, load_ms, rss_mb(), pss_mb())) end

local hit = 0
for _, c in ipairs(cases) do
  local r = m.score(c[1], c[2]); if r and r[1] == c[3] then hit = hit + 1 end
end
if not QUIET then print(string.format("top-1: %d/%d", hit, #cases)) end

-- 真实路径：预解码 → 等一小会儿（相当于两次按键之间）→ 只打分（allow_sync=false）
if os.getenv("BENCH") == "prep" then
  local wait_s = tonumber(os.getenv("WAIT_MS") or "100") / 1000
  local function pct2(t, p) table.sort(t); return t[math.max(1, math.ceil(#t * p))] end
  local sc, miss = {}, 0
  for i = 1, iters do
    local c = cases[(i % #cases) + 1]
    -- 换一个上文，保证预解码确实要重做（连续两次同一上文会命中旧结果）
    local ctx = c[1] .. (i % 2 == 0 and "" or "。")
    m.prepare(ctx)
    os.execute("sleep " .. wait_s)
    local a = m.now_ms()
    local r = m.score(ctx, c[2], false)
    local dt = m.now_ms() - a
    if r then sc[#sc + 1] = dt else miss = miss + 1 end
  end
  local sum = 0; for _, v in ipairs(sc) do sum = sum + v end
  print(string.format("threads=%d wait=%3.0fms : prepared-in-time %d/%d | score(prepared) mean %5.1f P50 %5.1f P95 %5.1f max %5.1f ms",
    threads, wait_s * 1000, #sc, iters, #sc > 0 and sum / #sc or -1, #sc > 0 and pct2(sc, .5) or -1, #sc > 0 and pct2(sc, .95) or -1, #sc > 0 and sc[#sc] or -1))
  os.exit(0)
end

local function pct(t, p) table.sort(t); return t[math.max(1, math.ceil(#t * p))] end
local lat = {}
for i = 1, iters do
  local c = cases[(i % #cases) + 1]
  local a = m.now_ms(); m.score(c[1], c[2]); lat[#lat + 1] = m.now_ms() - a
end
local sum = 0; for _, v in ipairs(lat) do sum = sum + v end
if QUIET then
  print(string.format("top1=%d/%d load=%4.0fms | mean %5.1f P50 %5.1f P95 %5.1f max %5.1f ms | PSS=%d MB", hit, #cases, load_ms, sum / #lat, pct(lat, 0.5), pct(lat, 0.95), lat[#lat], pss_mb()))
else
  print(string.format("score (sync, 3 cands, %d calls): mean %.1f ms | P50 %.1f | P95 %.1f | max %.1f", iters, sum / #lat, pct(lat, 0.5), pct(lat, 0.95), lat[#lat]))
  print(string.format("after run: RSS=%d MB  PSS=%d MB", rss_mb(), pss_mb()))
  local f = io.open("/proc/self/smaps_rollup")
  if f then
    local t = f:read("*a"); f:close()
    local function kb(name) return math.floor((tonumber(t:match(name .. ":%s*(%d+)")) or 0) / 1024) end
    print(string.format("smaps: Private_Dirty=%d MB  Private_Clean(file-backed, reclaimable)=%d MB  Shared_Clean=%d MB  Anonymous=%d MB  Swap=%d MB",
      kb("Private_Dirty"), kb("Private_Clean"), kb("Shared_Clean"), kb("Anonymous"), kb("Swap")))
  end
end
