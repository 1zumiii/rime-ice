-- emoji 候选推迟到第二页：第一页只放文字候选，emoji 从第 page_size+1 位开始出现。
-- 在 engine/filters 增加 - lua_filter@*emoji_defer_filter（必须放在 simplifier@emoji 之后）
--
-- 识别方式：simplifier 生成的候选类型是 simplified，emoji 的文字里没有字母、数字、汉字、假名、谚文。
-- 简繁转换（traditionalize）出来的候选类型也是 simplified，但含汉字，不会被当成 emoji。
-- 前 page_size 个非 emoji 候选放出之后，被扣住的 emoji 紧接着放出，之后的 emoji 保持原位置；
-- 候选不足一页时，emoji 放在最后。整个过程保持惰性，不会取尽候选。

local M = {}

local function is_emoji_text(text)
    if not text or text == "" then return false end
    local ok, res = pcall(function()
        for _, cp in utf8.codes(text) do
            if (cp >= 0x30 and cp <= 0x39) or (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A)
               or (cp >= 0x3040 and cp <= 0x30FF)     -- 假名
               or (cp >= 0x3400 and cp <= 0x9FFF)     -- 汉字
               or (cp >= 0xF900 and cp <= 0xFAFF)     -- 兼容汉字
               or (cp >= 0xAC00 and cp <= 0xD7AF)     -- 谚文
               or (cp >= 0x20000 and cp <= 0x2FFFF) then  -- 扩展汉字
                return false
            end
        end
        return true
    end)
    return ok and res
end
M.is_emoji_text = is_emoji_text

function M.init(env)
    local size = nil
    pcall(function() size = env.engine.schema.page_size end)
    if type(size) ~= "number" or size < 1 then
        pcall(function() size = env.engine.schema.config:get_int("menu/page_size") end)
    end
    M.page_size = (type(size) == "number" and size >= 1) and size or 5
end

function M.func(input, env)
    local quota = M.page_size or 5
    local held, normal, released = {}, 0, false
    for cand in input:iter() do
        if not released and cand.type == "simplified" and is_emoji_text(cand.text) then
            held[#held + 1] = cand
        else
            yield(cand)
            normal = normal + 1
            if not released and normal >= quota then
                for _, e in ipairs(held) do yield(e) end
                held = {}
                released = true
            end
        end
    end
    for _, e in ipairs(held) do yield(e) end
end

return M
