-- 空闲自动卸载测试
local so_dir, model, log_dir, exit_mode = arg[1], arg[2], arg[3], arg[4] or "close"
package.cpath = so_dir .. "/?.so;" .. package.cpath
local m = require("rime_llm")
m.log_dir = log_dir
m.model_path = model
m.n_threads = 4

local fails = 0
local function check(name, cond, extra)
  print((cond and "PASS " or "FAIL ") .. name .. (extra and ("  [" .. extra .. "]") or ""))
  if not cond then fails = fails + 1 end
end
local function fp()
  local f = io.popen("footprint -p $PPID 2>/dev/null | sed -n 's/.*Footprint: \\([0-9]*\\) MB.*/\\1/p'")
  local v = tonumber(f:read("*a")); f:close(); return v
end
local function scoreit() return m.score("他在公司当", { "经理", "经历", "精力" }) end
local function wait_ready(limit)
  local t0 = os.time()
  while not scoreit() do
    os.execute("sleep 0.1"); if os.time() - t0 > (limit or 60) then return false end
  end
  return true
end

check("default idle_unload_sec is 0 (off)", m.idle_unload_sec == 0, tostring(m.idle_unload_sec))
m.idle_unload_sec = 3
check("idle_unload_sec can be set", m.idle_unload_sec == 3, tostring(m.idle_unload_sec))

check("model loads", wait_ready())
local loaded_mb = fp()

-- 连续使用：每秒打一次分，持续 8 秒（> 3 秒空闲时限），不应被卸载
for i = 1, 8 do scoreit(); os.execute("sleep 1") end
check("continuous use (every 1 s for 8 s, limit 3 s): NOT unloaded", m.is_ready() == true)

-- 空闲：6 秒不用 → 应被卸载并还回内存
os.execute("sleep 6")
check("idle > limit: unloaded", m.is_ready() == false)
local idle_mb = fp()
check("memory returned after idle unload", idle_mb and loaded_mb and idle_mb < loaded_mb - 150,
      string.format("%s MB -> %s MB", tostring(loaded_mb), tostring(idle_mb)))

-- 再用：自动加载回来，结果正确
local t0 = os.time()
check("transparently reloads on next use", wait_ready())
local ranked = scoreit()
check("result correct after reload", ranked and ranked[1] == "经理", ranked and table.concat(ranked, ">") or "nil")

-- 关闭配置：不再卸载
m.idle_unload_sec = 0
os.execute("sleep 6")
check("idle_unload_sec = 0: never unloads", m.is_ready() == true)

-- 再次开启并立即退出，确认退出路径干净（模型仍加载着）
m.idle_unload_sec = 3
print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
io.stdout:flush()
if exit_mode == "exit" then os.exit(fails == 0 and 0 or 1) end
