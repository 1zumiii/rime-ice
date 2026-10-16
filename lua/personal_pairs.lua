-- personal_pairs.lua — 个人词对记录：前一个词 → 当前词 的使用次数（带时间衰减）
-- 由 recent_boost_filter 在每次上屏时记录，由 recent_boost_filter 和 ai_rerank_filter 查询。
-- 记录保存在用户目录的 recent_pairs.tsv（每行：时间戳<Tab>前一个词<Tab>当前词），明文，不属于仓库，不联网。
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
    if not f then return end
    local now = os.time()
    local keep = {}
    for line in f:lines() do
        local ts, a, b = line:match("^(%d+)\t([^\t]+)\t([^\t]+)$")
        ts = tonumber(ts)
        if ts and now - ts <= WINDOW then keep[#keep + 1] = { ts, a, b } end
    end
    f:close()
    local first = math.max(1, #keep - MAX_RECORDS + 1)
    for i = first, #keep do bump(keep[i][2], keep[i][3], keep[i][1]) end
    if #keep > MAX_RECORDS then
        local tmp = path .. ".tmp"
        local out = io.open(tmp, "w")
        if out then
            for i = first, #keep do out:write(string.format("%d\t%s\t%s\n", keep[i][1], keep[i][2], keep[i][3])) end
            out:close()
            os.rename(tmp, path)
        end
    end
end

-- 上屏一个词时调用：若上一个词仍有效，记一条词对；然后把当前词作为新的「前一个词」
function M.record(text, ts)
    ts = ts or os.time()
    local pv = M.prev(ts)
    if pv and usable(pv) and usable(text) then
        bump(pv, text, ts)
        local f = io.open(path, "a")
        if f then
            f:write(string.format("%d\t%s\t%s\n", ts, pv, text))
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
end

return M
