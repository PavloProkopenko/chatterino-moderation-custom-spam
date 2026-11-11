-- /custom-spam subcommands.
local util = require("util")
local config = require("config")
local E = require("engine")

local M = {}

-- Help is layered: index -> topic -> "all". Each topic's lines keep the
-- convention "explanation line, then syntax line".
local TOPICS = {
    {
        key = "trigger", aliases = { "run", "start", "stop" },
        summary = "как запустить и остановить спам",
        lines = {
            "Запуск: напишите в чате сохранённый триггер и число повторов, например !тг 10. Плагин отправит сохранённое сообщение 10 раз. Без числа отправит один раз (это число можно поменять: set default). Регистр не важен. Пока спам идёт, новые запуски в этом канале игнорируются.",
            "<триггер> [количество]",
            "Остановить текущий спам: stop отменяет отправку в этом канале, stop all — во всех каналах. Если вы потеряете права модератора, отправка прекратится сама.",
            "/custom-spam stop [all]",
            "Запустить спам можете только вы (аккаунт, под которым открыт чат), и только в Twitch-каналах, где вы модератор или стример. Сообщения других людей, в том числе других модераторов, ничего не запускают. В остальных каналах все команды /custom-spam, включая help, отключены.",
        },
    },
    {
        key = "add", aliases = { "cooldown" },
        summary = "добавить/изменить команду (триггер + сообщение) и её паузу",
        lines = {
            'Добавить команду: триггер (одно слово, например !тг) и сообщение, которое будет отправляться. Если такой триггер уже есть в канале, он будет перезаписан. Триггер и сообщение берите в кавычки. Команда привязана к текущему каналу; чтобы добавить в другой, укажите --channel <канал> (канал должен быть открыт в окне, и вы там модератор). Сообщение не длиннее 500 символов, не может начинаться с / или . и не может начинаться со слова-триггера. Плейсхолдеров (вроде {user}) нет: сообщение отправляется как написано.',
            '/custom-spam add "<триггер>" "<сообщение>" [--cooldown <секунды>] [--channel <канал>]',
            "Пауза для одного триггера: после запуска этот же триггер нельзя запустить снова N секунд (защита от случайного двойного запуска). Без своей паузы действует общая (set cooldown, по умолчанию 30). 0 = без паузы, default = вернуть общую.",
            '/custom-spam cooldown "<триггер>" <секунды|default> [--channel <канал>]',
        },
    },
    {
        key = "list", aliases = { "remove" },
        summary = "список команд и удаление",
        lines = {
            "Показать сохранённые команды текущего канала (all — всех каналов) вместе с паузой каждой.",
            "/custom-spam list [all]",
            "Удалить команду по триггеру.",
            '/custom-spam remove "<триггер>" [--channel <канал>]',
        },
    },
    {
        key = "set", aliases = {},
        summary = "общие настройки: лимит, интервал, пауза, число по умолчанию",
        lines = {
            "Общие настройки. max = самое большое число повторов за один запуск (по умолчанию 50, больше будет обрезано). gap = интервал между сообщениями в секундах (по умолчанию 0.5, минимум 0.1; у модераторов нет паузы между сообщениями, но слишком маленький интервал может привести к потере сообщений на стороне приложения). cooldown = общая пауза между запусками одного триггера в секундах (по умолчанию 30, 0 = выключить). default = сколько раз отправлять, если число не указано (по умолчанию 1).",
            "/custom-spam set max|gap|cooldown|default <число>",
        },
    },
    {
        key = "status", aliases = { "reload" },
        summary = "состояние плагина и перечитывание data/config.json",
        lines = {
            "Показать настройки, ваш статус в этом канале и идущую отправку.",
            "/custom-spam status",
            "Перечитать настройки из файла data/config.json (если вы правили его вручную). Идущая отправка при этом отменяется.",
            "/custom-spam reload",
        },
    },
}

