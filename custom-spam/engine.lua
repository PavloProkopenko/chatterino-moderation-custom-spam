-- Runtime: config state, channel hooks, moderator gate, trigger handling, send runs.
local util = require("util")
local config = require("config")

local E = {}

local POLL_MS = 5000
local FIRST_DELAY_MS = 50
local INVISIBLE = " " .. util.INVISIBLE_CHAR -- Twitch dup-message bypass

E.cfg = config.defaults()
E.notice_channel = nil -- where to print async notices

local handles = {} -- channel name -> { channel=, conn= }
local runs = {} -- channel name -> { token, key, trigger, text, total, sent }
local last_fire = {} -- "chan|key" -> ms of the last accepted trigger
local last_sent_text = {} -- channel -> text
local dup_flip = {} -- channel -> bool
local run_seq = 0
local warned = {} -- channel -> true, "not a mod" notice already shown

-- ---------- notices ----------
function E.notify(text, channel)
    local ch = channel or E.notice_channel
    if ch then
        local ok = pcall(function()
            if ch:is_valid() then
                ch:add_system_message("[custom-spam] " .. text)
            else
                error("invalid")
            end
        end)
        if ok then
            return
        end
    end
    c2.log(c2.LogLevel.Info, "custom-spam: " .. text)
end

function E.save()
    return config.save(E.cfg)
end

-- ---------- moderator gate ----------
-- Returns true, or false + reason. Plugin works only on Twitch channels where
-- the logged-in user is the broadcaster or a moderator.
function E.gate(ch)
    local acct = c2.current_account()
    if not acct or not acct:is_valid() or acct:is_anon() then
        return false, "no logged-in Twitch account."
    end
    local ok, res = pcall(function()
        if not ch or not ch:is_valid() or not ch:is_twitch_channel() then
            return false
        end
        return ch:is_mod() or ch:is_broadcaster()
    end)
    if not ok or not res then
        return false, "you are not a moderator or the broadcaster in this channel."
    end
    return true
end

-- ---------- entries ----------
function E.find_entry(channel, key)
    for i, e in ipairs(E.cfg.entries) do
        if e.channel == channel and e.key == key then
            return e, i
        end
    end
end

function E.effective_cooldown(e)
    return e.cooldown or E.cfg.cooldown
end

