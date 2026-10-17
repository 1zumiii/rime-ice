-- 最近使用优先：最近上屏过的词，提升到靠前的候选位置
-- 在 engine/filters 增加 - lua_filter@*recent_boost_filter（放在 pin_cand_filter 之前，置顶词仍在最前）
-- 配置（方案里的 recent_boost_filter 节点）：
--   window_hours  多少小时内用过算「最近」，默认 72
--   idx           提升到第几个候选位置，默认 2
--   max_boost     最多提升几个词，默认 2
--   scan          只在前 scan 个候选里找，默认 40
--   min_count     窗口内至少用过几次才提升，默认 1
--   max_records   活动记录文件最多保留的使用记录数，默认 3000；更早的记录移到归档，不丢弃
--   pairs         是否启用个人词对（前一个词 → 当前词，见 personal_pairs.lua），默认 true
--   min_pair      词对计数至少多大才提升，默认 1.5（至少要重复出现两次左右；单次的偶然搭配或误选不会被提升）
-- 使用记录保存在用户目录的 recent_words.tsv（每行：时间戳<Tab>词），不属于仓库，安装脚本会保留它。
-- 多个应用的输入会话各自读取记录，新开的会话才会读到别处刚产生的记录。

local M = {}

local FILE_NAME = "recent_words.tsv"

-- 只记录、只提升这些类型的候选；标点、emoji、计算器等不处理
local ELIGIBLE = {
    phrase = true,
    user_phrase = true,
    sentence = true,
}

local function record_path()
    local dir = rime_api:get_user_data_dir()
    local sep = "/"
    local name = rime_api:get_distribution_code_name():lower()
    if name:match("weasel") then sep = "\\" end
    return dir .. sep .. FILE_NAME
end

