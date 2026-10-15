-- 用模拟的 Rime 环境 + 真实 rime_llm.so + 真实模型，端到端跑 ai_rerank_filter / ai_rerank_processor
local repo, ud, model = arg[1], arg[2], arg[3]
package.path = repo .. "/lua/?.lua;" .. package.path

local fails = 0
local function check(name, cond, extra)
  print((cond and "PASS " or "FAIL ") .. name .. (extra and ("  [" .. extra .. "]") or ""))
  if not cond then fails = fails + 1 end
end

-- ---------- 模拟 Rime 环境 ----------
local yielded = nil
function yield(c) yielded[#yielded + 1] = c end
rime_api = { get_user_data_dir = function() return ud end }

local function mk(text, s, e, ctype, comment)
  return { text = text, _start = s, _end = e, type = ctype or "phrase", comment = comment or "" }
end
function Candidate(ctype, s, e, text, comment) return mk(text, s, e, ctype, comment) end
function ShadowCandidate(c, ctype, text, comment, _)
  local n = mk(text, c._start, c._end, ctype, comment); n.shadow = true; return n
end

local function mk_translation(list)
  local idx = 0   -- 共享游标：中断后再调用 iter() 会接着取
  return { iter = function() return function() idx = idx + 1; return list[idx] end end }, function() return idx end
end

local tail_cands = {}
Component = { Translator = function(_, _, name)
  return { query = function(_, rest, _)
    local t = mk_translation(tail_cands[rest] or {})
    return t
  end }
end }

local conf = { ["llm_rerank/model_path"] = model, ["llm_rerank/max_candidates"] = 5 }
local function mk_env(input, hist, enabled, extra_conf)
  local c = {}
  for k, v in pairs(conf) do c[k] = v end
  for k, v in pairs(extra_conf or {}) do c[k] = v end
  local ch = { to_table = function() local t = {}; for i, w in ipairs(hist) do t[i] = { text = w } end; return t end }
  return {
    engine = {
      schema = { config = {
        get_string = function(_, k) return c[k] and tostring(c[k]) or nil end,
        get_int = function(_, k) return type(c[k]) == "number" and math.floor(c[k]) or nil end,
        get_double = function(_, k) return type(c[k]) == "number" and c[k] or nil end,
        get_bool = function(_, k) return c[k] end,
      } },
      context = {
        input = input,
        commit_history = ch,
        composition = { back = function() return {} end },
        get_option = function(_, name) return name == "ai_rerank" and enabled end,
      },
    },
  }
end

-- ---------- 加载（processor 负责加载 .so）----------
os.execute("mkdir -p '" .. ud .. "/lua'")
local filter = require("ai_rerank_filter")
local processor = require("ai_rerank_processor")

local function press(env, repr)
  return processor({ release = function() return false end, repr = function() return repr end }, env)
end

-- 提交历史 → processor 同步 → 上文
local hist = { "他在公司当" }
local env0 = mk_env("", hist, true)
check("processor returns noop on normal key", press(env0, "a") == 2)
check("llm module loaded by processor", _G.ai_rerank_llm ~= nil)
check("context built from commit_history", _G.ai_rerank_context_get() == "他在公司当", _G.ai_rerank_context_get())

-- 等模型就绪（prepare/score 懒加载）
local llm = _G.ai_rerank_llm
local t0 = os.time()
while not llm.is_ready() do
  llm.score("你好", { "世界", "是借" })
  os.execute("sleep 0.3")
  if os.time() - t0 > 60 then print("FAIL model never ready"); os.exit(1) end
end
os.execute("sleep 0.5")

local function run(env, cands)
  yielded = {}
  local tr = mk_translation(cands)
  filter(tr, env)
  local texts = {}
  for i, c in ipairs(yielded) do texts[i] = c.text end
  return texts, yielded
end

-- A: 开关关闭 → 原样、惰性透传
do
  local cands = { mk("经理", 0, 6), mk("经历", 0, 6), mk("精力", 0, 6) }
  local texts = run(mk_env("jingli", hist, false), cands)
  check("A. disabled: passthrough unchanged", table.concat(texts, ",") == "经理,经历,精力", table.concat(texts, ","))
end

-- B: 两音节同音词，上文 "我最近没有太多" → 精力 应排第一
do
  hist = { "我最近没有太多" }
  press(mk_env("", hist, true), "b")   -- 同步新上文
  local cands = { mk("经理", 0, 6), mk("经历", 0, 6), mk("精力", 0, 6), mk("敬礼", 0, 6), mk("警力", 0, 6) }
  local texts, ys = run(mk_env("jingli", hist, true), cands)
  check("B. two-syllable rerank: 精力 first", texts[1] == "精力", table.concat(texts, ","))
  check("B. all 5 candidates kept", #texts == 5)
  check("B. badge on first", ys[1].comment:find("◇", 1, true) ~= nil, ys[1].comment)
end

-- C: 上文为空 → 不重排（原样）
do
  hist = {}
  press(mk_env("", hist, true), "e")
  local cands = { mk("经理", 0, 6), mk("经历", 0, 6), mk("精力", 0, 6) }
  local texts = run(mk_env("jingli", hist, true), cands)
  check("C. empty context: unchanged order", table.concat(texts, ",") == "经理,经历,精力", table.concat(texts, ","))
end

-- D: 四字两阶段：上文 "他在公司当"，jingliguolai → 经理过来
do
  hist = { "他在公司当" }
  press(mk_env("", hist, true), "c")
  _G.llm_filter_cache = nil
  tail_cands["guolai"] = { mk("过来", 0, 6), mk("果来", 0, 6), mk("国来", 0, 6) }
  local cands = {
    mk("经历过来", 0, 12, "sentence"),
    mk("经理", 0, 6), mk("经历", 0, 6), mk("精力", 0, 6),
    mk("敬礼", 0, 6),
  }
  local texts, ys = run(mk_env("jingliguolai", hist, true), cands)
  check("D. two-stage: 经理过来 first", texts[1] == "经理过来", table.concat(texts, ","))
  check("D. two-stage badge", ys[1].comment == "◈", ys[1].comment)
  check("D. original sentence kept", table.concat(texts, ","):find("经历过来", 1, true) ~= nil)
end

-- E: scan_limit 之后的候选惰性透传、顺序不变
do
  hist = { "他在公司当" }
  press(mk_env("", hist, true), "d")
  _G.llm_filter_cache = nil
  local cands = {}
  for i = 1, 12 do cands[i] = mk("词" .. i, 0, 6) end
  -- 过滤器的配置只读一次：重新加载模块，让 scan_limit 生效
  package.loaded["ai_rerank_filter"] = nil
  filter = require("ai_rerank_filter")
  local texts = run(mk_env("jingli", hist, true, { ["llm_rerank/scan_limit"] = 3 }), cands)
  check("E. no candidate lost with scan_limit", #texts == 12, tostring(#texts))
  local tail_ok = true
  for i = 4, 12 do if texts[i] ~= "词" .. i then tail_ok = false end end
  check("E. candidates after scan_limit keep order", tail_ok, table.concat(texts, ","))
end

-- F: 单字母输入不触发（默认 code_pattern [a-z]{3,}）
do
  local cands = { mk("的", 0, 1), mk("地", 0, 1), mk("得", 0, 1) }
  local texts = run(mk_env("d", hist, true), cands)
  check("F. single letter not reranked (pins safe)", table.concat(texts, ",") == "的,地,得", table.concat(texts, ","))
end

-- G: 编辑键重置上文
do
  hist = { "他在公司当" }
  press(mk_env("", hist, true), "x")
  check("G. context present before edit key", _G.ai_rerank_context_get() == "他在公司当")
  local r = press(mk_env("", hist, true), "BackSpace")
  check("G. edit key returns 0 (rejected, passes on)", r == 0)
  check("G. context cleared after edit key", _G.ai_rerank_context_get() == "", _G.ai_rerank_context_get())
end

-- H: 不写任何明文文件
do
  local p = io.popen("ls '" .. ud .. "' 2>/dev/null"); local ls = p:read("*a"); p:close()
  local bad = {}
  for name in ls:gmatch("[^\n]+") do
    if not (name == "lua" or name == "rime_llm_log.txt") then bad[#bad + 1] = name end
  end
  check("H. only expected files in user dir", #bad == 0, table.concat(bad, ","))
  local f = io.open(ud .. "/rime_llm_log.txt"); local log = f and f:read("*a") or ""; if f then f:close() end
  local leaked = false
  for _, w in ipairs({ "公司", "最近", "经理", "精力", "jingli" }) do if log:find(w, 1, true) then leaked = true end end
  check("H. log contains no input/candidate text", not leaked)
end

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
