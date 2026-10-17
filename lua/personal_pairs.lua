-- personal_pairs.lua — 个人词对记录：前一个词 → 当前词 的使用次数（带时间衰减）
-- 由 recent_boost_filter 在每次上屏时记录，由 recent_boost_filter 和 ai_rerank_filter 查询。
-- 记录保存在用户目录的 recent_pairs.tsv（每行：时间戳<Tab>前一个词<Tab>当前词），明文，不属于仓库，不联网。
-- 超出 90 天或 6000 条的旧记录不丢弃，移到 recent_pairs.archive.tsv（见 corpus_archive.lua）。
-- 纠错记忆另存 recent_choices.tsv（时间戳<Tab>前一个词<Tab>拼音<Tab>所选词<Tab>权重），明文、仅本机，规则同上（180 天、4000 条，旧记录归档）。
-- 清空个人词对：删除该文件后重新部署即可。
-- 「前一个词」只在上一次上屏后 GAP 秒内有效；编辑键（退格、方向键等）由 ai_rerank_processor 调 reset() 清掉。

local M = {}

local FILE_NAME = "recent_pairs.tsv"
local TAU = 14 * 86400          -- 衰减时间常数：14 天后权重降到 1/e
local WINDOW = 90 * 86400       -- 超过 90 天的记录在加载时丢弃
local MAX_RECORDS = 6000
local GAP = 20                  -- 秒
local MAX_CHARS = 8             -- 过长的上屏文本（整句）不参与词对

local tbl = {}                  -- tbl[前词][当前词] = { s = 衰减计数, t = 最近时间 }

-- 纠错记忆：在“前一个词 + 输入的拼音”这个具体情境下，用户选了哪个词（选了非首位的权重更大）
local CHOICE_FILE = "recent_choices.tsv"
local CHOICE_TAU = 30 * 86400
local CHOICE_WINDOW = 180 * 86400
local CHOICE_MAX = 4000
local choices = {}                -- choices[前词 .. "\1" .. 拼音][词] = { s, t }
local choice_path = nil
local prev_text, prev_ts = nil, 0
local path = nil
local inited = false

local function record_path()
    local dir = rime_api:get_user_data_dir()
    local sep = "/"
    local name = rime_api:get_distribution_code_name():lower()
    if name:match("weasel") then sep = "\\" end
    return dir .. sep .. FILE_NAME
end

local function bump(prev, word, ts)
    local row = tbl[prev]
    if not row then row = {}; tbl[prev] = row end
    local e = row[word]
    if not e then
        row[word] = { s = 1, t = ts }
    else
        e.s = 1 + e.s * math.exp(math.min(0, (e.t - ts) / TAU))
        if ts > e.t then e.t = ts end
    end
end

local function usable(text)
    if not text or text == "" or text:find("[\t\r\n]") then return false end
    if not text:find("[^\1-\127]") then return false end      -- 只记含中文的词，英文、数字串不记
    return (utf8.len(text) or 99) <= MAX_CHARS
end

