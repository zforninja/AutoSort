--[[
    AutoSort — Automatic FFXI inventory sorting for Windower 4.

    Sorts items across every storage container using user-defined rules,
    driven by a local Web UI. Because FFXI forbids moving an item directly
    between two non-Inventory bags, all transfers are routed through Inventory
    as an intermediate.

    Commands:
        //autosort open     Open the Web UI in your default browser.
        //autosort reload   Reload settings from data/settings.json.
        //autosort stop     Stop the HTTP server.
        //autosort start    (Re)start the HTTP server.
        //autosort url      Print the Web UI URL to chat.

    Author: zforninja
]]

_addon.name     = 'AutoSort'
_addon.author   = 'zforninja'
_addon.version  = '1.0.0'
_addon.commands = { 'autosort', 'asort' }

local config    = require('lib/config')
local server    = require('lib/server')
local sorter    = require('lib/sorter')
local inventory = require('lib/inventory')
local bags      = require('lib/bags')

-- ---------------------------------------------------------------------------
-- Add-on state
-- ---------------------------------------------------------------------------

local state = {
    settings = nil,     -- current settings table
    last_plan = nil,    -- most recently generated preview plan
}

-- Chat colours for windower.add_to_chat.
local COLOR_INFO = 207
local COLOR_WARN = 123

local function notify(msg)
    windower.add_to_chat(COLOR_INFO, '[AutoSort] ' .. msg)
end

local function warn(msg)
    windower.add_to_chat(COLOR_WARN, '[AutoSort] ' .. msg)
end

local function ui_url()
    return ('http://127.0.0.1:%d/'):format(state.settings and state.settings.port or 9898)
end

-- ---------------------------------------------------------------------------
-- API handlers (called from the HTTP server on the game thread)
-- ---------------------------------------------------------------------------

local api = {}

-- GET /api/status — inventory snapshot for enabled bags + full bag catalog.
function api.status()
    local snapshot = inventory.snapshot(state.settings.enabled_bags)
    -- Catalog describes every bag (id/key/name/note) so the UI can render the
    -- Bag Settings tab and show live slot counts even for disabled bags.
    local catalog = {}
    for _, b in ipairs(bags.list) do
        local used, max = 0, b.max_slots
        -- Only probe live counts for bags the game can currently read.
        local ok, data = pcall(inventory.read_bag, b.id)
        if ok then
            used, max = data.used, data.max
        end
        catalog[#catalog + 1] = {
            id = b.id, key = b.key, name = b.name, note = b.note,
            enabled = state.settings.enabled_bags[b.key] and true or false,
            used = used, max = max,
        }
    end
    return { ok = true, bags = snapshot, catalog = catalog }
end

-- GET /api/settings
function api.get_settings()
    return {
        ok = true,
        settings = state.settings,
        -- Provide the bag catalog + category list to populate dropdowns.
        catalog = (function()
            local c = {}
            for _, b in ipairs(bags.list) do
                c[#c + 1] = { key = b.key, name = b.name, id = b.id, note = b.note }
            end
            return c
        end)(),
        categories = { 'Weapon', 'Armor', 'Ranged', 'Ammo', 'Food', 'Usable', 'Crystal', 'Currency', 'General' },
    }
end

-- POST /api/settings — persist enabled_bags + rules (+ optional port/delay).
function api.save_settings(data)
    -- Merge incoming fields onto the current settings.
    if type(data.enabled_bags) == 'table' then
        state.settings.enabled_bags = data.enabled_bags
    end
    if type(data.rules) == 'table' then
        state.settings.rules = data.rules
    end
    if tonumber(data.move_delay) then
        state.settings.move_delay = tonumber(data.move_delay)
    end
    if tonumber(data.port) then
        state.settings.port = tonumber(data.port)
    end
    -- mule_bag may be a string (bag key) or explicit null to clear it.
    if data.mule_bag ~= nil then
        state.settings.mule_bag = (data.mule_bag == '' ) and nil or data.mule_bag
    elseif data.clear_mule_bag then
        state.settings.mule_bag = nil
    end
    if type(data.icon_base_url) == 'string' then
        state.settings.icon_base_url = data.icon_base_url
    end
    if data.show_icons ~= nil then
        state.settings.show_icons = data.show_icons and true or false
    end

    local ok, err = config.save(state.settings)
    -- Reload the sanitized version back into memory.
    state.settings = config.load()
    if ok then
        return { ok = true, settings = state.settings }
    end
    return { ok = false, error = tostring(err) }
end

-- POST /api/preview — build and cache a move plan.
function api.preview()
    local plan = sorter.build_plan(state.settings)
    state.last_plan = plan
    return { ok = true, plan = plan }
end

-- POST /api/execute — begin executing the cached plan.
function api.execute()
    if not state.last_plan then
        -- Build fresh if none cached.
        state.last_plan = sorter.build_plan(state.settings)
    end
    if sorter.exec.running then
        return { ok = false, error = 'A sort is already running.' }
    end
    sorter.start(state.last_plan, state.settings.move_delay)
    notify(('Executing sort: %d moves queued.'):format(#state.last_plan.moves))
    return { ok = true, total = #state.last_plan.moves }
end

-- GET /api/progress — current execution progress.
function api.progress()
    local p = sorter.progress()
    p.ok = true
    return p
end

-- POST /api/stop — abort execution.
function api.stop_sort()
    sorter.stop()
    return { ok = true }
end

-- ---------------------------------------------------------------------------
-- Server lifecycle
-- ---------------------------------------------------------------------------

local function start_server()
    local ok, err = server.start(state.settings.port, api)
    if ok then
        notify(('Web UI available at %s'):format(ui_url()))
        notify('Type "//autosort open" to launch it in your browser.')
    else
        warn(('Could not start server on port %d: %s'):format(state.settings.port, tostring(err)))
        warn('Change the port with "//autosort port <number>" then "//autosort start".')
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

windower.register_event('load', function()
    state.settings = config.load()
    notify(('AutoSort v%s loaded.'):format(_addon.version))
    start_server()
end)

windower.register_event('unload', function()
    server.stop()
    sorter.stop()
end)

-- Poll the HTTP server and advance any running sort once per frame.
windower.register_event('prerender', function()
    server.tick()
    if sorter.exec.running then
        sorter.tick()
    end
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'open'):lower()
    local args = { ... }

    if cmd == 'open' then
        windower.open_url(ui_url())
        notify('Opening Web UI: ' .. ui_url())

    elseif cmd == 'url' then
        notify('Web UI: ' .. ui_url())

    elseif cmd == 'reload' then
        state.settings = config.load()
        notify('Settings reloaded.')

    elseif cmd == 'stop' then
        server.stop()
        sorter.stop()
        notify('Server stopped.')

    elseif cmd == 'start' then
        server.stop()
        start_server()

    elseif cmd == 'port' then
        local p = tonumber(args[1])
        if p then
            state.settings.port = p
            config.save(state.settings)
            notify('Port set to ' .. p .. '. Restart with "//autosort start".')
        else
            warn('Usage: //autosort port <number>')
        end

    elseif cmd == 'sort' then
        -- Convenience: preview + execute from chat.
        api.preview()
        api.execute()

    else
        notify('Commands: open | url | start | stop | reload | port <n> | sort')
    end
end)
