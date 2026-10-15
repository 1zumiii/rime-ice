-- 冒烟测试（不需要模型）：只验证模块能加载、接口存在、失败时优雅降级
local so_dir, log_dir = arg[1], arg[2]
package.cpath = so_dir .. "/?.so;" .. package.cpath
local m = assert(require("rime_llm"), "require failed")

local function check(name, cond) print((cond and "PASS " or "FAIL ") .. name); if not cond then os.exit(1) end end

for _, k in ipairs({ "score", "prepare", "is_ready", "llm_context", "kick_context",
                     "edit_reset_context", "fg_changed", "click_happened", "match_code" }) do
  check("function exists: " .. k, type(m[k]) == "function")
end

check("is_ready() == false before load", m.is_ready() == false)
check("llm_context() returns nil (no UIA on macOS)", m.llm_context() == nil)
check("fg_changed() == false", m.fg_changed() == false)
check("click_happened() == false", m.click_happened() == false)
check("match_code('.+','nihao') == true", m.match_code(".+", "nihao") == true)
check("match_code('.{4}','nihao') == false", m.match_code(".{4}", "nihao") == false)
check("match_code('','x') == true (empty pattern)", m.match_code("", "x") == true)

-- 模型路径不存在：score 应返回 nil 而不是崩溃
m.log_dir = log_dir
m.model_path = log_dir .. "/no_such_model.gguf"
check("score() with no model returns nil", m.score("你好", { "世界", "是借" }) == nil)
os.execute("sleep 2")
check("still not ready after failed load", m.is_ready() == false)
print("ALL OK")
