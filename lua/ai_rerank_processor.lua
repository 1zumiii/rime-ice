-- ai_rerank_processor.lua — AI 重排的按键处理器（rime-llm-rerank 的 macOS 移植）
-- 上游：zhanghaozhecn/rime-llm-rerank（署名许可，作者 zhanghaozhecn）；逻辑取自其 Windows 侧修改版。
-- 作用：加载 rime_llm.so；维护"上文"（本会话内上屏的词）；每次按键后异步预解码；编辑键后重置上文。
-- 开关：方案开关 ai_rerank。关闭时本处理器直接放行，不加载、不记录。
-- 隐私：不写任何文件。上文只存在内存里，来自 Rime 自己的 commit_history，不读取任何应用里的文字。
-- 配置（llm_rerank 节点）：idle_unload_minutes 空闲多少分钟后卸载模型，默认 20，0 = 不卸载。
-- 在 engine/processors 增加 - lua_processor@*ai_rerank_processor（放在最前面）

local history = {}       -- 当前会话上屏词序列（base 之后）
local prev_hist = {}
local commit_base = 0    -- 上文基座：只认 commit_history 中 base 之后的新词（librime-lua 无法清 commit_history）
local llm_prep = nil
local last_prep_ctx = ""
local load_tried = false

local NAV_KEYS = { Left = true, Right = true, Up = true, Down = true,
                   Home = true, End = true, Page_Up = true, Page_Down = true }

-- 导航/换行类键（含 Control+Left、Shift+Home 等：以导航键名结尾的 repr 都算）
local function is_nav_ish_key(k)
    if NAV_KEYS[k] or k == "Return" or k == "KP_Enter" then return true end
    for name in pairs(NAV_KEYS) do
        if #k > #name and k:sub(-#name) == name then return true end
    end
    return false
end

-- 编辑位置变化键：退格/删除、导航、回车，以及撤销/重做/粘贴/剪切
-- 这些键之后，会话上屏词序列不再代表光标前的内容 → 上文重置为空
local function is_edit_key(k)
    if k == "BackSpace" or k == "Delete"
       or k == "Control+BackSpace" or k == "Control+Delete"
       or k:match("^Control%+[zyvxZYVX]$")
       or is_nav_ish_key(k) then
        return true
    end
    return false
end

local function reset_history()
    history = {}
    prev_hist = {}
    local ok, pp = pcall(require, "personal_pairs")   -- 编辑位置变了，个人词对的「前一个词」也作废
    if ok then pcall(pp.reset) end
end

local function user_dir()
    local ok, ud = pcall(function() return rime_api.get_user_data_dir() end)
    if ok and ud and ud ~= "" then return ud end
    return nil
end

-- 上文：只用本会话上屏的词。去空白（与 filter 保持一致，保证预解码命中）
local function get_context()
    return table.concat(history, "")
end
_G.ai_rerank_context_get = get_context

-- 异步预解码：上文变化时提前解码，按键时直接打分
local function trigger_prepare()
    local cur_ctx = get_context():gsub('%s+', '')
    if llm_prep and llm_prep.prepare and cur_ctx ~= last_prep_ctx then
        -- prepare 返回 true 才表示预解码真的排上了。模型还没加载好（刚启动、或被空闲卸载后）时它只会触发加载并返回 false，
        -- 这种情况不能记成"已预解码"，否则模型加载完成后上文没变，就再也不会补预解码。
        if llm_prep.prepare(cur_ctx) then last_prep_ctx = cur_ctx end
    end
end