local TOPIC_BY_NAME = {}
for _, t in ipairs(TOPICS) do
    TOPIC_BY_NAME[t.key] = t
    for _, a in ipairs(t.aliases) do
        TOPIC_BY_NAME[a] = t
    end
end

local function say(ctx, text)
    ctx.channel:add_system_message("[custom-spam] " .. text)
end

local function help_index(ctx)
    local out = ctx.channel
    out:add_system_message("=== Custom Spam: справка ===")
    for _, t in ipairs(TOPICS) do
        out:add_system_message(string.format("/custom-spam help %s — %s", t.key, t.summary))
    end
    out:add_system_message("/custom-spam help all — вся справка целиком")
end

local function help(ctx, arg)
    local out = ctx.channel
    arg = arg and arg:lower() or nil
    if arg == nil then
        help_index(ctx)
    elseif arg == "all" or arg == "full" then
        out:add_system_message("=== Custom Spam: полная справка ===")
        for _, t in ipairs(TOPICS) do
            out:add_system_message("-- " .. t.key .. " --")
            for _, line in ipairs(t.lines) do
                out:add_system_message(line)
            end
        end
    elseif TOPIC_BY_NAME[arg] then
        local t = TOPIC_BY_NAME[arg]
        out:add_system_message("=== Справка: " .. t.key .. " ===")
        for _, line in ipairs(t.lines) do
            out:add_system_message(line)
        end
    else
        out:add_system_message("Нет такого раздела: " .. arg)
        help_index(ctx)
    end
end

-- ---------- argument parsing ----------
-- Removes "--name value" from s. Returns value (or nil), remaining string.
local function pull_flag(s, name)
    local val
    local out = s:gsub("%s*%-%-" .. name .. "%s+(%S+)", function(v)
        val = val or v
        return ""
    end)
    return val, out
end

-- Parses: <quoted or single token> <rest>. Returns token, rest.
local function take_arg(s)
    s = s:gsub("^%s+", "")
    if s:sub(1, 1) == '"' then
        local tok, rest = s:match('^"(.-)"%s*(.*)$')
        if tok then
            return tok, rest
        end
        return nil, s
    end
    local tok, rest = s:match("^(%S+)%s*(.*)$")
    return tok, rest
end

-- Message text: a quoted string (inner quotes allowed) followed only by
-- flags, or the whole unquoted rest. Returns text, flags-string or nil, error.
local function take_text(rest)
    rest = rest:gsub("^%s+", "")
    if rest:sub(1, 1) == '"' then
        local tok, tail = rest:match('^"(.*)"(%s+%-%-.*)$')
        if tok then
            return tok, tail
        end
        tok = rest:match('^"(.*)"%s*$')
        if tok then
            return tok, ""
        end
        return nil, "missing closing quote"
    end
    return rest, nil
end

local function parse_seconds(str, min, max)
    local n = tonumber(str)
    if not n or n ~= n or n < min or n > max then
        return nil
    end
    return n
end

-- Resolves --channel; returns name, channel object, or nil + message.
local function target_channel(ctx, flag)
    local cur = util.norm_channel(ctx.channel:get_name())
    if not flag then
        return cur, ctx.channel
    end
    local name = util.norm_channel(flag)
    if name == "" then
        return nil, "empty channel name"
    end
    if name == cur then
        return cur, ctx.channel
    end
    local ch = c2.Channel.by_name(name)
    if not ch or not ch:is_valid() then
        return nil, "channel " .. name .. " is not open in a split; open it first."
    end
    local ok, why = E.gate(ch)
    if not ok then
        return nil, name .. ": " .. why
    end
    return name, ch
end