function M.init(file_path)
    if inited then return end
    inited = true
    path = file_path or record_path()
    local f = io.open(path, "r")
    choice_path = path:gsub("recent_pairs%.tsv$", CHOICE_FILE)
    M._load_choices()
    if not f then return end
    local now = os.time()
    local keep, old = {}, {}
    for line in f:lines() do
        local ts, a, b = line:match("^(%d+)\t([^\t]+)\t([^\t]+)$")
        ts = tonumber(ts)
        if ts then
            if now - ts <= WINDOW then keep[#keep + 1] = { ts, a, b } else old[#old + 1] = line end
        end
    end
    f:close()
    local first = math.max(1, #keep - MAX_RECORDS + 1)
    for i = first, #keep do bump(keep[i][2], keep[i][3], keep[i][1]) end
    -- 超出 90 天窗口或超出条数上限的旧记录移到归档（recent_pairs.archive.tsv），写成功后才改写活动文件
    if #old > 0 or #keep > MAX_RECORDS then
        for i = 1, first - 1 do old[#old + 1] = string.format("%d\t%s\t%s", keep[i][1], keep[i][2], keep[i][3]) end
        local ok_arc, arc = pcall(require, "corpus_archive")
        if ok_arc and arc.append(path, old) then
            local tmp = path .. ".tmp"
            local out = io.open(tmp, "w")
            if out then
                for i = first, #keep do out:write(string.format("%d\t%s\t%s\n", keep[i][1], keep[i][2], keep[i][3])) end
                out:close()
                os.rename(tmp, path)
            end
        end
    end
end

local function choice_bump(prev, input, word, w, ts)
    local key = prev .. "\1" .. input
    local row = choices[key]
    if not row then row = {}; choices[key] = row end
    local e = row[word]
    if not e then
        row[word] = { s = w, t = ts }
    else
        e.s = w + e.s * math.exp(math.min(0, (e.t - ts) / CHOICE_TAU))
        if ts > e.t then e.t = ts end
    end
end

function M._load_choices()
    if not choice_path then return end
    local f = io.open(choice_path, "r")
    if not f then return end
    local now = os.time()
    local keep, old = {}, {}
    for line in f:lines() do
        local ts, a, inp, word, w = line:match("^(%d+)\t([^\t]+)\t([a-z]+)\t([^\t]+)\t([%d%.]+)$")
        ts, w = tonumber(ts), tonumber(w)
        if ts and w then
            if now - ts <= CHOICE_WINDOW then keep[#keep + 1] = { ts, a, inp, word, w } else old[#old + 1] = line end
        end
    end
    f:close()
    local first = math.max(1, #keep - CHOICE_MAX + 1)
    for i = first, #keep do local r = keep[i]; choice_bump(r[2], r[3], r[4], r[5], r[1]) end
    if #old > 0 or #keep > CHOICE_MAX then
        for i = 1, first - 1 do local r = keep[i]; old[#old + 1] = string.format("%d\t%s\t%s\t%s\t%s", r[1], r[2], r[3], r[4], r[5]) end
        local ok_arc, arc = pcall(require, "corpus_archive")
        if ok_arc and arc.append(choice_path, old) then
            local tmp = choice_path .. ".tmp"
            local out = io.open(tmp, "w")
            if out then
                for i = first, #keep do local r = keep[i]; out:write(string.format("%d\t%s\t%s\t%s\t%s\n", r[1], r[2], r[3], r[4], r[5])) end
                out:close()
                os.rename(tmp, choice_path)
            end
        end
    end
end

-- 记一次选择：在“前一个词 + 输入的拼音”下选了 word；w 为权重（选了非首位的取大，选了首位的取小）
function M.record_choice(prev, input, word, w, ts)
    ts = ts or os.time()
    if not prev or not choice_path or not input:match("^[a-z]+$") or #input < 2 or #input > 24 then return end
    if not (usable(prev) and usable(word)) then return end
    choice_bump(prev, input, word, w, ts)
    local f = io.open(choice_path, "a")
    if f then
        f:write(string.format("%d\t%s\t%s\t%s\t%g\n", ts - ts % 60, prev, input, word, w))
        f:close()
    end
end

-- 衰减后的选择计数；没有记录返回 0
function M.choice_eff(prev, input, word, now)
    local row = prev and choices[prev .. "\1" .. input]
    local e = row and row[word]
    if not e then return 0 end
    return e.s * math.exp(math.min(0, (e.t - (now or os.time())) / CHOICE_TAU))
end

-- 上屏一个词时调用：若上一个词仍有效，记一条词对；然后把当前词作为新的「前一个词」
function M.record(text, ts)
    ts = ts or os.time()
    local pv = M.prev(ts)
    -- 两个都是单字（的、是、了之类）的搭配信息量很低、噪声多，不记
    local single = pv and (utf8.len(pv) or 0) == 1 and (utf8.len(text) or 0) == 1
    if pv and usable(pv) and usable(text) and not single then
        bump(pv, text, ts)
        local f = io.open(path, "a")
        if f then
            f:write(string.format("%d\t%s\t%s\n", ts - ts % 60, pv, text))   -- 落盘的时间戳只到分钟
            f:close()
        end
    end
    prev_text, prev_ts = text, ts
end

function M.prev(now)
    now = now or os.time()
    if prev_text and now - prev_ts <= GAP then return prev_text end
    return nil
end

function M.reset()
    prev_text = nil
end

-- 衰减后的词对计数；没有记录返回 0
function M.eff(prev, word, now)
    local row = prev and tbl[prev]
    local e = row and row[word]
    if not e then return 0 end
    return e.s * math.exp(math.min(0, (e.t - (now or os.time())) / TAU))
end

-- 测试用：清空内存状态
function M._reset_all()
    tbl, prev_text, prev_ts, inited, path = {}, nil, 0, false, nil
    choices, choice_path = {}, nil
end

return M
