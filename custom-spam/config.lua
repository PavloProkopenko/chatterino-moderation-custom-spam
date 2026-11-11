-- Loads/saves data/config.json (the plugin's data dir; relative paths in
-- io.open resolve there).
local json = require("chatterino.json")
local util = require("util")

local M = {}
local FILE = "config.json"

-- name -> {min, max} for the numeric settings
M.LIMITS = {
    max_count = { 1, 500 },
    gap = { 0.1, 60 },
    cooldown = { 0, 86400 },
    default_count = { 1, 500 },
}

function M.defaults()
    return {
        version = 1,
        max_count = 50, -- cap for one run
        gap = 0.5, -- seconds between two spam messages (min 0.1)
        cooldown = 30, -- seconds, per trigger, default (entries may override)
        default_count = 1, -- when the trigger has no number
        -- entries: {channel, trigger, key (lowercased trigger), text, cooldown?}
        entries = {},
    }
end

local function read_all(name)
    local f = io.open(name, "r")
    if not f then
        return nil
    end
    local data = f:read("a")
    f:close()
    return data
end

local function write_all(name, data)
    local f = io.open(name, "w")
    if not f then
        return false
    end
    f:write(data)
    f:close()
    return true
end

-- Returns cfg, warning (string or nil).
function M.load()
    local raw = read_all(FILE)
    if not raw or raw == "" then
        return M.defaults(), nil
    end
    local ok, parsed = pcall(json.parse, raw)
    if not ok or type(parsed) ~= "table" then
        write_all(FILE .. ".bad", raw)
        return M.defaults(),
            "config.json was corrupt; saved a copy as config.json.bad and started fresh."
    end
    local cfg = M.defaults()
    for k, v in pairs(parsed) do
        cfg[k] = v
    end
    for name, lim in pairs(M.LIMITS) do
        local v = cfg[name]
        if type(v) ~= "number" or v < lim[1] or v > lim[2] then
            cfg[name] = M.defaults()[name]
        end
    end
    if type(cfg.entries) ~= "table" then
        cfg.entries = {}
    end
    local good, seen = {}, {}
    for _, e in ipairs(cfg.entries) do
        if type(e) == "table" and type(e.channel) == "string" and type(e.trigger) == "string"
            and type(e.text) == "string" and e.trigger ~= "" and e.text:match("%S") then
            e.channel = util.norm_channel(e.channel)
            e.key = util.lower(e.trigger)
            if type(e.cooldown) ~= "number" or e.cooldown < 0 or e.cooldown > M.LIMITS.cooldown[2] then
                e.cooldown = nil
            end
            local id = e.channel .. "|" .. e.key
            if not seen[id] then
                seen[id] = true
                good[#good + 1] = e
            end
        end
    end
    cfg.entries = good
    return cfg, nil
end

function M.save(cfg)
    local ok, out = pcall(json.stringify, cfg)
    if not ok then
        c2.log(c2.LogLevel.Warning, "custom-spam: could not serialize config: " .. tostring(out))
        return false
    end
    if not write_all(FILE, out) then
        c2.log(c2.LogLevel.Warning, "custom-spam: could not write config.json")
        return false
    end
    return true
end

return M