-- 加载 rime_llm.so（放在用户目录的 lua/ 下），只尝试一次
local function load_llm(env)
    if load_tried then return end
    load_tried = true
    local ud = user_dir()
    if ud then
        local pat = ud .. "/lua/?.so"
        if not package.cpath:find(pat, 1, true) then
            package.cpath = pat .. ";" .. package.cpath
        end
    end
    local ok, cpp = pcall(require, "rime_llm")
    local err1 = (not ok) and tostring(cpp) or nil
    if not ok or type(cpp) ~= "table" then
        -- Android（Trime）：库在 APK 的原生库目录里，按文件名由系统加载器解析
        local f, err2 = package.loadlib("librime_llm.so", "luaopen_rime_llm")
        if f then
            ok, cpp = pcall(f)
            if not ok then err2 = tostring(cpp) end
        end
        if not (ok and type(cpp) == "table") then
            if ud then
                local fh = io.open(ud .. "/llm_load_error.txt", "w")
                if fh then fh:write(tostring(err1), "\n", tostring(err2), "\n"); fh:close() end
            end
            return
        end
    end
    local sc = env.engine.schema.config
    local mp = sc:get_string("llm_rerank/model_path")
    if mp and mp ~= "" then cpp.model_path = mp
    elseif ud then cpp.model_path = ud .. "/Qwen3.5-0.8B-Q4_K_M.gguf" end   -- 默认：用户目录下的模型（macOS 即 ~/Library/Rime）
    local mt = sc:get_int("llm_rerank/max_tokens")
    if mt then cpp.max_ctx = mt end
    local cores = sc:get_int("llm_rerank/cpu_cores")
    if cores then cpp.n_threads = cores end
    if ud then cpp.log_dir = ud end                    -- 日志只含模型路径与耗时，不含输入内容
    -- 空闲多少分钟没用就卸载模型（释放约 320 MB 内存），下次打字时自动加载回来（约 0.5~1 秒，期间不重排）。
    -- 0 = 不卸载。默认 20 分钟。
    local idle = sc:get_int("llm_rerank/idle_unload_minutes")
    if idle == nil then idle = 20 end
    cpp.idle_unload_sec = math.max(0, idle) * 60
    -- Android：Trime 在亮屏/熄屏时设置 Rime 选项 screen_off；转给常驻推理进程，熄屏后它会更快卸载模型（其他平台没有这个函数）
    if cpp.screen_off then
        env.engine.context.option_update_notifier:connect(function(c, name)
            if name == "screen_off" then pcall(cpp.screen_off, c:get_option("screen_off")) end
        end)
    end
    -- Android：手动启停。方案开关 ai_rerank（工具栏的 AI 徽标点一下就是切它）同步给常驻推理进程：
    -- 关 = 立刻卸载模型并拒绝一切推理（进程只剩待命，不占 CPU）；开 = 允许按需加载。启动时也同步一次当前状态。
    if cpp.set_enabled then
        local c = env.engine.context
        c.option_update_notifier:connect(function(cc, name)
            if name == "ai_rerank" then pcall(cpp.set_enabled, cc:get_option("ai_rerank")) end
        end)
        pcall(cpp.set_enabled, c:get_option("ai_rerank"))
    end
    llm_prep = cpp
    _G.ai_rerank_llm = cpp
end