-- ---------- subcommands ----------
local function cmd_add(ctx, words)
    local usage = 'usage: /custom-spam add "<trigger>" "<message>" [--cooldown <s>] [--channel <name>]'
    if not words[3] then
        say(ctx, usage)
        return
    end
    local trigger, rest = take_arg(table.concat(words, " ", 3))
    if not trigger or rest == "" then
        say(ctx, usage)
        return
    end
    local text, tail = take_text(rest)
    if not text then
        say(ctx, "cannot parse: " .. tail .. ". " .. usage)
        return
    end
    local flags
    if tail then
        flags = tail
    else
        -- unquoted text: flags may follow it
        local cd_raw, chan_raw
        cd_raw, text = pull_flag(text, "cooldown")
        chan_raw, text = pull_flag(text, "channel")
        flags = (cd_raw and (" --cooldown " .. cd_raw) or "") .. (chan_raw and (" --channel " .. chan_raw) or "")
    end
    local cd_raw, chan_raw
    cd_raw, flags = pull_flag(flags, "cooldown")
    chan_raw, flags = pull_flag(flags, "channel")
    if flags:match("%S") then
        say(ctx, "unexpected text after the message: " .. flags:match("^%s*(.-)%s*$") .. ". " .. usage)
        return
    end
    local cooldown
    if cd_raw then
        cooldown = parse_seconds(cd_raw, config.LIMITS.cooldown[1], config.LIMITS.cooldown[2])
        if not cooldown then
            say(ctx, "invalid cooldown '" .. cd_raw .. "' (0 to 86400 seconds).")
            return
        end
    end
    local name, ch = target_channel(ctx, chan_raw)
    if not name then
        say(ctx, ch)
        return
    end
    local entry, replaced = E.add_entry(name, trigger, text, cooldown)
    if not entry then
        say(ctx, "cannot add: " .. replaced)
        return
    end
    say(ctx, string.format("%s %s in %s (cooldown %s s) -> %s", replaced and "updated" or "added",
        entry.trigger, name, util.fmt_seconds(E.effective_cooldown(entry)), entry.text))
    if not E.hooked(name) then
        say(ctx, "note: " .. name .. " is not open in a split yet; it will hook automatically once opened.")
    end
end

local function cmd_remove(ctx, words)
    local usage = 'usage: /custom-spam remove "<trigger>" [--channel <name>]'
    if not words[3] then
        say(ctx, usage)
        return
    end
    local chan_raw, rest = pull_flag(table.concat(words, " ", 3), "channel")
    local trigger = take_arg(rest)
    if not trigger then
        say(ctx, usage)
        return
    end
    local name, ch = target_channel(ctx, chan_raw)
    if not name then
        say(ctx, ch)
        return
    end
    if E.remove_entry(name, util.lower(trigger)) then
        say(ctx, string.format("removed %s from %s.", trigger, name))
    else
        say(ctx, string.format("no trigger %s in %s.", trigger, name))
    end
end

local function cmd_cooldown(ctx, words)
    local usage = 'usage: /custom-spam cooldown "<trigger>" <seconds|default> [--channel <name>]'
    if not words[3] then
        say(ctx, usage)
        return
    end
    local chan_raw, rest = pull_flag(table.concat(words, " ", 3), "channel")
    local trigger, value = take_arg(rest)
    value = value and value:match("^(%S+)$")
    if not trigger or not value then
        say(ctx, usage)
        return
    end
    local name, ch = target_channel(ctx, chan_raw)
    if not name then
        say(ctx, ch)
        return
    end
    local entry = E.find_entry(name, util.lower(trigger))
    if not entry then
        say(ctx, string.format("no trigger %s in %s.", trigger, name))
        return
    end
    if value:lower() == "default" then
        entry.cooldown = nil
    else
        local n = parse_seconds(value, config.LIMITS.cooldown[1], config.LIMITS.cooldown[2])
        if not n then
            say(ctx, "invalid cooldown '" .. value .. "' (0 to 86400 seconds, or default).")
            return
        end
        entry.cooldown = n
    end
    E.save()
    say(ctx, string.format("cooldown of %s: %s s%s.", entry.trigger, util.fmt_seconds(E.effective_cooldown(entry)),
        entry.cooldown and "" or " (default)"))
end

