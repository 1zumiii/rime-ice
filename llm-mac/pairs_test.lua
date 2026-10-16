-- 个人词对（personal_pairs）与 recent_boost_filter 的单元测试，不需要模型。
-- 用法：lua llm-mac/pairs_test.lua <仓库目录> <临时目录>
local repo, tmp = arg[1], arg[2]
package.path = repo .. "/lua/?.lua;" .. package.path
local fails = 0
local function check(name, cond, extra)
  print((cond and "PASS " or "FAIL ") .. name .. (extra and ("  [" .. extra .. "]") or ""))
  if not cond then fails = fails + 1 end
end
os.execute("rm -rf '" .. tmp .. "' && mkdir -p '" .. tmp .. "'")
rime_api = { get_user_data_dir = function() return tmp end, get_distribution_code_name = function() return "Squirrel" end }
local pp = require("personal_pairs")
local file = tmp .. "/recent_pairs.tsv"
local T = os.time()

-- 记录与时间窗
pp.init()
pp.record("今天", T - 100)
pp.record("天气", T - 95)            -- 间隔 5 秒：记 今天→天气
pp.record("不错", T - 60)            -- 间隔 35 秒：超过 GAP，不记
check("间隔内记词对", pp.eff("今天", "天气", T) > 0.99)
check("超过间隔不记词对", pp.eff("天气", "不错", T) == 0)
check("没有前一个词（超时）", pp.prev(T) == nil)
pp.record("天气", T - 10); pp.record("真好", T - 8)
check("英文不记", (function() pp.record("hello", T - 5); pp.record("world", T - 4); return pp.eff("hello", "world", T) == 0 end)())
check("整句不记", (function() local long = "这是一个很长很长很长的句子"; pp.record(long, T - 3); pp.record("好", T - 2); return pp.eff(long, "好", T) == 0 end)())
check("reset 后没有前一个词", (function() pp.record("你好", T); pp.reset(); return pp.prev(T) == nil end)())

-- 衰减：同一词对 14 天前一次，约 1/e
pp._reset_all()
local f = io.open(file, "w"); f:write(string.format("%d\t喜欢\t吃饭\n", T - 14 * 86400)); f:close()
pp.init()
local e = pp.eff("喜欢", "吃饭", T)
check("14 天衰减到约 0.37", math.abs(e - math.exp(-1)) < 0.02, string.format("%.3f", e))
-- 重复累加
pp.record("喜欢", T - 3); pp.record("吃饭", T - 2); pp.record("喜欢", T - 1); pp.record("吃饭", T)
check("重复使用累加", pp.eff("喜欢", "吃饭", T) > 1.3)

-- 持久化：重启后读回
pp._reset_all(); pp.init()
check("重启后读回", pp.eff("喜欢", "吃饭", T) > 1.3)

-- 超过 90 天的丢弃；超量压缩
pp._reset_all()
f = io.open(file, "w")
f:write(string.format("%d\t旧\t词\n", T - 100 * 86400))
for i = 1, 6100 do f:write(string.format("%d\t甲%d\t乙\n", T - 10, i)) end
f:close()
pp.init()
check("90 天前的丢弃", pp.eff("旧", "词", T) == 0)
local n = 0; for _ in io.lines(file) do n = n + 1 end
check("超量压缩到 6000 条", n == 6000, tostring(n))
check("压缩保留最新的", pp.eff("甲6100", "乙", T) > 0 and pp.eff("甲1", "乙", T) == 0)

-- recent_boost_filter：词对命中的候选优先提升
pp._reset_all()
os.remove(file); os.remove(tmp .. "/recent_words.tsv")
local conf = { ["rbf/window_hours"] = 72, ["rbf/idx"] = 2, ["rbf/max_boost"] = 2, ["rbf/scan"] = 40, ["rbf/min_count"] = 1, ["rbf/max_records"] = 3000 }
local notifier_cb
local ctx = { input = "tianqi", commit_notifier = { connect = function(_, cb) notifier_cb = cb; return { disconnect = function() end } end } }
local last_commit
ctx.commit_history = { back = function() return last_commit end }
local env = { name_space = "rbf", engine = { context = ctx, schema = { config = {
  get_int = function(_, k) return conf[k] end,
  get_double = function(_, k) return conf[k] end,
  get_bool = function(_, k) return conf[k] end } } } }
local M = require("recent_boost_filter")
M.init(env)
local function commit(text) last_commit = { type = "phrase", text = text }; notifier_cb(ctx) end
local function run(texts, e)
  local list = {}
  for i, t in ipairs(texts) do list[i] = { text = t, type = "phrase" } end
  local idx = 0
  local out = {}
  _G.yield = function(c) out[#out + 1] = c.text end
  M.func({ iter = function() return function() idx = idx + 1; return list[idx] end end }, e or env)
  return out
end
-- 用户常在「明天」后面选「天气」，也最近用过「天机」（更新）
commit("明天"); commit("天气"); pp.reset(); commit("明天"); commit("天气")   -- 同一搭配两次
os.execute("sleep 1")
commit("天机")
commit("天下"); commit("天下")
local pairs_before = run({ "天启", "天空", "天气", "天机" })
-- 没有前一个词时（超时）：按最近使用提升
check("无上文时按最近使用", pairs_before[2] == "天下" or pairs_before[2] == "天机", table.concat(pairs_before, ","))
commit("明天")   -- 现在前一个词 = 明天
local out = run({ "天启", "天空", "天气", "天机" })
check("词对命中排在最近使用之前", out[2] == "天气", table.concat(out, ","))
-- 关闭词对
conf["rbf/pairs"] = false
local env2 = { name_space = "rbf", engine = env.engine }
M.fini(env); M.init(env2)
commit("明天")
local out2 = run({ "天启", "天空", "天气", "天机" }, env2)
check("pairs=false 回到按最近使用", out2[2] == "天机", table.concat(out2, ","))
print(fails == 0 and "全部通过" or ("失败 " .. fails))
os.exit(fails == 0 and 0 or 1)
