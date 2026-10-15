-- 语法模型标记：整句组出来的候选（type == sentence）后面加一个小标记
-- 在 engine/filters 增加 - lua_filter@*model_badge_filter（放在 corrector 之后，否则注释会被覆盖）
-- 配置（方案里的 model_badge_filter 节点）：
--   badge  标记内容，默认 ❖
--   gram   语法模型文件名（在用户目录下），文件不存在时不显示标记
-- 说明：这只表示候选是整句拼出来的，Lua 无法查询 octagram 的内部状态，不能证明模型改变了排序。

local M = {}

function M.init(env)
    local config = env.engine.schema.config
    local ns = env.name_space:gsub("^%*", "")
    env.badge = config:get_string(ns .. "/badge") or "❖"
    local gram = config:get_string(ns .. "/gram") or "wanxiang-lts-zh-hans.gram"
    local f = io.open(rime_api:get_user_data_dir() .. "/" .. gram, "r")
    env.enabled = f ~= nil
    if f then f:close() end
end

function M.func(input, env)
    for cand in input:iter() do
        if env.enabled and cand.type == "sentence" then
            cand.comment = cand.comment .. env.badge
        end
        yield(cand)
    end
end

return M
