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
_G.ai_select_info = { input = "jingli", o = { ["经理"] = 1, ["经历"] = 2, ["精力"] = 3 }, f = { ["精力"] = 1, ["经历"] = 2, ["经理"] = 3 }, n = 3, s1 = "miss", s2 = "-" }
fire()
local ls = read_lines()
check("写了一行", #ls == 1)
local f = {}
for x in (ls[1] or ""):gmatch("[^\t]+") do f[#f + 1] = x end
check("11 列", #f == 11, tostring(#f))
check("AI 开、输入 6 个字母、候选 3 个", f[2] == "1" and f[4] == "6" and f[5] == "3")
check("原顺序第 3 位，最终第 1 位", f[6] == "3" and f[7] == "1")
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
print(fails == 0 and "全部通过" or ("失败 " .. fails))
os.exit(fails == 0 and 0 or 1)
