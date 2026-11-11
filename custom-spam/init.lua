-- Custom Spam plugin for Chatterino / Leafyrino (moderators only).
-- Configure with /custom-spam help. Config lives in data/config.json.
local E = require("engine")
local commands = require("commands")

E.load()
E.start_poll()

local ok = c2.register_command("/custom-spam", commands.handle)
if not ok then
    c2.log(c2.LogLevel.Warning, "custom-spam: /custom-spam is already registered by something else")
end

c2.log(c2.LogLevel.Info, "custom-spam loaded; use /custom-spam help")
