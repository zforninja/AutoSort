--[[
    AutoSort — rule-driven inventory sorting for Windower 4.

    Commands (//autosort or //as):
        preview [bag]   show what a sort would do, without moving anything
        sort [bag]      preview, then ask for confirmation before moving
        go [bag]        sort with no confirmation
        stop            abort a running sort
        status          slot usage for every accessible bag
        rules           list the loaded rules
        setup           create a starter rule file for this character
        reload          re-read the rule file
        gear            re-scan GearSwap files for protected gear
        defaults        show or change the built-in default rules
        explain <item>  say what a sort would do with an item, and why
        check           report how your items are being categorized

    Rules live in  data/<CharacterName>.lua  — see rules.lua for the format.
]]

_addon.name = 'AutoSort'
_addon.author = 'zforninja'
_addon.version = '2.2.0'
_addon.commands = { 'autosort', 'as' }

local bags      = require('lib/bags')
local items     = require('lib/items')
local inventory = require('lib/inventory')
local rules     = require('lib/rules')
local baseline  = require('lib/baseline')
local planner   = require('lib/planner')
local executor  = require('lib/executor')
local server    = require('lib/server')
local api       = require('lib/api')

local INFO, WARN, GOOD = 207, 123, 204

local state = {
    config = nil,       -- loaded rule set for the current character
    plan = nil,         -- last preview
    plan_bag = nil,     -- source filter used for that preview
    awaiting = false,   -- waiting on a yes/no confirmation
    char = nil,
    port = 9898,
}

local function say(msg, color)
    windower.add_to_chat(color or INFO, '[AutoSort] ' .. msg)
end

local function char_name()
    local p = windower.ffxi.get_player()
    return p and p.name or nil
end

local function logged_in()
    local info = windower.ffxi.get_info()
    return info and info.logged_in
end

-- ---------------------------------------------------------------------------
-- GearSwap protection
-- ---------------------------------------------------------------------------

-- Scan the player's GearSwap files for item names and pin those items so a
-- sort never pulls gear out from under a set. This is a text scan: it reads
-- every quoted string in the character's GearSwap lua files and keeps the ones
-- that match a real item name.
local function scan_gearswap(char)
    local ids = {}
    if not char then return ids end

    local dir = windower.windower_path .. 'addons/GearSwap/data/'
    local candidates = {
        dir .. char .. '.lua',
    }
    -- Job-specific files live under data/<Character>/<Char>_<JOB>.lua on many
    -- setups; add the per-character folder if it exists.
    local sub = dir .. char .. '/'
    if windower.dir_exists and windower.dir_exists(sub) then
        local ok, files = pcall(windower.get_dir, sub)
        if ok and type(files) == 'table' then
            for _, f in ipairs(files) do
                if f:sub(-4) == '.lua' then candidates[#candidates + 1] = sub .. f end
            end
        end
    end

    -- Build a name -> id index once.
    local by_name = {}
    local res = require('resources')
    for id, r in pairs(res.items or {}) do
        local n = r.en or r.english or r.name
        if type(n) == 'string' then by_name[n:lower()] = id end
    end

    local found = 0
    for _, path in ipairs(candidates) do
        if windower.file_exists(path) then
            local fh = io.open(path, 'r')
            if fh then
                local text = fh:read('*a')
                fh:close()
                for quoted in text:gmatch('["\']([^"\']+)["\']') do
                    local id = by_name[quoted:lower()]
                    if id and not ids[id] then
                        ids[id] = true
                        found = found + 1
                    end
                end
            end
        end
    end
    return ids, found
end

-- ---------------------------------------------------------------------------
-- Config loading
-- ---------------------------------------------------------------------------

local function load_config(quiet)
    state.char = char_name()
    state.config = rules.load(state.char)

    if state.config.options.protect_gear then
        local ids, found = scan_gearswap(state.char)
        state.config.gear_ids = ids
        if not quiet and found and found > 0 then
            say(('Protecting %d item(s) referenced by GearSwap.'):format(found))
        end
    else
        state.config.gear_ids = {}
    end

    for _, p in ipairs(state.config.problems) do
        say('Rule problem: ' .. p, WARN)
    end

    if not quiet then
        if not state.config.exists then
            say('No rule file yet, so the built-in defaults apply. Try "//as preview".')
            say('Add your own rules any time with "//as open" or "//as setup".')
        else
            say(('Loaded %d rule(s) for %s.'):format(#state.config.rules, tostring(state.char)))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Web UI
-- ---------------------------------------------------------------------------

-- The api module reaches shared add-on state through these hooks rather than
-- importing the add-on, which would be circular.
api.host = {
    get_config = function()
        if not state.config then load_config(true) end
        return state.config
    end,
    reload = function() load_config(true) end,
    char_name = char_name,
    set_plan = function(plan, bag) state.plan, state.plan_bag = plan, bag end,
    get_plan_bag = function() return state.plan_bag end,
}

local function start_server()
    local ok, err = server.start(state.port, api)
    if ok then
        say('Web UI ready. Type "//as open" to launch it.')
    else
        say(('Could not start the Web UI on port %d: %s'):format(state.port, tostring(err)), WARN)
        say('Try another port: "//as port 9899" then "//as start".', WARN)
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

local function show_plan(plan, verbose)
    if #plan.moves == 0 then
        say('Nothing to move.', GOOD)
    else
        say('Plan: ' .. planner.summary(plan), GOOD)
        local shown = verbose and #plan.moves or math.min(#plan.moves, 15)
        for i = 1, shown do
            local m = plan.moves[i]
            local tag = m.source == 'user' and ' [' .. tostring(m.rule_label) .. ']' or ''
            say(('  %s x%d: %s -> %s%s'):format(m.name, m.count, m.from_name, m.to_name, tag))
        end
        if shown < #plan.moves then
            say(('  ...and %d more. Use "//as preview all" to see everything.')
                :format(#plan.moves - shown))
        end
    end

    for _, b in ipairs(plan.blocked) do
        say(('BLOCKED %s: %s'):format(b.item.name, b.reason), WARN)
    end

    if #plan.skipped > 0 then
        local by_reason = {}
        for _, sk in ipairs(plan.skipped) do
            by_reason[sk.reason] = (by_reason[sk.reason] or 0) + 1
        end
        local parts = {}
        for reason, n in pairs(by_reason) do parts[#parts + 1] = ('%d %s'):format(n, reason) end
        table.sort(parts)
        say('Left alone: ' .. table.concat(parts, '; ') .. '.')
    end
    if plan.unmatched_count > 0 then
        say(('%d item(s) matched no rule and stay put.'):format(plan.unmatched_count))
    end
    if plan.inventory then
        say(('Inventory: %d free now, %d after the sort (target %d).')
            :format(plan.inventory.free_before, plan.inventory.free_after, plan.inventory.target))
    end
    for _, w in ipairs(plan.warnings) do say(w, WARN) end
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

local function can_act()
    if not logged_in() then
        say('Not logged in.', WARN)
        return false
    end
    if executor.state.running then
        say('A sort is already running. Use "//as stop" to abort it.', WARN)
        return false
    end
    if not state.config then load_config(true) end
    local d = state.config.options.defaults
    if #state.config.rules == 0 and not (d and d.enabled) then
        say('Nothing to do: you have no rules and the built-in defaults are off.', WARN)
        say('Turn them on with "//as defaults on".', WARN)
        return false
    end
    return true
end

local function do_preview(bag_key, verbose)
    if not can_act() then return nil end
    if bag_key and not bags.get_by_key(bag_key) then
        say('Unknown bag: ' .. bag_key, WARN)
        return nil
    end
    local plan = planner.build(state.config, bag_key)
    state.plan = plan
    state.plan_bag = bag_key
    show_plan(plan, verbose)
    return plan
end

local function do_execute(plan)
    executor.on_finish = function(p)
        say(('Done: %d moved, %d failed.'):format(p.completed, p.failed),
            p.failed > 0 and WARN or GOOD)
        state.plan = nil
    end
    executor.on_log = function(line)
        -- Only surface failures live; successes are summarized at the end.
        if line:find('^FAILED') then say(line, WARN) end
    end
    if executor.start(plan, state.config.options) then
        say(('Sorting: %d move(s). "//as stop" to abort.'):format(#plan.moves))
    else
        say('Nothing to do.')
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- A new user has no rule file, and nothing is wrong with that: the built-in
-- defaults work on their own. Say so once, so it is clear the addon is ready.
local function first_run_hint()
    if state.config and not state.config.exists then
        say('Ready. No rule file yet, so the built-in defaults apply.')
        say('Try "//as preview" to see what a sort would do, or "//as open" for the Web UI.')
    end
end

windower.register_event('load', function()
    say(('v%s loaded. Type "//as" for commands.'):format(_addon.version))
    if logged_in() then load_config(true); first_run_hint() end
    start_server()
end)

windower.register_event('login', function()
    load_config(true)
    first_run_hint()
end)

windower.register_event('logout', function()
    executor.stop('logged out')
    state.config, state.plan = nil, nil
end)

windower.register_event('zone change', function()
    if executor.state.running then
        executor.stop('zoned')
    end
    state.plan = nil
end)

windower.register_event('prerender', function()
    server.tick()
    if executor.state.running then
        executor.tick()
    end
end)

windower.register_event('unload', function()
    executor.stop('add-on unloaded')
    server.stop()
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local commands = {}

function commands.preview(arg)
    local verbose = (arg == 'all')
    do_preview(verbose and nil or arg, verbose)
end

function commands.sort(arg)
    local plan = do_preview(arg)
    if not plan or #plan.moves == 0 then return end
    state.awaiting = true
    say('Type "//as yes" to run this, or "//as no" to cancel.', GOOD)
end

function commands.yes()
    if not state.awaiting or not state.plan then
        say('Nothing waiting for confirmation.', WARN)
        return
    end
    state.awaiting = false
    -- Rebuild against live state: inventory may have changed since the preview.
    local fresh = planner.build(state.config, state.plan_bag)
    if #fresh.moves == 0 then
        say('Nothing left to move.', GOOD)
        return
    end
    if #fresh.moves ~= #state.plan.moves then
        say(('Inventory changed: now %d move(s).'):format(#fresh.moves), WARN)
    end
    do_execute(fresh)
end

function commands.no()
    state.awaiting = false
    state.plan = nil
    say('Cancelled.')
end

function commands.go(arg)
    if not can_act() then return end
    local plan = planner.build(state.config, arg)
    if #plan.moves == 0 then
        say('Nothing to move.', GOOD)
        for _, b in ipairs(plan.blocked) do
            say(('BLOCKED %s: %s'):format(b.item.name, b.reason), WARN)
        end
        return
    end
    do_execute(plan)
end

function commands.stop(arg)
    if arg == 'server' then
        server.stop()
        say('Web UI stopped.')
        return
    end
    if executor.state.running then
        executor.stop('cancelled')
        say('Sort stopped.')
    else
        say('No sort is running.')
    end
end

function commands.status()
    if not logged_in() then say('Not logged in.', WARN) return end
    say('Accessible bags:')
    for _, bag in ipairs(inventory.snapshot()) do
        say(('  %-18s %3d/%-3d  (%d free)'):format(
            bag.name, bag.used, bag.max, bag.free))
    end
end

function commands.rules()
    if not state.config then load_config(true) end
    if #state.config.rules == 0 then
        say('You have no rules of your own; the built-in defaults apply. See "//as defaults".')
        return
    end
    say(('Your rules for %s (first match wins, checked before the defaults):'):format(tostring(state.char)))
    for i, r in ipairs(state.config.rules) do
        local what = r.match or ('category ' .. tostring(r.category))
        if r.match and r.category then
            what = ('%s + %s'):format(r.match, r.category)
        end
        say(('  %2d. %-30s -> %s'):format(i, what, r.to))
    end
    local o = state.config.options
    say(('Options: delay %.1fs, keep %d inventory slot(s) free, gear protection %s')
        :format(o.delay, o.keep_free, o.protect_gear and 'on' or 'off'))
end

function commands.setup()
    local char = char_name()
    if not char then say('Log in first.', WARN) return end
    local ok, result = rules.write_starter(char)
    if ok then
        say('Created ' .. result)
        say('Edit it, then run "//as reload".')
    else
        say(result, WARN)
    end
end

function commands.reload()
    load_config(false)
    state.plan = nil
end

function commands.gear()
    if not state.char then state.char = char_name() end
    local ids, found = scan_gearswap(state.char)
    state.config = state.config or rules.load(state.char)
    state.config.gear_ids = ids
    say(('Found %d gear item(s) referenced by GearSwap.'):format(found or 0))
end

function commands.open()
    if not server.running then
        say('The Web UI is not running. Start it with "//as start".', WARN)
        return
    end
    windower.open_url(server.url())
    say('Opening the Web UI in your browser.')
end

function commands.url()
    if not server.running then
        say('The Web UI is not running.', WARN)
        return
    end
    say('Web UI: ' .. server.url())
    say('That address includes a one-time session key; it changes each restart.')
end

function commands.start()
    start_server()
end

function commands.port(arg)
    local p = tonumber(arg)
    if not p or p < 1024 or p > 65535 then
        say('Usage: //as port <1024-65535>', WARN)
        return
    end
    state.port = p
    say(('Port set to %d. Restarting the Web UI.'):format(p))
    start_server()
end

--- Persist the current rules and options, then reload them.
local function persist()
    local char = char_name()
    if not char then say('Log in first.', WARN) return false end
    local ok, result = rules.save(char, {
        rules = state.config.rules, options = state.config.options,
    })
    if not ok then say(tostring(result), WARN) return false end
    load_config(true)
    state.plan = nil
    return true
end

function commands.defaults(arg, rest)
    if not state.config then load_config(true) end
    local d = state.config.options.defaults

    -- Changing a setting: "defaults <group|all> on|off", "defaults on|off",
    -- or "defaults free <n|auto>".
    if arg == 'on' or arg == 'off' then
        d.enabled = (arg == 'on')
        if persist() then say('Built-in defaults ' .. (d.enabled and 'ON' or 'OFF') .. '.', GOOD) end
        return
    end
    if arg == 'free' then
        local v = rest[1]
        if v == 'auto' then d.inventory_free = 'auto'
        elseif tonumber(v) then d.inventory_free = math.max(0, math.floor(tonumber(v)))
        else say('Usage: //as defaults free <number|auto>', WARN) return end
        if persist() then say('Inventory free-slot target: ' .. tostring(d.inventory_free), GOOD) end
        return
    end
    if arg and baseline.by_id[arg] then
        local want = rest[1]
        if want ~= 'on' and want ~= 'off' then
            say(('Usage: //as defaults %s on|off'):format(arg), WARN)
            return
        end
        d[arg] = (want == 'on')
        if persist() then say(('Default group "%s" %s.'):format(arg, want:upper()), GOOD) end
        return
    end
    if arg == 'all' and (rest[1] == 'on' or rest[1] == 'off') then
        for _, g in ipairs(baseline.groups) do d[g.id] = (rest[1] == 'on') end
        if persist() then say('All default groups ' .. rest[1]:upper() .. '.', GOOD) end
        return
    end

    -- Otherwise just show them.
    say('Built-in defaults are ' .. (d.enabled and 'ON' or 'OFF') ..
        '. Your own rules always take priority.', d.enabled and GOOD or WARN)
    local free = d.inventory_free
    say(('Inventory free-slot target: %s'):format(
        type(free) == 'number' and tostring(free) or 'auto (a quarter of Inventory)'))
    local groups = baseline.describe(d, function(key)
        local b = bags.get_by_key(key)
        return b and inventory.available(b.id)
    end)
    for _, g in ipairs(groups) do
        local chain = {}
        for _, link in ipairs(g.chain) do
            chain[#chain + 1] = link.available and link.key or ('(' .. link.key .. ')')
        end
        say(('  %-11s %-3s %s%s'):format(g.id, g.enabled and 'on' or 'off', g.label,
            g.soft and ' [only if Inventory is crowded]' or ''))
        if #chain > 0 then say('              -> ' .. table.concat(chain, ' > ')) end
    end
    say('Bags in (parentheses) are unavailable right now and are skipped.')
    say('Change: //as defaults <group|all> on|off  |  //as defaults on|off  |  //as defaults free <n|auto>')
end

function commands.explain(arg, rest)
    if not arg then say('Usage: //as explain <item name>', WARN) return end
    if not logged_in() then say('Not logged in.', WARN) return end
    if not state.config then load_config(true) end
    local name = arg
    for _, w in ipairs(rest or {}) do name = name .. ' ' .. w end

    local r = planner.explain(state.config, name)
    if not r then
        say(('No item matching "%s" in any accessible bag.'):format(name), WARN)
        return
    end
    say(('%s (%s, %s)'):format(r.item.name, r.bag, r.item.slot_name or r.item.category), GOOD)
    if r.rule then say('  rule:    ' .. tostring(r.rule.label)) end
    if r.chain and r.chain ~= '' then say('  options: ' .. r.chain) end
    say('  result:  ' .. r.verdict)
end

function commands.check()
    if not logged_in() then say('Not logged in.', WARN) return end
    if not state.config then load_config(true) end
    local counts, total, unknown = {}, 0, 0
    local rule_list = rules.effective(state.config)
    local by_group = {}
    for _, bag in ipairs(inventory.snapshot()) do
        for _, it in ipairs(bag.items) do
            total = total + 1
            counts[it.category] = (counts[it.category] or 0) + 1
            if it.name:find('^Unknown') then unknown = unknown + 1 end
            local rule = rules.match(it, rule_list)
            local g = rule and (rule.group or rule.label) or 'no rule'
            by_group[g] = (by_group[g] or 0) + 1
        end
    end
    say(('Read %d item(s) across your accessible bags.'):format(total))
    local cats = {}
    for c, n in pairs(counts) do cats[#cats + 1] = ('%s %d'):format(c, n) end
    table.sort(cats)
    say('By category: ' .. table.concat(cats, ', '))
    local groups = {}
    for g, n in pairs(by_group) do groups[#groups + 1] = ('%s %d'):format(g, n) end
    table.sort(groups)
    say('By rule:     ' .. table.concat(groups, ', '))
    if unknown > 0 then
        say(('%d item(s) had no resource data and read as Unknown.'):format(unknown), WARN)
    end
    if (counts['General'] or 0) > total * 0.85 and total > 20 then
        say('Almost everything reads as General. Item categories may not be')
        say('detected on this Windower build; tell the developer the output above.', WARN)
    end
end

function commands.help()
    say('Commands:')
    say('  preview [bag|all]  show planned moves without moving anything')
    say('  sort [bag]         preview, then confirm with "//as yes"')
    say('  go [bag]           sort immediately, no confirmation')
    say('  stop               abort a running sort')
    say('  status             slot usage per bag')
    say('  rules              list loaded rules')
    say('  setup              create a starter rule file')
    say('  reload             re-read the rule file')
    say('  gear               re-scan GearSwap for protected gear')
    say('  defaults           show or change the built-in default rules')
    say('  explain <item>     what would a sort do with this item, and why')
    say('  check              how your items are being categorized')
    say('  open               open the Web UI in your browser')
    say('  url                print the Web UI address')
    say('  start              restart the Web UI server')
    say('  port <n>           change the Web UI port')
end

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local words = {}
    for _, w in ipairs({ ... }) do words[#words + 1] = tostring(w):lower() end
    local arg = words[1]
    local rest = {}
    for i = 2, #words do rest[#rest + 1] = words[i] end

    local fn = commands[cmd]
    if fn then
        local ok, err = pcall(fn, arg, rest)
        if not ok then
            say('Error: ' .. tostring(err), WARN)
        end
    else
        say('Unknown command: ' .. cmd, WARN)
        commands.help()
    end
end)
