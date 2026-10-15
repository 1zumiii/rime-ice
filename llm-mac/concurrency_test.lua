-- 边界情况测试。用法：lua test_concurrency.lua <so目录> <模型> <日志目录> <场景>
-- 场景：race | loading | reinit | toggles | exit_wait | exit_window
local so_dir, model, log_dir, case = arg[1], arg[2], arg[3], arg[4]
package.cpath = so_dir .. "/?.so;" .. package.cpath

local fails = 0
local function check(name, cond, extra)
  print((cond and "PASS " or "FAIL ") .. name .. (extra and ("  [" .. extra .. "]") or ""))
  if not cond then fails = fails + 1 end
end
local function sh(cmd) local f = io.popen(cmd); local r = f:read("*a"); f:close(); return r end
local function now() return tonumber(sh("python3 -c 'import time;print(time.time())'")) end
local function nthreads() return tonumber(sh("ps -M -p $PPID | tail -n +2 | wc -l")) end
local cands = { "经理", "经历", "精力" }
local function setup(m)
  m.log_dir = log_dir; m.model_path = model; m.n_threads = 4
end
local function wait_ready(m, limit)
  local t0 = os.time()
  while not m.score("他在公司当", cands) do
    os.execute("sleep 0.05"); if os.time() - t0 > (limit or 60) then return false end
  end
  return true
end
local function finish()
  print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
  io.stdout:flush()
end

local m = require("rime_llm")
setup(m)

if case == "race" then
  -- 场景 1/2：卸载线程已经决定卸载（窗口被拉长到 600 ms），这时用户开始打字
  m.idle_unload_sec = 1
  check("model loads", wait_ready(m))
  m.score("他在公司当", cands)                 -- 刷新最近使用时间，t0
  local t0 = now()
  os.execute("sleep 1.25")                     -- 1.05 s 时计时线程拿到独占锁并进入 600 ms 的卸载窗口
  local a = now()
  local r, why = m.score("他在公司当", cands, false)
  local dt = (now() - a) * 1000
  check("score during the unload window: skipped as busy (no crash, no wait)", r == nil and why == "busy", tostring(why))
  check("score during the window returned fast (<100 ms, window is 600 ms)", dt < 100, string.format("%.0f ms", dt))
  a = now()
  local pr = m.prepare("他在公司当")
  dt = (now() - a) * 1000
  check("prepare during the window: returns false fast, no crash", pr == false and dt < 100, string.format("%s %.0f ms", tostring(pr), dt))
  os.execute("sleep 1.2")                      -- 等卸载完成
  check("model was unloaded after the window", m.is_ready() == false)
  check("transparently reloads afterwards", wait_ready(m))
  local ranked = m.score("他在公司当", cands)
  check("result correct after the race", ranked and ranked[1] == "经理", ranked and table.concat(ranked, ">") or "nil")
  finish()

elseif case == "loading" then
  -- 场景 3：模型正在加载时反复收到输入：不重复加载、不丢最新上下文
  local calls = 0
  for i = 1, 300 do   -- 加载期间持续不断的输入（远快于加载完成）
    m.prepare("他在公司当"); m.score("他在公司当", cands); calls = calls + 1
  end
  m.prepare("我最近没有太多")                    -- 加载期间最后一次请求的上下文
  check("many calls while loading", calls > 20, tostring(calls))
  check("model becomes ready", wait_ready(m))
  local f = io.open(log_dir .. "/rime_llm_log.txt"); local log = f:read("*a"); f:close()
  local _, loads = log:gsub("loading model:", "")
  check("model created exactly once", loads == 1, tostring(loads))
  -- 处理器的做法：加载完成后上文没变，再请求一次预解码；之后用最新上下文打分应已预解码好
  check("prepare(latest) is accepted once loaded", m.prepare("我最近没有太多") == true)
  os.execute("sleep 0.6")
  local r, why = m.score("我最近没有太多", { "经理", "经历", "精力", "敬礼", "警力" }, false)
  check("scoring with the latest context works (prepared)", type(r) == "table" and r[1] == "精力", r and table.concat(r, ">") or ("nil/" .. tostring(why)))
  finish()

elseif case == "reinit" then
  -- 场景 6a：模块被卸载（__gc）后重新 require/初始化：计时线程不重复、空闲卸载仍然有效
  m.idle_unload_sec = 2
  check("model loads", wait_ready(m))
  local th1 = nthreads()
  m = nil
  package.loaded["rime_llm"] = nil
  collectgarbage(); collectgarbage()           -- 触发旧模块表的 __gc → cleanup(false)：卸载模型并停止计时线程
  local m2 = require("rime_llm")
  setup(m2)
  m2.idle_unload_sec = 2
  check("re-initialised module is a fresh table that can load", wait_ready(m2))
  local th2 = nthreads()
  check("no thread leak across re-init", th2 <= th1 + 1, string.format("%d -> %d", th1, th2))
  os.execute("sleep 5")
  check("idle unload still works after re-init", m2.is_ready() == false)
  check("works again afterwards", wait_ready(m2))
  finish()

elseif case == "toggles" then
  -- 场景 6b：配置反复切换：不产生重复计时线程
  m.idle_unload_sec = 3
  check("model loads", wait_ready(m))
  local th0 = nthreads()
  for i = 1, 200 do m.idle_unload_sec = (i % 4 == 0) and 0 or (i % 7 + 1) end
  m.idle_unload_sec = 2
  os.execute("sleep 0.5")
  local th1 = nthreads()
  check("200 config changes: thread count unchanged", th1 <= th0, string.format("%d -> %d", th0, th1))
  os.execute("sleep 4")
  check("last setting (2 s) still takes effect", m.is_ready() == false)
  finish()

elseif case == "exit_wait" then
  -- 场景 5a：计时线程在睡眠时退出
  m.idle_unload_sec = 600
  check("model loads", wait_ready(m))
  finish()
  os.exit(fails == 0 and 0 or 1)

elseif case == "exit_window" then
  -- 场景 5b：计时线程正在卸载（窗口 800 ms）时退出
  m.idle_unload_sec = 1
  check("model loads", wait_ready(m))
  m.score("他在公司当", cands)
  os.execute("sleep 1.3")                      -- 正处在卸载窗口中
  finish()
  os.exit(fails == 0 and 0 or 1)
end