-- 读取记录，返回 { [词] = { last = 最近时间戳, count = 窗口内次数 } } 与全部原始记录
local function load_records(path, window_start)
    local words = {}
    local f = io.open(path, "r")
    if not f then return words, {} end
    local raw = {}
    for line in f:lines() do
        local ts, text = line:match("^(%d+)\t(.+)$")
        if ts then
            ts = tonumber(ts)
            raw[#raw + 1] = { ts, text }
            if ts >= window_start then
                local e = words[text]
                if not e then
                    e = { last = ts, count = 0 }
                    words[text] = e
                end
                e.count = e.count + 1
                if ts > e.last then e.last = ts end
            end
        end
    end
    f:close()
    return words, raw
end

-- 记录过多时只保留最新的 max_records 条；被挤出的旧记录先追加到归档（recent_words.archive.tsv，见 corpus_archive.lua），
-- 归档写成功后才改写活动文件，所以不会丢记录。
local function compact(path, raw, max_records)
    if #raw <= max_records then return end
    local ok_arc, arc = pcall(require, "corpus_archive")
    if ok_arc then
        local dropped = {}
        for i = 1, #raw - max_records do
            dropped[#dropped + 1] = string.format("%d\t%s", raw[i][1], raw[i][2])
        end
        if not arc.append(path, dropped) then return end   -- 归档写不进去就先不截断
    end
    local f = io.open(path, "w")
    if not f then return end
    for i = #raw - max_records + 1, #raw do
        f:write(string.format("%d\t%s\n", raw[i][1], raw[i][2]))
    end
    f:close()
end

local function append_record(path, ts, text)
    local f = io.open(path, "a")
    if not f then return end
    f:write(string.format("%d\t%s\n", ts - ts % 60, text))   -- 落盘的时间戳只到分钟
    f:close()
end

function M.init(env)
    local config = env.engine.schema.config
    local ns = env.name_space:gsub("^%*", "")
    env.window = (config:get_int(ns .. "/window_hours") or 72) * 3600
    env.idx = config:get_int(ns .. "/idx") or 2
    env.max_boost = config:get_int(ns .. "/max_boost") or 2
    env.scan = config:get_int(ns .. "/scan") or 40
    env.min_count = config:get_int(ns .. "/min_count") or 1
    local max_records = config:get_int(ns .. "/max_records") or 3000

    local use_pairs = config:get_bool(ns .. "/pairs")
    if use_pairs == nil then use_pairs = true end
    env.min_pair = (config:get_double(ns .. "/min_pair") or 1.5)
    if use_pairs then
        local ok, pp = pcall(require, "personal_pairs")
        if ok then
            pcall(pp.init)
            env.pp = pp
        end
    end

    env.path = record_path()
    local raw
    env.words, raw = load_records(env.path, os.time() - env.window)
    compact(env.path, raw, max_records)

    -- 每次上屏后记录：只处理最后一条提交记录，出错时不影响输入
    env.commit_conn = env.engine.context.commit_notifier:connect(function(ctx)
        pcall(function()
            local rec = ctx.commit_history:back()
            if not rec or not ELIGIBLE[rec.type] then return end
            local text = rec.text
            if not text or text == "" or text:find("[\t\r\n]") then return end
            local now = os.time()
            append_record(env.path, now, text)
            if env.pp then env.pp.record(text, now) end
            local e = env.words[text]
            if e then
                e.last = now
                e.count = e.count + 1
            else
                env.words[text] = { last = now, count = 1 }
            end
        end)
    end)
end

function M.fini(env)
    if env.commit_conn then
        env.commit_conn:disconnect()
        env.commit_conn = nil
    end
end

function M.func(input, env)
    -- 只处理普通拼音输入（全小写字母和分隔符），其他模式（v 符号、大写开头的英文/计算器等）原样输出
    local code = env.engine.context.input
    if not code:match("^[a-z' ]+$") then
        for cand in input:iter() do yield(cand) end
        return
    end

    local now = os.time()
    local buf = {}
    for cand in input:iter() do
        buf[#buf + 1] = cand
        if #buf >= env.scan then break end
    end

    -- 找出窗口内用过的、或与上一个词有个人词对的候选；词对命中的优先，其余按最近时间，取前 max_boost 个
    local prev = env.pp and env.pp.prev(now) or nil
    local picked = {}
    for i, cand in ipairs(buf) do
        if ELIGIBLE[cand.type] then
            local e = env.words[cand.text]
            local pe = prev and env.pp.eff(prev, cand.text, now) or 0
            local recent = e and e.count >= env.min_count and now - e.last <= env.window
            if recent or pe >= env.min_pair then
                picked[#picked + 1] = { pos = i, last = e and e.last or 0, count = e and e.count or 0,
                                        pair = pe >= env.min_pair and pe or 0 }
            end
        end
    end
    local function better(a, b)
        if a.pair ~= b.pair then return a.pair > b.pair end
        if a.last ~= b.last then return a.last > b.last end
        return a.count > b.count
    end
    table.sort(picked, better)
    while #picked > env.max_boost do table.remove(picked) end

    -- 已经排在目标位置之前的不动；其余的依次插入到 idx、idx+1……
    local move, skip = {}, {}
    for _, p in ipairs(picked) do
        if p.pos > env.idx + #move then
            move[#move + 1] = p
            skip[p.pos] = true
        else
            skip[p.pos] = nil
        end
    end

    if #move == 0 then
        for _, cand in ipairs(buf) do yield(cand) end
    else
        table.sort(move, better)
        local rest = {}
        for i, cand in ipairs(buf) do
            if not skip[i] then rest[#rest + 1] = cand end
        end
        local out = {}
        local insert_at = math.min(env.idx, #rest + 1)
        for i = 1, insert_at - 1 do out[#out + 1] = rest[i] end
        for _, p in ipairs(move) do out[#out + 1] = buf[p.pos] end
        for i = insert_at, #rest do out[#out + 1] = rest[i] end
        for _, cand in ipairs(out) do yield(cand) end
    end

    -- 后面的候选原样输出（迭代器会从上次中断处继续）
    for cand in input:iter() do yield(cand) end
end

return M