-- Returns entry, replaced(bool) or nil, error.
function E.add_entry(channel, trigger, text, cooldown)
    if type(trigger) ~= "string" or trigger == "" then
        return nil, "a trigger is required"
    end
    if trigger:find("%s") then
        return nil, "the trigger must be a single word (no spaces)"
    end
    if #trigger > 50 then
        return nil, "the trigger is longer than 50 characters"
    end
    local tfirst = trigger:sub(1, 1)
    if tfirst == "/" or tfirst == "." then
        return nil, "the trigger must not start with '/' or '.' (would run as a command)"
    end
    if type(text) ~= "string" or not text:match("%S") then
        return nil, "a message is required"
    end
    if #text > 500 then
        return nil, "the message is longer than 500 characters"
    end
    local first = text:sub(1, 1)
    if first == "/" or first == "." then
        return nil, "the message must not start with '/' or '.' (would run as a command)"
    end
    local key = util.lower(trigger)
    -- A message whose first word is a trigger would re-trigger itself.
    local text_key = util.lower(util.first_token(text) or "")
    if text_key == key then
        return nil, "the message must not start with its own trigger"
    end
    for _, e in ipairs(E.cfg.entries) do
        if e.channel == channel then
            if e.key ~= key and util.lower(util.first_token(e.text) or "") == key then
                return nil, string.format("trigger %s is the first word of the message of %s", trigger, e.trigger)
            end
            if e.key ~= key and e.key == text_key then
                return nil, string.format("the message starts with the existing trigger %s", e.trigger)
            end
        end
    end
    local entry, idx = E.find_entry(channel, key)
    local replaced = entry ~= nil
    local new = { channel = channel, trigger = trigger, key = key, text = text, cooldown = cooldown }
    if replaced then
        E.cfg.entries[idx] = new
    else
        E.cfg.entries[#E.cfg.entries + 1] = new
    end
    E.save()
    E.sync_hooks()
    return new, replaced
end

function E.remove_entry(channel, key)
    local e, idx = E.find_entry(channel, key)
    if not e then
        return false
    end
    table.remove(E.cfg.entries, idx)
    local run = runs[channel]
    if run and run.key == key then
        runs[channel] = nil
    end
    E.save()
    E.sync_hooks()
    return true
end

-- ---------- runs ----------
function E.stop(channel)
    if runs[channel] then
        runs[channel] = nil
        return true
    end
    return false
end

function E.stop_all()
    local n = 0
    for name in pairs(runs) do
        runs[name] = nil
        n = n + 1
    end
    return n
end

function E.run_info(channel)
    return runs[channel]
end

function E.active_runs()
    local n = 0
    for _ in pairs(runs) do
        n = n + 1
    end
    return n
end

local function next_text(channel, text)
    if last_sent_text[channel] == text then
        dup_flip[channel] = not dup_flip[channel]
    else
        dup_flip[channel] = false
    end
    last_sent_text[channel] = text
    if dup_flip[channel] then
        return text .. INVISIBLE
    end
    return text
end

local function step(name, token)
    local run = runs[name]
    if not run or run.token ~= token then
        return -- stopped, replaced or plugin reloaded
    end
    local ch = c2.Channel.by_name(name)
    if not ch or not ch:is_valid() then
        runs[name] = nil
        return
    end
    -- the user may have lost moderator rights meanwhile
    local ok, why = E.gate(ch)
    if not ok then
        runs[name] = nil
        E.notify(string.format("stopped after %d of %d: %s", run.sent, run.total, why), ch)
        return
    end
    ch:send_message(next_text(name, run.text), false) -- false: never run as a command
    run.sent = run.sent + 1
    if run.sent >= run.total then
        runs[name] = nil
        return
    end
    local delay = math.max(1, math.floor(E.cfg.gap * 1000))
    c2.later(function()
        local okc, err = pcall(step, name, token)
        if not okc then
            runs[name] = nil
            c2.log(c2.LogLevel.Warning, "custom-spam: send step failed: " .. tostring(err))
        end
    end, delay)
end

local function start_run(name, ch, entry, count)
    run_seq = run_seq + 1
    local token = run_seq
    runs[name] = {
        token = token, key = entry.key, trigger = entry.trigger,
        text = entry.text, total = count, sent = 0,
    }
    c2.later(function()
        local okc, err = pcall(step, name, token)
        if not okc then
            runs[name] = nil
            c2.log(c2.LogLevel.Warning, "custom-spam: send step failed: " .. tostring(err))
        end
    end, FIRST_DELAY_MS)
end

-- ---------- config (re)load ----------
function E.load()
    local cfg, warn = config.load()
    E.cfg = cfg
    E.stop_all()
    if warn then
        E.notify(warn)
    end
    E.sync_hooks()
end

-- ---------- channel hooks ----------
function E.sync_hooks()
    local wanted = {}
    for _, e in ipairs(E.cfg.entries) do
        wanted[e.channel] = true
    end
    for name, h in pairs(handles) do
        if not wanted[name] then
            pcall(function() h.conn:disconnect() end)
            handles[name] = nil
        end
    end
    for name in pairs(wanted) do
        local h = handles[name]
        local healthy = false
        if h then
            local ok, res = pcall(function()
                return h.channel:is_valid() and h.conn:is_connected()
            end)
            healthy = ok and res
            if not healthy then
                pcall(function() h.conn:disconnect() end)
                handles[name] = nil
            end
        end
        if not healthy then
            local ch = c2.Channel.by_name(name)
            if ch and ch:is_valid() then
                local conn = ch:on_message_appended(function(msg)
                    E.on_message(name, ch, msg)
                end)
                handles[name] = { channel = ch, conn = conn }
            end
        end
    end
end

function E.hooked(name)
    return handles[name] ~= nil
end

-- Re-hook channels that were opened/closed after startup.
function E.start_poll()
    local function tick()
        pcall(E.sync_hooks)
        c2.later(tick, POLL_MS)
    end
    c2.later(tick, POLL_MS)
end

-- ---------- incoming ----------
local SKIP = nil
local function skip_flags()
    local mask = 0
    for _, n in ipairs({ "System", "RecentMessage", "Debug", "Timeout", "Untimeout", "Disabled" }) do
        mask = mask | (c2.MessageFlag[n] or 0)
    end
    return mask
end

-- Parses "<trigger> [count]" (first token already known to be a trigger).
-- Returns count (number), or nil when the message is not in the trigger syntax.
function E.parse_count(tokens)
    if #tokens == 1 then
        return E.cfg.default_count
    end
    if #tokens == 2 and tokens[2]:match("^%d+$") and #tokens[2] <= 6 then
        local n = tonumber(tokens[2])
        if n >= 1 then
            return n
        end
    end
    return nil
end

function E.on_message(chan_name, ch, msg)
    if #E.cfg.entries == 0 then
        return
    end
    SKIP = SKIP or skip_flags()
    if ((msg.flags or 0) & SKIP) ~= 0 then
        return
    end
    local text = util.clean_text(msg.message_text)
    if text == "" then
        return
    end
    local tokens = util.split_tokens(text)
    local key = util.lower(tokens[1])
    local entry = E.find_entry(chan_name, key)
    if not entry then
        return
    end

    -- Only the plugin owner (logged-in account) may trigger; everyone else is ignored.
    local acct = c2.current_account()
    if not acct or not acct:is_valid() or acct:is_anon() then
        return
    end
    local sender = util.norm_user(msg.login_name)
    local mine = sender ~= "" and sender == util.norm_user(acct:login())
    if not mine and msg.user_id and msg.user_id ~= "" and msg.user_id == acct:id() then
        mine = true
    end
    if not mine then
        return
    end

    local ok, why = E.gate(ch)
    if not ok then
        if not warned[chan_name] then
            warned[chan_name] = true
            E.notify("not triggered: " .. why, ch)
        end
        return
    end
    warned[chan_name] = nil

    local count = E.parse_count(tokens)
    if not count then
        return
    end
    if runs[chan_name] then
        E.notify(string.format("%s ignored: a run (%s, %d/%d) is already in progress. /custom-spam stop cancels it.",
            entry.trigger, runs[chan_name].trigger, runs[chan_name].sent, runs[chan_name].total), ch)
        return
    end
    local now = util.now_ms()
    local fkey = chan_name .. "|" .. key
    local cd = E.effective_cooldown(entry)
    local last = last_fire[fkey]
    if last and cd > 0 and now - last < cd * 1000 then
        E.notify(string.format("%s is on cooldown, %s s left.", entry.trigger,
            util.fmt_seconds(math.ceil((cd * 1000 - (now - last)) / 100) / 10)), ch)
        return
    end
    if count > E.cfg.max_count then
        E.notify(string.format("count %d is above the limit, sending %d (/custom-spam set max <n>).",
            count, E.cfg.max_count), ch)
        count = E.cfg.max_count
    end
    last_fire[fkey] = now
    start_run(chan_name, ch, entry, count)
end

return E
