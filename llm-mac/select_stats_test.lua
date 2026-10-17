-- 选词统计的单元测试：用模拟环境检查只写纯数字、开关文件生效、位次与去重正确。
-- 用法：lua llm-mac/select_stats_test.lua <仓库目录> <临时目录>
local repo, tmp = arg[1], arg[2]
package.path = repo .. "/lua/?.lua;" .. package.path
local fails = 0
local function check(name, cond, extra)
  print((cond and "PASS " or "FAIL ") .. name .. (extra and ("  [" .. extra .. "]") or ""))
  if not cond then fails = fails + 1 end
end
os.execute("rm -rf '" .. tmp .. "' && mkdir -p '" .. tmp .. "'")
rime_api = { get_user_data_dir = function() return tmp end, get_distribution_code_name = function() return "Squirrel" end }
local mod = require("ai_rerank_processor")

local function mk_env(selected_text, sel_index, ai, input)
  local cb
  local ctx = {
    input = input,
    select_notifier = { connect = function(_, f) cb = f end },
    option_update_notifier = { connect = function() end },
    commit_notifier = { connect = function() end },
    get_option = function(_, n) return n == "ai_rerank" and ai end,
    get_selected_candidate = function() return { text = selected_text, type = "phrase" } end,
    composition = { back = function() return { selected_index = sel_index } end },
  }
  local env = { engine = { context = ctx, schema = { config = {
    get_string = function() return "" end, get_int = function() return nil end, get_bool = function() return nil end,
    get_double = function() return nil end } } } }
  return env, function() cb(ctx) end
end
local function read_lines()
  local t = {}
  local f = io.open(tmp .. "/select_stats.tsv", "r")
  if not f then return t end
  for l in f:lines() do t[#t + 1] = l end
  f:close()
  return t
end

-- 1) 没有开关文件：不记录
local env, fire = mk_env("精力", 0, true, "jingli")
mod.init(env)
check("没有 select_stats.enabled 时不监听", _G.ai_select_stats_on == false)