local function cmd_list(ctx, words)
    local cur = util.norm_channel(ctx.channel:get_name())
    local all = words[3] and words[3]:lower() == "all"
    local n = 0
    for _, e in ipairs(E.cfg.entries) do
        if all or e.channel == cur then
            n = n + 1
            say(ctx, string.format("%s%s [cooldown %s s%s] -> %s", e.trigger, all and (" @" .. e.channel) or "",
                util.fmt_seconds(E.effective_cooldown(e)), e.cooldown and "" or ", default", e.text))
        end
    end
    if n == 0 then
        say(ctx, all and "no commands yet." or "no commands in this channel. Add one with /custom-spam add ...")
    end
end

local function cmd_stop(ctx, words)
    if words[3] and words[3]:lower() == "all" then
        local n = E.stop_all()
        say(ctx, n > 0 and string.format("stopped %d run(s).", n) or "nothing is running.")
        return
    end
    local cur = util.norm_channel(ctx.channel:get_name())
    local run = E.run_info(cur)
    if E.stop(cur) then
        say(ctx, string.format("stopped %s after %d of %d.", run.trigger, run.sent, run.total))
    else
        say(ctx, "nothing is running in this channel.")
    end
end

local SET_KEYS = {
    max = "max_count", gap = "gap", cooldown = "cooldown", default = "default_count",
}

local function cmd_set(ctx, words)
    local usage = "usage: /custom-spam set max|gap|cooldown|default <number>"
    local field = SET_KEYS[(words[3] or ""):lower()]
    if not field or not words[4] then
        say(ctx, usage)
        return
    end
    local lim = config.LIMITS[field]
    local n = parse_seconds(words[4], lim[1], lim[2])
    if not n then
        say(ctx, string.format("invalid value '%s' (allowed: %s to %s).", words[4],
            util.fmt_seconds(lim[1]), util.fmt_seconds(lim[2])))
        return
    end
    if field ~= "gap" and field ~= "cooldown" then
        n = math.floor(n)
    end
    E.cfg[field] = n
    E.save()
    say(ctx, string.format("%s = %s.", words[3]:lower(), util.fmt_seconds(n)))
end

local function status(ctx)
    local cfg = E.cfg
    local cur = util.norm_channel(ctx.channel:get_name())
    local acct = c2.current_account()
    local role = ctx.channel:is_broadcaster() and "broadcaster" or "moderator"
    say(ctx, string.format("account: %s, role in %s: %s.", acct:login(), cur, role))
    say(ctx, string.format("max %d, gap %s s, cooldown %s s, default count %d, commands: %d.",
        cfg.max_count, util.fmt_seconds(cfg.gap), util.fmt_seconds(cfg.cooldown), cfg.default_count, #cfg.entries))
    local run = E.run_info(cur)
    if run then
        say(ctx, string.format("running here: %s, %d of %d sent.", run.trigger, run.sent, run.total))
    end
end

function M.handle(ctx)
    E.notice_channel = ctx.channel
    -- Moderators/broadcaster only: nothing works for anyone else.
    local ok, why = E.gate(ctx.channel)
    if not ok then
        say(ctx, "unavailable: " .. why .. " The plugin works only for moderators.")
        return
    end
    local words = ctx.words
    local sub = words[2] and words[2]:lower() or "help"
    if sub == "add" then
        cmd_add(ctx, words)
    elseif sub == "remove" or sub == "delete" then
        cmd_remove(ctx, words)
    elseif sub == "cooldown" then
        cmd_cooldown(ctx, words)
    elseif sub == "list" then
        cmd_list(ctx, words)
    elseif sub == "stop" then
        cmd_stop(ctx, words)
    elseif sub == "set" then
        cmd_set(ctx, words)
    elseif sub == "status" then
        status(ctx)
    elseif sub == "reload" then
        E.load()
        say(ctx, "config reloaded from disk.")
        status(ctx)
    elseif sub == "help" then
        help(ctx, words[3])
    else
        help(ctx)
    end
end

return M
