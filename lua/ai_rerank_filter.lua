-- ai_rerank_filter.lua — 本地小模型按上文重排候选（rime-llm-rerank 的 macOS 移植）
-- 上游：zhanghaozhecn/rime-llm-rerank（署名许可，作者 zhanghaozhecn）；
--       两阶段（四字 = 两个两字词）与全拼适配取自其 Windows 侧修改版。
-- 在 engine/filters 增加 - lua_filter@*ai_rerank_filter（放在最后，uniquifier 之后）
-- 开关：方案开关 ai_rerank。关闭时直接透传，不取尽候选、不加载模型。
-- 上文：本会话内上屏的词（由 ai_rerank_processor 维护），不读取任何应用里的文字。
-- 隐私：不写任何含输入内容的文件。debug_latency: true 时只写 输入长度|毫秒|推理次数。
-- 配置（方案里的 llm_rerank 节点）：
--   code_pattern            触发的编码正则（全串匹配），默认 [a-z]{3,}（避开单/双字母，保留置顶词与简拼）
--   max_candidates          参与重排的候选数，默认 5
--   max_tokens              上文 token 数，默认 10
--   expected_length_weight  预期词长加成，全拼设 0（默认 0）
--   freq_beta               词频融合系数，默认 1.5
--   pair_gamma              个人词对融合系数（前一个词 → 当前词，见 personal_pairs.lua），默认 1.5，0 = 关闭
--   scan_limit              只在前 N 个候选里重排，其余惰性透传，默认 80
--   stage2                  四字两阶段总开关，默认 true
--   stage2_context_chars    第二阶段只用最后 N 个字作为上文，默认 8（现场解码，越短越快）
--   stage2_min_rest         剩余拼音至少 N 个字母才跑第二阶段，默认 4
--   badge / badge2          首选候选的注释标记：重排后的首选 / 两阶段拼出来的首选，默认 ◇ / ◈（单字符，省空间；❖ 仍表示语法模型整句）
--   model_path / cpu_cores  见 ai_rerank_processor

local cfg = {
    code_pattern = '[a-z]{3,}',
    max_candidates = 5,
    expected_length_weight = 0,
    freq_beta = 1.5,
    pair_gamma = 1.5,
    scan_limit = 80,
    stage2 = true,              -- 四字两阶段总开关；怀疑它有问题时设为 false
    stage2_context_chars = 8,   -- 第二阶段只用「上文+第一阶段选中词」的最后 N 个字，解码更快
    stage2_min_rest = 4,        -- 剩余拼音至少 N 个字母才跑第二阶段（输入过程中的半截拼音不值得推理）
    badge = "◇",       -- AI 按上文重排后的首选
    badge2 = "◈",      -- 两阶段拼出来的首选（四字 = 两个两字词）
    debug_latency = false,
}

-- 结果缓存：同一 (上文, 输入) 的评分复用（翻页/候选窗重建不重复推理）。
-- 存 _G 以便 ai_rerank_processor 在编辑操作后清空。
_G.llm_filter_cache = _G.llm_filter_cache or nil

-- 个人词对：前一个词 → 候选 的衰减计数（模块不可用或没有前一个词时恒为 0）
local okpp, pp = pcall(require, "personal_pairs")
local function pair_eff(prev, w)
    if not okpp or not prev or cfg.pair_gamma <= 0 then return 0 end
    local ok, v = pcall(pp.eff, prev, w)
    return (ok and v) or 0
end