-- 2) 有开关文件：重排参与的一次选词
io.open(tmp .. "/select_stats.enabled", "w"):close()
env, fire = mk_env("精力", 0, true, "jingli")
mod.init(env)
check("有开关文件时开启", _G.ai_select_stats_on == true)
_G.ai_select_info = { input = "jingli", o = { ["经理"] = 1, ["经历"] = 2, ["精力"] = 3 }, f = { ["精力"] = 1, ["经历"] = 2, ["经理"] = 3 }, n = 3, s1 = "miss", s2 = "-", mg = 1.234, gated = 0, mtop = 3 }
fire()
local ls = read_lines()
check("写了一行", #ls == 1)
local f = {}
for x in (ls[1] or ""):gmatch("[^\t]+") do f[#f + 1] = x end
check("14 列", #f == 14, tostring(#f))
check("AI 开、输入 6 个字母、候选 3 个", f[2] == "1" and f[4] == "6" and f[5] == "3")
check("原顺序第 3 位，最终第 1 位", f[6] == "3" and f[7] == "1")
check("门控三列：margin×10、未门控、模型首位原位次 3", f[12] == "12" and f[13] == "0" and f[14] == "3", tostring(f[12]) .. "," .. tostring(f[13]) .. "," .. tostring(f[14]))
check("整行不含汉字和拼音", not (ls[1] or ""):find("[\128-\255]") and not (ls[1] or ""):find("jingli"))
-- 3) 同一次选择重复通知只记一次
fire()
check("重复通知只记一次", #read_lines() == 1)
-- 4) AI 关：原顺序位次 = 最终位次
env, fire = mk_env("好", 2, false, "hao")
mod.init(env)
_G.ai_select_info = nil
fire()
ls = read_lines()
f = {}
for x in (ls[2] or ""):gmatch("[^\t]+") do f[#f + 1] = x end
check("AI 关时位次相同", f[2] == "0" and f[6] == "3" and f[7] == "3", table.concat(f, ","))
-- 5) 输入串不一致（过期的统计信息）：不使用
env, fire = mk_env("精力", 1, true, "jingliguolai")
mod.init(env)
_G.ai_select_info = { input = "jingli", o = { ["精力"] = 3 }, f = { ["精力"] = 1 }, n = 3, s1 = "hit", s2 = "-" }
fire()
ls = read_lines()
f = {}
for x in (ls[3] or ""):gmatch("[^\t]+") do f[#f + 1] = x end
check("过期信息不使用", f[5] == "0" and f[6] == "2", table.concat(f, ","))

-- ===== 训练语料 select_corpus.tsv =====
local function mk_env2(selected_text, sel_index, ai, input, anchor_rate)
  local cb
  local ctx = {
    input = input,
    select_notifier = { connect = function(_, f) cb = f end },
    option_update_notifier = { connect = function() end },
    commit_notifier = { connect = function() end },
    get_option = function(_, n) return n == "ai_rerank" and ai end,
    get_selected_candidate = function() return { text = selected_text, type = "phrase" } end,
    composition = { back = function() return { selected_index = sel_index } end },
  }
  local env = { engine = { context = ctx, schema = { config = {
    get_string = function() return "" end, get_int = function() return nil end, get_bool = function() return nil end,
    get_double = function(_, k) if k == "llm_rerank/select_anchor_rate" then return anchor_rate end return nil end } } } }
  return env, function() cb(ctx) end, ctx
end
local function corpus_lines()
  local t = {}
  local f = io.open(tmp .. "/select_corpus.tsv", "r")
  if not f then return t end
  for l in f:lines() do t[#t + 1] = l end
  f:close()
  return t
end
local function fields(l) local r = {}; for x in (l .. "\t"):gmatch("([^\t]*)\t") do r[#r + 1] = x end; return r end

check("没有 select_corpus.enabled 时不写语料", #corpus_lines() == 0)
io.open(tmp .. "/select_corpus.enabled", "w"):close()
-- 难例：选了最终顺序的第二位
local env3, fire3, ctx3 = mk_env2("精力", 1, true, "jingli", 0.0)
mod.init(env3)
_G.ai_select_info = { input = "jingli", o = { ["经理"] = 1, ["精力"] = 3 }, f = { ["经理"] = 1, ["精力"] = 2 }, n = 3, s1 = "hit", s2 = "-", ft = "经理", of = "经理" }
fire3()
local cl = corpus_lines()
check("难例写入一行", #cl == 1, tostring(#cl))
local cf = fields(cl[1] or "")
check("语料 10 列", #cf == 10, tostring(#cf))
check("难例：所选、最终首位、原顺序首位、类型", cf[5] == "精力" and cf[6] == "经理" and cf[7] == "经理" and cf[8] == "hard", table.concat(cf, "|"))
check("时间戳只到分钟", tonumber(cf[2]) % 60 == 0)
-- 选了首位且锚点率为 0：不记
local env4, fire4 = mk_env2("经理", 0, true, "jingli", 0.0)
mod.init(env4)
_G.ai_select_info = { input = "jingli", o = { ["经理"] = 1 }, f = { ["经理"] = 1 }, n = 3, s1 = "hit", s2 = "-", ft = "经理", of = "经理" }
fire4()
check("选首位且锚点率 0：不记语料", #corpus_lines() == 1)
-- 锚点率 1：记为 anchor
local env5, fire5 = mk_env2("经理", 0, true, "jingli2", 1.0)
mod.init(env5)
_G.ai_select_info = { input = "jingli2", o = { ["经理"] = 1 }, f = { ["经理"] = 1 }, n = 3, s1 = "hit", s2 = "-", ft = "经理", of = "经理" }
fire5()
cl = corpus_lines(); cf = fields(cl[2] or "")
check("锚点率 1：记为 anchor", #cl == 2 and cf[8] == "anchor", cf[8])
-- 英文候选不记
local env6, fire6 = mk_env2("hello", 1, true, "hello", 1.0)
mod.init(env6); _G.ai_select_info = nil; fire6()
check("英文候选不记语料", #corpus_lines() == 2)
-- 选词后马上退格：追加 revise 标记
local env7, fire7, ctx7 = mk_env2("精力", 1, true, "jingli3", 0.0)
mod.init(env7)
_G.ai_select_info = { input = "jingli3", o = {}, f = { ["精力"] = 2 }, n = 3, s1 = "hit", s2 = "-", ft = "经理", of = "经理" }
fire7()
ctx7.input = ""
local bs = { release = function() return false end, repr = function() return "BackSpace" end }
mod.func(bs, env7)
cl = corpus_lines()
check("退格后追加 revise 行", #cl == 4 and cl[4]:match("^revise\t") ~= nil, cl[4] or "无")
local rid = (cl[3] or ""):match("^([^\t]+)")
check("revise 指向刚记的那条", cl[4] == "revise\t" .. rid)


-- ===== 光标被点动后清空上文 =====
do
  local pp = require("personal_pairs")
  local notifier_cb
  local opts = { ai_ctx_reset = false }
  local ctx = { input = "", commit_history = { to_table = function() return { 1, 2, 3 } end },
    select_notifier = { connect = function() end }, commit_notifier = { connect = function() end },
    option_update_notifier = { connect = function(_, f) notifier_cb = f end },
    get_option = function(_, n) return opts[n] end, set_option = function(_, n, v) opts[n] = v end }
  local env = { engine = { context = ctx, schema = { config = { get_string = function() return "" end, get_int = function() return nil end,
    get_bool = function() return nil end, get_double = function() return nil end } } } }
  pp._reset_all(); pp.init(tmp .. "/recent_pairs.tsv")
  pp.record("明天", os.time())
  check("重置前有前一个词", pp.prev() == "明天")
  mod.init(env)
  opts.ai_ctx_reset = true
  notifier_cb(ctx, "ai_ctx_reset")
  check("收到 ai_ctx_reset 后前一个词作废", pp.prev() == nil)
  check("选项被还原成 false（可再次触发）", opts.ai_ctx_reset == false)
end

print(fails == 0 and "全部通过" or ("失败 " .. fails))
os.exit(fails == 0 and 0 or 1)
