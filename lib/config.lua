--[[
    config.lua — Load and save AutoSort settings.

    Settings are persisted as JSON at <addon_dir>/data/settings.json.

    Settings schema:
    {
        "port": 9898,
        "move_delay": 0.7,          -- seconds between item moves
        "enabled_bags": {            -- keyed by bag key, boolean
            "inventory": true,
            "sack": true,
            ...
        },
        "rules": [                   -- evaluated top-to-bottom, first match wins
            {
                "match_type": "name",     -- "name" | "category"
                "pattern": "*Sword*",      -- name/wildcard OR category string
                "target": "sack"           -- destination bag key
            },
            ...
        ]
    }

    No default rules are shipped (per user requirement); the rules table
    starts empty and every bag except Inventory starts disabled so the user
    explicitly opts in to the containers they actually own.
]]

local json = require('json')
local bags = require('lib/bags')

local config = {}

config.DATA_DIR = 'data'
config.FILE = 'data/settings.json'

--- Build the default settings table.
-- Inventory is always enabled (it is the mandatory intermediate); everything
-- else starts disabled and the user turns on the bags they own.
function config.defaults()
    local enabled = {}
    for _, b in ipairs(bags.list) do
        enabled[b.key] = (b.key == 'inventory')
    end
    return {
        port = 9898,
        move_delay = 0.7,
        enabled_bags = enabled,
        rules = {},
        mule_bag = nil,  -- Optional: designate one bag as your "mule outbox"
        -- Base URL for item icons. Icons are addressed by item id:
        --   <icon_base_url><item_id>.png
        -- FFXIAH hosts every item icon at a predictable id-based path, so no
        -- scraping is needed. Set to "" to disable icons entirely.
        icon_base_url = 'https://static.ffxiah.com/images/icon/',
        show_icons = true,       -- master toggle for item icons in the UI
    }
end

-- Ensure every known bag key exists in enabled_bags and validate types so a
-- hand-edited or partial file cannot crash the add-on.
local function sanitize(settings)
    local defaults = config.defaults()
    settings = type(settings) == 'table' and settings or {}

    settings.port = tonumber(settings.port) or defaults.port
    settings.move_delay = tonumber(settings.move_delay) or defaults.move_delay
    if settings.move_delay < 0.3 then settings.move_delay = 0.3 end

    -- enabled_bags
    local enabled = type(settings.enabled_bags) == 'table' and settings.enabled_bags or {}
    for _, b in ipairs(bags.list) do
        if enabled[b.key] == nil then
            enabled[b.key] = (b.key == 'inventory')
        else
            enabled[b.key] = enabled[b.key] and true or false
        end
    end
    enabled.inventory = true -- inventory can never be disabled
    settings.enabled_bags = enabled

    -- rules
    local clean_rules = {}
    if type(settings.rules) == 'table' then
        for _, r in ipairs(settings.rules) do
            if type(r) == 'table' and r.pattern and r.target then
                clean_rules[#clean_rules + 1] = {
                    match_type = (r.match_type == 'category') and 'category' or 'name',
                    pattern = tostring(r.pattern),
                    target = tostring(r.target),
                }
            end
        end
    end
    settings.rules = clean_rules

    -- mule_bag: must be a valid bag key or nil
    if settings.mule_bag ~= nil then
        local valid_bag = bags.get_by_key(tostring(settings.mule_bag))
        settings.mule_bag = valid_bag and tostring(settings.mule_bag) or nil
    else
        settings.mule_bag = nil
    end

    -- icon settings
    if type(settings.icon_base_url) ~= 'string' then
        settings.icon_base_url = defaults.icon_base_url
    end
    settings.show_icons = (settings.show_icons ~= false)

    return settings
end

--- Load settings from disk, creating defaults if the file is missing/invalid.
function config.load()
    local path = windower.addon_path .. config.FILE
    if not windower.file_exists(path) then
        local defaults = config.defaults()
        config.save(defaults)
        return defaults
    end

    local raw = io.open(path, 'r')
    if not raw then
        return config.defaults()
    end
    local contents = raw:read('*a')
    raw:close()

    local ok, decoded = pcall(json.decode, contents)
    if not ok or type(decoded) ~= 'table' then
        return config.defaults()
    end
    return sanitize(decoded)
end

--- Save settings to disk. Returns true on success.
function config.save(settings)
    settings = sanitize(settings)

    -- Make sure the data directory exists.
    local dir = windower.addon_path .. config.DATA_DIR
    if not windower.dir_exists(dir) then
        windower.create_dir(dir)
    end

    local path = windower.addon_path .. config.FILE
    local ok, encoded = pcall(json.encode, settings)
    if not ok then
        return false, encoded
    end

    local fh = io.open(path, 'w')
    if not fh then
        return false, 'could not open ' .. path
    end
    fh:write(encoded)
    fh:close()
    return true
end

return config