local function is_finite_number(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function is_valid_llm_score(v)
    return is_finite_number(v) and v > -1e9
end

local function get_config_number(sc, key)
    local ok, v = pcall(function() return sc:get_double(key) end)
    if ok and is_finite_number(v) then return v end
    ok, v = pcall(function() return sc:get_string(key) end)
    if ok then
        v = tonumber(v)
        if is_finite_number(v) then return v end
    end
    return nil
end

local function init_config(env)
    local sc = env.engine.schema.config
    local pat = sc:get_string("llm_rerank/code_pattern")
    if pat ~= nil then cfg.code_pattern = pat end
    local v = get_config_number(sc, "llm_rerank/expected_length_weight")
    if v ~= nil then cfg.expected_length_weight = math.max(0, v) end
    v = get_config_number(sc, "llm_rerank/freq_beta")
    if v ~= nil then cfg.freq_beta = math.max(0, v) end
    v = get_config_number(sc, "llm_rerank/pair_gamma")
    if v ~= nil then cfg.pair_gamma = math.max(0, v) end
    v = sc:get_int("llm_rerank/max_candidates")
    if v then cfg.max_candidates = v end
    v = sc:get_int("llm_rerank/scan_limit")
    if v then cfg.scan_limit = v end
    local s2on = sc:get_bool("llm_rerank/stage2")
    if s2on ~= nil then cfg.stage2 = s2on end
    v = sc:get_int("llm_rerank/stage2_context_chars")
    if v then cfg.stage2_context_chars = v end
    v = sc:get_int("llm_rerank/stage2_min_rest")
    if v then cfg.stage2_min_rest = v end
    local b = sc:get_string("llm_rerank/badge")
    if b ~= nil then cfg.badge = b end
    b = sc:get_string("llm_rerank/badge2")
    if b ~= nil then cfg.badge2 = b end
    local dl = sc:get_bool("llm_rerank/debug_latency")
    if dl ~= nil then cfg.debug_latency = dl end
end

-- 编码匹配：优先用 .so 的 std::regex（ECMAScript），不可用时回退 Lua 模式
local function match_code_pattern(llm, code)
    local pat = cfg.code_pattern
    if not pat or pat == "" then return true end
    if llm and llm.match_code then
        local ok, r = pcall(llm.match_code, pat, code)
        if ok then return r and true or false end
    end
    local ok, s, e = pcall(string.find, code, pat)
    if not ok or not s then return false end
    return s == 1 and e == #code
end

local function get_scores(llm, cands)
    if not llm or not llm.get_scores then return nil end
    local ok, scores = pcall(function() return llm.get_scores() end)
    if not ok or type(scores) ~= "table" then return nil end
    for _, text in ipairs(cands) do
        if not is_finite_number(scores[text]) then return nil end
    end
    return scores
end

-- yield 包装：capture 非空时把候选收集起来，否则直接 yield
local capture = nil
local function Y(c)
    if capture then capture[#capture + 1] = c else yield(c) end
end

local function append_line(name, line)
    local ok, ud = pcall(function() return rime_api.get_user_data_dir() end)
    if not ok or not ud or ud == "" then return end
    local f = io.open(ud .. "/" .. name, "a")
    if f then f:write(line .. "\n"); f:close() end
end

-- 调试：只记录"为什么没有重排"的原因码，不含任何输入或候选文字（debug_latency: true 时才写）
local function dbg(msg)
    if cfg.debug_latency then
        append_line("llm_errors.txt", os.date("%H:%M:%S") .. " " .. msg)
    end
end

-- 调试标志（仅数字/原因码，不含文字）：由 inner 填写，wrapper 在 debug_latency 时写入 llm_latency.txt
local flags = {}

-- 取字符串最后 n 个 UTF-8 字符
local function tail_chars(str, n)
    local len = utf8.len(str)
    if not len or len <= n then return str end
    return str:sub(utf8.offset(str, len - n + 1))
end

-- === 第二阶段 ===
-- 用 ScriptTranslator 查剩余拼音的候选，以"上文 + 第一阶段选中词"为上文打分，返回最优词。
-- 只有 Component.Translator(engine, "", "script_translator@translator") 的 query 能返回候选。
-- 候选文字不做繁简转换（雾凇词库本身是简体）。
-- 翻译器必须按引擎各自持有（存在 env 里，随引擎销毁）。鼠须管每个输入框/应用都有独立的引擎，
-- 而 Lua 模块是共享的：缓存成模块级变量会让后来的输入框用上已被销毁的引擎里的翻译器，
-- 之后 query 会访问野指针，直接段错误（崩溃报告：ScriptTranslator::Query）。
local function s2_translator(env)
    if not env.ai_s2_tr then
        pcall(function()
            env.ai_s2_tr = Component.Translator(env.engine, "", "script_translator@translator")
        end)
    end
    return env.ai_s2_tr
end

-- 返回 w2, cands2；失败返回 nil
local function second_stage(env, llm, context, w1, rest)
    local s2_tr = s2_translator(env)
    if not s2_tr or not llm or rest == "" then return nil end
    local okseg, seg = pcall(function() return env.engine.context.composition:back() end)
    if not okseg or not seg then return nil end
    local cands2, seen = {}, {}
    local okq = pcall(function()
        local t = s2_tr:query(rest, seg)
        if not t then return end
        local n = 0
        for cand in t:iter() do
            n = n + 1
            if n > 60 then break end
            local e = cand._end
            if type(e) == "number" and e >= #rest then
                local txt = cand.text
                if txt and txt ~= "" and not seen[txt] then
                    seen[txt] = true
                    cands2[#cands2 + 1] = txt
                    if #cands2 >= cfg.max_candidates then break end
                end
            end
        end
    end)
    if not okq or #cands2 == 0 then return nil end
    if #cands2 == 1 then return cands2[1], cands2 end
    _G.llm_infer_n = (_G.llm_infer_n or 0) + 1
    local ok2, result = pcall(function() return llm.score(tail_chars(context .. w1, cfg.stage2_context_chars), cands2) end)
    if not ok2 or type(result) ~= "table" or not result[1] then return cands2[1], cands2 end
    local okg, scores = pcall(function() return llm.get_scores() end)
    local best = result[1]
    if okg and type(scores) == "table" then
        local freq_eff = _G.ai_rerank_freq_eff
        local best_t = nil
        for _, w in ipairs(cands2) do
            local s = scores[w]
            if is_valid_llm_score(s) then
                local t = s + cfg.freq_beta * math.log(1 + (freq_eff and freq_eff(w) or 0))
                if not best_t or t > best_t then best_t = t; best = w end
            end
        end
    end
    return best, cands2
end

local function inner(translation, env)
    if not cfg._inited then
        init_config(env)
        cfg._inited = true
    end

    local all = {}
    for cand in translation:iter() do table.insert(all, cand) end
    if #all < 2 then dbg("skip: <2 candidates"); for _, c in ipairs(all) do Y(c) end; return end

    local input = env.engine.context.input or ""
    -- 输入串变短 = 用户在退格改字：跳过第二阶段（它要现场解码，约 100 ms），改完再往后打时恢复。
    -- 同一个输入串被过滤器多次调用时保持"改字中"的判断；输入清空时由 processor 重置。
    local st = _G.ai_rerank_state
    if not st then st = { last = "", skip = nil }; _G.ai_rerank_state = st end
    local shrinking
    if st.skip == input then
        shrinking = true
    elseif #st.last > 0 and #input < #st.last then
        st.skip = input
        shrinking = true
    else
        st.skip = nil
        shrinking = false
    end
    st.last = input
    flags.shr = shrinking and "1" or "0"
    local llm = _G.ai_rerank_llm   -- 由 ai_rerank_processor 加载
    if not llm then
        dbg("skip: llm module not loaded (_G.ai_rerank_llm is nil)")
        for _, c in ipairs(all) do Y(c) end; return
    end

    -- 触发条件：编码串匹配 code_pattern
    if not match_code_pattern(llm, input) then
        dbg("skip: code_pattern mismatch, input_len=" .. #input)
        for _, c in ipairs(all) do Y(c) end; return
    end

    -- 全拼适配：候选窗里混有只覆盖前几个音节的前缀词（_end < #input），模型只看每个
    -- 候选的前 3 个 token，短前缀词会系统性占优。所以只在同一覆盖长度（相同 _end）的
    -- 一组候选内重排，结果按原位次回填，其余候选位置不动。取不到 _end 时视为全部覆盖。
    local orig = all
    local full, full_pos, has_end = {}, {}, false
    local groups, best_e = {}, nil
    for i, c in ipairs(orig) do
        local okend, e = pcall(function() return c._end end)
        if okend and type(e) == "number" then
            has_end = true
            local g = groups[e]
            if not g then g = {}; groups[e] = g end
            g[#g + 1] = i
        end
    end
    -- 两阶段：输入有剩余时优先选"两字词"那一组做第一阶段（四字 = 两个两字词）。
    -- (1) 整串覆盖的组有 >=2 个候选时直接用它（两音节输入，无第二阶段）；
    -- (2) 否则取 Rime 原生顺序里第一个"两字词且未覆盖整串"的候选所在的组
    --     （不能取最小 e，否则会选到 yi+yu 之类的错误切分前缀）；
    -- (3) 都没有就取覆盖最长且至少 2 个候选的组。
    if groups[#input] and #groups[#input] >= 2 then
        best_e = #input
    else
        for _, c in ipairs(orig) do
            local okend, e = pcall(function() return c._end end)
            if okend and type(e) == "number" and e < #input
               and (utf8.len(c.text or "") or 0) == 2 and groups[e] and #groups[e] >= 2 then
                best_e = e
                break
            end
        end
    end
    if not best_e then
        for e, g in pairs(groups) do
            if #g >= 2 and (not best_e or e > best_e) then best_e = e end
        end
    end
    if best_e then
        for _, i in ipairs(groups[best_e]) do
            full[#full + 1] = orig[i]
            full_pos[#full_pos + 1] = i
        end
    end
    if not has_end then
        full, full_pos = orig, {}
        for i = 1, #orig do full_pos[i] = i end
    end
    if #full < 2 then
        dbg(string.format("skip: group<2 (has_end=%s, groups=%d, input_len=%d)",
            tostring(has_end), (function() local n = 0; for _ in pairs(groups) do n = n + 1 end; return n end)(), #input))
        for _, c in ipairs(orig) do Y(c) end; return
    end
    all = full
    local out = {}
    local function emit(c) out[#out + 1] = c end
    local extra_first = nil   -- 两阶段拼接候选，置于首位
    local function finish()
        -- 把 out（重排后的这一组）按原位次填回，其余候选原样保留
        local res = {}
        if #out ~= #full_pos then
            for _, c in ipairs(out) do res[#res + 1] = c end
            local isfull = {}
            for _, p in ipairs(full_pos) do isfull[p] = true end
            for i, c in ipairs(orig) do
                if not isfull[i] then res[#res + 1] = c end
            end
        else
            local slot = {}
            for k, p in ipairs(full_pos) do slot[p] = out[k] end
            for i, c in ipairs(orig) do res[#res + 1] = slot[i] or c end
        end
        if extra_first then
            Y(extra_first)
            for _, c in ipairs(res) do
                if c.text ~= extra_first.text then Y(c) end
            end
        else
            for _, c in ipairs(res) do Y(c) end
        end
    end

    local ctx_text = ""
    if _G.ai_rerank_context_get then ctx_text = _G.ai_rerank_context_get() end
    local context = (ctx_text or ""):gsub('%s+', '')
    local cands = {}
    for i, c in ipairs(all) do
        if i > cfg.max_candidates then break end
        table.insert(cands, c.text)
    end

    -- 第一阶段缓存：按「上文 + 候选列表」缓存，而不是按输入串。输入第二个词的每个字母时，
    -- 第一阶段的候选其实没变，不需要重新推理。
    local key1 = context .. "\1" .. table.concat(cands, "\2")
    local cache = _G.llm_filter_cache
    local ok, result, scores
    if cache and cache.key == key1 and cache.result then
        ok, result, scores = true, cache.result, cache.scores
        flags.s1 = "hit"
    else
        _G.llm_infer_n = (_G.llm_infer_n or 0) + 1
        local why
        -- allow_sync = false：上文没预解码好、或后台预解码占着锁时，不在主线程上等待或现场解码，
        -- 这次按键保持原顺序，下一次按键再重排（避免输入卡顿）
        ok, result, why = pcall(function() return llm.score(context, cands, false) end)
        if ok and type(result) == "table" then
            scores = get_scores(llm, cands)
            _G.llm_filter_cache = { key = key1, result = result, scores = scores }
            flags.s1 = "miss"
        else
            flags.s1 = "skip:" .. tostring(why or "nil")
            -- 预解码没就绪：补一次异步预解码，下一次按键就能用
            if why == "unprepared" and llm.prepare then pcall(llm.prepare, context) end
        end
    end

    dbg(string.format("scored: ok=%s result=%s ctx_len=%d cands=%d best_e=%s input_len=%d",
        tostring(ok), type(result), #context, #cands, tostring(best_e), #input))
    if ok and result then
        local seen = {}
        local ordered = {}
        for i = 1, #result do
            for _, c in ipairs(all) do
                if c.text == result[i] and not seen[c.text] then
                    seen[c.text] = true
                    table.insert(ordered, c)
                    break
                end
            end
        end
        -- 融合：fused(w) = score(w) + β·log(1+eff(w))
        -- score = 模型分（−交叉熵）；eff = 本会话词频的时间衰减计数（processor 维护）
        -- 无效分排尾部、不参与；同分保持模型序
        local fused_scores = nil
        if #ordered > 1 and scores then
            local freq_eff = _G.ai_rerank_freq_eff
            local prev_word = okpp and cfg.pair_gamma > 0 and pp.prev() or nil
            fused_scores = {}
            local arr = {}
            for i, c in ipairs(ordered) do
                local s = scores[c.text]
                if is_valid_llm_score(s) then
                    local n = freq_eff and freq_eff(c.text) or 0
                    local t = s + cfg.freq_beta * math.log(1 + n)
                        + cfg.pair_gamma * math.log(1 + pair_eff(prev_word, c.text))
                    fused_scores[c.text] = t
                    arr[i] = { c = c, t = t, idx = i }
                else
                    fused_scores[c.text] = -math.huge
                    arr[i] = { c = c, t = -math.huge, idx = i }
                end
            end
            table.sort(arr, function(a, b)
                if a.t ~= b.t then return a.t > b.t end
                return a.idx < b.idx
            end)
            for i = 1, #arr do ordered[i] = arr[i].c end
        end
        -- 预期词长加权：两码一字方案才有意义，全拼保持 0（默认）
        if cfg.expected_length_weight > 0 and #ordered > 1 and fused_scores then
            local expected_len = math.floor(#input / 2)
            local min_score, max_score
            for _, c in ipairs(ordered) do
                local s = scores[c.text]
                if is_valid_llm_score(s) then
                    if not min_score or s < min_score then min_score = s end
                    if not max_score or s > max_score then max_score = s end
                end
            end
            local span = (min_score and max_score) and (max_score - min_score) or 0
            if expected_len >= 1 and span > 0 then
                local arr, ok2 = {}, true
                for i, c in ipairs(ordered) do
                    local f = fused_scores[c.text]
                    if not f or f == -math.huge then ok2 = false; break end
                    local len = utf8.len(c.text or "") or 0
                    arr[i] = { c = c, s = f, m = (len == expected_len), idx = i }
                end
                if ok2 then
                    for _, item in ipairs(arr) do
                        if item.m then item.s = item.s + cfg.expected_length_weight * span end
                    end
                    table.sort(arr, function(a, b)
                        if a.s ~= b.s then return a.s > b.s end
                        if a.m ~= b.m then return a.m end
                        return a.idx < b.idx
                    end)
                    for i = 1, #arr do ordered[i] = arr[i].c end
                end
            end
        end

        -- 第二阶段：第一阶段选中 w1 并入上文，对剩余拼音的候选再打分，拼成 w1..w2 作为首选
        -- （每阶段结果缓存；编辑键清缓存时一并清除）。任何一步失败都退回第一阶段结果。
        if best_e and best_e < #input and ordered[1] and context ~= ""
           and cfg.stage2 and not shrinking and (#input - best_e) >= cfg.stage2_min_rest then
            local w1 = ordered[1].text
            local rest = input:sub(best_e + 1)
            local fc = _G.llm_filter_cache
            local w2 = nil
            if fc and fc.s2 and fc.s2.w1 == w1 and fc.s2.rest == rest then
                w2 = fc.s2.w2 or nil
                flags.s2 = "hit"
            else
                flags.s2 = "run"
                local okc, r1 = pcall(second_stage, env, llm, context, w1, rest)
                if okc and r1 then w2 = r1 end
                if fc then fc.s2 = { w1 = w1, rest = rest, w2 = w2 or false } end
            end
            if w2 then
                local okcand, cand = pcall(function()
                    local st = orig[1]._start
                    return Candidate("sentence", type(st) == "number" and st or 0,
                                     #input, w1 .. w2, cfg.badge2)
                end)
                if okcand and cand then extra_first = cand end
            end
        end

        for i, c in ipairs(ordered) do
            if i == 1 and cfg.badge ~= "" then
                local cm = c.comment
                if cm and cm ~= "" then cm = cm .. " " .. cfg.badge else cm = cfg.badge end
                emit(ShadowCandidate(c, c.type, c.text, cm, true))
            else
                emit(c)
            end
        end
        for _, c in ipairs(all) do
            if not seen[c.text] then emit(c) end
        end
    else
        for _, c in ipairs(all) do emit(c) end
    end
    finish()
end

-- === 外层包装 ===
-- 开关关闭：原样惰性透传（不取尽候选）。
-- 开关打开：只取前 scan_limit 个候选做重排（雾凇词库大，输入单个字母时候选数以万计，
-- 取尽会卡），其余候选保持惰性透传；先收集、再 yield（Rime 只拉取窗口所需数量，之后会丢弃协程）；
-- inner 出错时退回原生顺序，不让候选窗变空。
return function(translation, env)
    if not cfg._inited then
        init_config(env)
        cfg._inited = true
    end
    if not env.engine.context:get_option("ai_rerank") then
        dbg("filter called: switch OFF in this session")
        _G.ai_select_info = nil   -- 选词统计：本次没有重排，按原顺序记
        local first_seen = false
        for cand in translation:iter() do
            if _G.ai_select_stats_on and not first_seen then
                first_seen = true
                _G.ai_select_info = { input = env.engine.context.input or "", o = {}, f = {}, n = 0,
                                      s1 = "-", s2 = "-", ft = cand.text, of = cand.text, off = true }
            end
            yield(cand)
        end
        return
    end
    dbg("filter called: switch ON")

    local t0 = os.clock()
    local n0 = _G.llm_infer_n or 0
    flags = {}

    local native = {}
    for cand in translation:iter() do
        native[#native + 1] = cand
        if #native >= cfg.scan_limit then break end
    end
    local k = 0
    local proxy = { iter = function() return function() k = k + 1; return native[k] end end }

    capture = {}
    local ok, err = pcall(inner, proxy, env)
    local cap = capture
    capture = nil
    if not ok and cfg.debug_latency then
        append_line("llm_errors.txt", os.date("%H:%M:%S") .. " " .. tostring(err))
    end
    if not ok or #cap == 0 then cap = native end

    -- 选词统计（见 ai_rerank_processor 的 select_stats）：只记每个候选在原始顺序和最终顺序里的位次，不记文字内容之外的任何东西
    if _G.ai_select_stats_on then
        local o, fpos = {}, {}
        for i, c in ipairs(native) do if not o[c.text] then o[c.text] = i end end
        for i, c in ipairs(cap) do if not fpos[c.text] then fpos[c.text] = i end end
        _G.ai_select_info = { input = env.engine.context.input or "", o = o, f = fpos, n = #native,
                              s1 = flags.s1 or "-", s2 = flags.s2 or "-",
                              ft = cap[1] and cap[1].text or "", of = native[1] and native[1].text or "" }
    end

    if cfg.debug_latency then
        local input = env.engine.context.input or ""
        append_line("llm_latency.txt", string.format("%d|%.1f|%d|s1=%s|s2=%s|shr=%s", #input,
            (os.clock() - t0) * 1000, (_G.llm_infer_n or 0) - n0,
            flags.s1 or "-", flags.s2 or "-", flags.shr or "-"))
    end

    for _, c in ipairs(cap) do yield(c) end
    -- scan_limit 之后的候选：惰性透传
    for cand in translation:iter() do yield(cand) end
end
