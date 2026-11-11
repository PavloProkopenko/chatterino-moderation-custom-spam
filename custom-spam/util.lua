-- Small helpers shared by all modules.
local M = {}

function M.now_ms()
    return c2.DateTime.current_utc():to_unix_milliseconds()
end

function M.norm_channel(name)
    name = tostring(name or ""):lower()
    name = name:gsub("^#", "")
    return name
end

function M.norm_user(name)
    name = tostring(name or ""):lower()
    name = name:gsub("^@", "")
    return name
end

-- Unicode-aware lowercase (Lua's string.lower only handles ASCII).
local function lower_cp(cp)
    if cp >= 0x41 and cp <= 0x5A then return cp + 32 end
    if cp >= 0x410 and cp <= 0x42F then return cp + 32 end
    if cp >= 0x400 and cp <= 0x40F then return cp + 80 end
    if cp >= 0x490 and cp <= 0x4BF and cp % 2 == 0 then return cp + 1 end
    return cp
end

function M.lower(str)
    local ok, res = pcall(function()
        local out = {}
        for _, cp in utf8.codes(str) do
            out[#out + 1] = utf8.char(lower_cp(cp))
        end
        return table.concat(out)
    end)
    if ok then
        return res
    end
    return str:lower()
end

-- Twitch/Chatterino append this invisible char to bypass duplicate-message checks.
M.INVISIBLE_CHAR = "\u{E0000}"

-- Message text without the invisible suffix and outer whitespace.
function M.clean_text(text)
    text = tostring(text or ""):gsub(M.INVISIBLE_CHAR, "")
    return (text:match("^%s*(.-)%s*$"))
end

function M.first_token(text)
    return text:match("^(%S+)")
end

function M.split_tokens(text)
    local out = {}
    for tok in text:gmatch("%S+") do
        out[#out + 1] = tok
    end
    return out
end

function M.fmt_seconds(s)
    if s == math.floor(s) then
        return string.format("%d", s)
    end
    local out = string.format("%.2f", s):gsub("0+$", ""):gsub("%.$", "")
    return out
end

return M
