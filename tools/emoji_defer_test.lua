-- emoji_defer_filter 的单元测试（模拟 Rime 环境）。
-- 用法：lua tools/emoji_defer_test.lua <仓库根目录>
local repo = arg[1] or "."
package.path = repo .. "/lua/?.lua;" .. package.path

local out
function yield(c) out[#out + 1] = c end

local M = require("emoji_defer_filter")
local fails = 0
local function check(name, cond, extra)
  print((cond and "PASS " or "FAIL ") .. name .. (extra and ("  [" .. extra .. "]") or ""))
  if not cond then fails = fails + 1 end
end

local function word(t) return { text = t, type = "phrase" } end
local function emoji(t) return { text = t, type = "simplified" } end
local function trad(t) return { text = t, type = "simplified" } end   -- 繁体转换结果，类型也是 simplified

-- 惰性迭代器：记录一共被取走多少个候选
local function run(list, page_size)
  local idx = 0
  local input = { iter = function() return function() idx = idx + 1; return list[idx] end end }
  M.init({ engine = { schema = { page_size = page_size } } })
  out = {}
  M.func(input, {})
  local t = {}
  for i, c in ipairs(out) do t[i] = c.text end
  return table.concat(t, " "), idx
end

-- 1. emoji 在第 2 位 → 推迟到第 6 位
local r = run({ word("笑"), emoji("😄"), word("哈"), word("嘻"), word("呵"), word("嘿"), word("哟") }, 5)
check("emoji moved to start of page 2", r == "笑 哈 嘻 呵 嘿 😄 哟", r)

-- 2. 第一页之后的 emoji 保持原位
r = run({ word("a"), word("b"), word("c"), word("d"), word("e"), word("f"), emoji("😀"), word("g") }, 5)
check("emoji after page 1 stay in place", r == "a b c d e f 😀 g", r)

-- 3. 多个 emoji 一起推迟，保持相对顺序
r = run({ word("a"), emoji("😀"), emoji("😁"), word("b"), word("c"), word("d"), word("e"), word("f") }, 5)
check("several emoji keep their order", r == "a b c d e 😀 😁 f", r)

-- 4. 候选不足一页：emoji 放最后
r = run({ word("a"), emoji("😀"), word("b") }, 5)
check("short list: emoji at the end", r == "a b 😀", r)

-- 5. 简繁转换的候选（含汉字）不被当成 emoji
r = run({ word("笑"), trad("笑"), word("哈"), word("嘻"), word("呵"), word("嘿") }, 5)
check("traditional-converted candidate not treated as emoji", r == "笑 笑 哈 嘻 呵 嘿", r)

-- 6. 没有 emoji 时原样输出
r = run({ word("a"), word("b"), word("c") }, 5)
check("no emoji: unchanged", r == "a b c", r)

-- 7. 符号类的 emoji（不含字母/汉字）
check("is_emoji_text: symbols", M.is_emoji_text("❤️") and M.is_emoji_text("👍🏻") and M.is_emoji_text("😄"))
check("is_emoji_text: letters/CJK/digits are not emoji",
      not M.is_emoji_text("abc") and not M.is_emoji_text("笑") and not M.is_emoji_text("1😄") and not M.is_emoji_text(""))

-- 8. 惰性：第一页凑满后，后面的候选不会被提前取走（只取到被消费的位置）
do
  local list = {}
  for i = 1, 100 do list[i] = word("w" .. i) end
  list[2] = emoji("😄")
  local idx = 0
  local input = { iter = function() return function() idx = idx + 1; return list[idx] end end }
  M.init({ engine = { schema = { page_size = 5 } } })
  -- 用协程模拟 Rime 只拉取一页（5 个）候选就丢弃协程
  local co = coroutine.create(function() M.func(input, {}) end)
  local got = {}
  function yield(c) got[#got + 1] = c; if #got >= 5 then coroutine.yield() end end
  coroutine.resume(co)
  check("lazy: pulls only about one page from the source", idx <= 8, "pulled " .. idx)
  check("lazy: first page has no emoji", (function() for _, c in ipairs(got) do if c.type == "simplified" then return false end end return true end)())
end

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