-- === 选词统计（默认关闭）===
-- 作用：用你自己的真实输入评估重排有没有帮助（原顺序第一位被选中的比例 vs 重排后第一位被选中的比例），
--       并为调参（候选数、二次推理、词对权重）提供依据。
-- 内容：每次选词写一行纯数字到用户目录 select_stats.tsv：时间戳、AI 开关、模型（q = Qwen，s = 学生）、输入字母数、
--       参与重排的候选数、所选候选在原顺序和最终顺序里的位次、上文长度档、候选字数、候选类型、是否命中缓存。
--       不含任何输入的文字、拼音和候选文字。
-- 开关：用户目录里存在空文件 select_stats.enabled 才记录（新开的输入会话生效）；删除该文件即停止，删除 select_stats.tsv 即清空。
local function setup_select_stats(env)
    local ud = user_dir()
    if not ud then return end
    local probe = io.open(ud .. "/select_stats.enabled", "r")
    if not probe then _G.ai_select_stats_on = false; return end
    probe:close()
    _G.ai_select_stats_on = true
    local path = ud .. "/select_stats.tsv"
    local model_cache, model_ts = "q", 0
    local function model_kind()
        local now = os.time()
        if now - model_ts > 60 then
            model_ts = now
            local llm = _G.ai_rerank_llm
            if llm and llm.status then
                local ok, s = pcall(llm.status)
                model_cache = (ok and type(s) == "string" and s:find('"student":true', 1, true)) and "s" or "q"
            end
        end
        return model_cache
    end
    local last_key, last_t = "", 0
    env.engine.context.select_notifier:connect(function(ctx)
        pcall(function()
            local cand = ctx:get_selected_candidate()
            if not cand then return end
            local text = cand.text or ""
            local input = ctx.input or ""
            local now = os.time()
            local key = input .. "\1" .. text
            if key == last_key and now - last_t <= 1 then return end   -- 同一次选择被通知两次时只记一次
            last_key, last_t = key, now
            local seg = ctx.composition:back()
            local sel = (seg and seg.selected_index or 0) + 1          -- 最终顺序里的位次（从 1 起）
            local ai = ctx:get_option("ai_rerank") and 1 or 0
            local info = _G.ai_select_info
            local o, f, n, s1 = sel, sel, 0, "-"
            if ai == 1 and info and info.input == input then
                o, f, n, s1 = info.o[text] or 0, info.f[text] or sel, info.n, info.s1
            end
            local clen = #get_context():gsub("[\128-\191]", "")        -- 上文的字数
            local bucket = clen == 0 and 0 or clen <= 2 and 1 or clen <= 9 and 2 or 3
            local fh = io.open(path, "a")
            if not fh then return end
            if fh:seek("end") > 2 * 1024 * 1024 then
                fh:close(); os.rename(path, path .. ".old"); fh = io.open(path, "a")
                if not fh then return end
            end
            fh:write(string.format("%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n",
                now, ai, model_kind(), #input, n, o, f, bucket, utf8.len(text) or 0, tostring(cand.type), s1))
            fh:close()
        end)
    end)
end

-- === 词频（仅内存，重启即清）===
-- 衰减算法 = librime user_dictionary 调频同源：
--   提交: dee = 1 + dee·exp((t_old - t_now)/200)；查询: eff = dee·exp((t_word - t_now)/200)
local FREQ_TAU = 200
local word_freq = {}
local freq_tick = 0

local function freq_bump(word)
    freq_tick = freq_tick + 1
    local e = word_freq[word]
    if not e then
        e = { d = 0, t = 0 }
        word_freq[word] = e
    end
    e.d = 1 + e.d * math.exp((e.t - freq_tick) / FREQ_TAU)
    e.t = freq_tick
end

_G.ai_rerank_freq_eff = function(w)
    local e = word_freq[w]
    if not e or e.d <= 0 then return 0 end
    return e.d * math.exp((e.t - freq_tick) / FREQ_TAU)
end

local function find_overlap(prev, curr)
    local np, nc = #prev, #curr
    for len = math.min(np, nc), 0, -1 do
        local match = true
        for j = 1, len do
            if prev[np - len + j] ~= curr[j] then
                match = false
                break
            end
        end
        if match then return len end
    end
    return 0
end

local function processor(key, env)
    if key:release() then return 2 end

    local ctx = env.engine.context
    -- 开关关闭：不加载模型、不记录
    -- 先加载模块（不加载模型）：开关处于关闭状态时，也要把"关"同步给常驻推理进程
    if not llm_prep then load_llm(env) end
    if not ctx:get_option("ai_rerank") then return 2 end

    -- 每次按键刷新“最近使用”时间，避免只打短输入（不触发重排）时被误判为空闲而卸载模型
    if llm_prep and llm_prep.touch then llm_prep.touch() end

    -- 输入已清空（上屏/取消）：退格检测的状态归零
    if ctx.input == "" then _G.ai_rerank_state = nil end

    -- 模型被空闲卸载（或还在加载）：清掉"已预解码"的记录，这样 prepare 会触发加载，
    -- 加载完成后的下一次按键立刻补上预解码。
    if llm_prep and llm_prep.is_ready and not llm_prep.is_ready() then last_prep_ctx = "" end

    -- 上文变化 → 立即异步预解码
    trigger_prepare()

    local ch = ctx.commit_history
    if not ch then return 2 end

    -- 退格/删除/导航键（输入框内没有未上屏编码时）：编辑位置变化，上文重置
    if ctx.input == "" and is_edit_key(key:repr()) then
        reset_history()
        commit_base = #ch:to_table()   -- 旧词永久忽略
        _G.llm_filter_cache = nil      -- 编辑后重打相同词必须重新推理
        trigger_prepare()              -- 上文已空 → 预解码空上文
        return 0                       -- 放行按键，由后续处理器正常处理
    end

    -- 同步 commit_history
    local all = ch:to_table()
    if all and (#all < commit_base or (#all == 0 and #history > 0)) then
        -- 引擎清空了 commit_history：基座归零，并丢弃已记的上文（否则旧上文会一直残留）
        commit_base = 0
        reset_history()
    end
    if all and #all > commit_base then
        history = {}
        for i = commit_base + 1, #all do
            local entry = all[i]
            if entry and entry.text and #entry.text >= 1 then
                table.insert(history, entry.text)
            end
        end
        local overlap = find_overlap(prev_hist, history)
        for i = overlap + 1, #history do
            local w = history[i]
            if w:match("[^\1-\127]") then   -- 只统计含中文的词
                freq_bump(w)
            end
        end
        prev_hist = {}
        for _, v in ipairs(history) do table.insert(prev_hist, v) end
        -- 上文刚更新：立刻异步预解码，让它在两次按键之间的空档里完成。
        -- （按键开头的那次预解码用的还是旧上文——新上文要到这里才同步进来。）
        trigger_prepare()
    end

    return 2
end

-- 会话创建时就加载并同步一次开关（之前要等第一次按键才加载：在那之前点安卓徽标切换开关，守护进程收不到，表现为第一次点击失效）
return setmetatable({
    init = function(env) pcall(load_llm, env); pcall(setup_select_stats, env) end,
    func = processor,
}, { __call = function(_, key, env) return processor(key, env) end })   -- 仍可当函数直接调用（测试脚本这样用）
