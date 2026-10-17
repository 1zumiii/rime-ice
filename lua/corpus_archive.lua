-- corpus_archive.lua — 把挤出活动文件的旧记录追加到归档，而不是丢掉
-- 活动文件（recent_words.tsv、recent_pairs.tsv）只保留最近的若干条，用于“最近使用优先”和个人词对；
-- 被挤出的旧记录追加到同目录的 <名字>.archive.tsv，超过 512 KB 就改名成带时间的分卷并尽力用 gzip 压缩
-- （没有 gzip 或在 Windows 上时保留明文分卷）。归档只在本机，不会同步，也不会进入仓库。
local M = {}

local ROTATE_BYTES = 512 * 1024

local function is_windows() return package.config:sub(1, 1) == "\\" end

-- 追加成功返回 true；失败返回 false（调用方此时不应删除活动文件里的旧记录）
function M.append(path, lines)
    if #lines == 0 then return true end
    local base = path:gsub("%.tsv$", "")
    local ap = base .. ".archive.tsv"
    local f = io.open(ap, "a")
    if not f then return false end
    local ok = f:write(table.concat(lines, "\n"), "\n")
    local size = f:seek("end")
    f:close()
    if not ok then return false end
    if size and size > ROTATE_BYTES then
        local rot = base .. ".archive-" .. os.date("%Y%m%d-%H%M%S") .. ".tsv"
        if os.rename(ap, rot) and not is_windows() then
            local q = rot:gsub("'", "'\\''")
            pcall(os.execute, "gzip -f '" .. q .. "' >/dev/null 2>&1")
        end
    end
    return true
end

return M
