--[[
    rules.lua — Rule matching and per-character rule files.

    Rules live in  data/<CharacterName>.lua  and are plain Lua, so they can be
    hand-edited with comments. A file returns:

        return {
            options = {
                delay        = 0.8,    -- seconds between moves
                keep_free    = 0,      -- inventory slots to leave empty
                protect      = { 'Warp Ring', 'Vile Elixir' },
                protect_gear = true,   -- never move anything GearSwap uses
            },
            rules = {
                { match = '*Crystal',  to = 'sack'      },
                { category = 'Armor',  to = 'wardrobe2' },
                { category = 'Usable', to = 'satchel'   },
                { match = 'Gil',       to = 'keep'      },
            },
        }

    Rule fields:
        match     item name, '*' wildcard, case-insensitive. Optional.
        category  broad category or equipment slot name, or 'ALL'. Optional.
        to        destination bag key, or 'keep' to pin the item where it is.

    A rule matches when every field it specifies matches. Rules are evaluated
    top to bottom and the first match wins, so put specific rules above broad
    ones.
]]

local bags = require('lib/bags')
local items = require('lib/items')
local baseline = require('lib/baseline')

local rules = {}

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

-- Convert a '*' wildcard pattern into a Lua pattern, escaping magic chars.
local function to_pattern(glob)
    local escaped = glob:gsub('([%^%$%(%)%%%.%[%]%+%-%?])', '%%%1')
    return '^' .. escaped:gsub('%*', '.*') .. '$'
end

local pattern_cache = {}

--- Case-insensitive wildcard match.
function rules.name_matches(name, glob)
    if not name or not glob or glob == '' then return false end
    name, glob = name:lower(), glob:lower()
    if not glob:find('*', 1, true) then
        return name == glob
    end
    local pat = pattern_cache[glob]
    if not pat then
        pat = to_pattern(glob)
        pattern_cache[glob] = pat
    end
    return name:find(pat) ~= nil
end

-- Does the item satisfy this rule's category field? The field may name a
-- broad category (Armor) or an equipment slot (Head); both are checked.
local function category_matches(item, want)
    if not want or want == '' then return true end
    want = want:lower()
    if want == 'all' then return true end
    if want == 'equipment' then return item.equippable and true or false end
    if item.category and item.category:lower() == want then return true end
    if item.slot_name and item.slot_name:lower() == want then return true end
    return false
end

--- First matching rule for an item, or nil.
-- A rule with neither `match` nor `category` matches everything, which makes
-- a trailing catch-all rule possible.
function rules.match(item, rule_list)
    for _, rule in ipairs(rule_list or {}) do
        local name_ok = (not rule.match or rule.match == '')
            or rules.name_matches(item.name, rule.match)
        if name_ok and category_matches(item, rule.category) then
            return rule
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

--- Check a rule list. Returns cleaned rules plus an array of problem strings.
-- Invalid rules are dropped rather than silently misbehaving.
function rules.validate(rule_list)
    local clean, problems = {}, {}
    if type(rule_list) ~= 'table' then
        return clean, { 'rules is not a list' }
    end

    for i, r in ipairs(rule_list) do
        local label = ('rule %d'):format(i)
        if type(r) ~= 'table' then
            problems[#problems + 1] = label .. ': not a table'
        elseif type(r.to) ~= 'string' or r.to == '' then
            problems[#problems + 1] = label .. ': missing "to"'
        else
            local dest = r.to:lower()
            local ok = true
            if dest ~= 'keep' and not bags.get_by_key(dest) then
                problems[#problems + 1] = ('%s: unknown bag "%s"'):format(label, r.to)
                ok = false
            end
            if r.category and not items.is_valid_category(r.category) then
                problems[#problems + 1] =
                    ('%s: unknown category "%s"'):format(label, tostring(r.category))
                ok = false
            end
            if ok then
                clean[#clean + 1] = {
                    match = r.match and tostring(r.match) or nil,
                    category = r.category and tostring(r.category) or nil,
                    to = dest,
                }
            end
        end
    end
    return clean, problems
end

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

local DEFAULT_OPTIONS = {
    delay = 0.8,
    keep_free = 0,
    protect = {},
    protect_gear = true,
}

-- Fresh options table each time, so nothing shares the defaults block.
local function new_options()
    local o = {}
    for k, v in pairs(DEFAULT_OPTIONS) do o[k] = v end
    o.defaults = baseline.default_settings()
    return o
end

--- Path to the current character's rule file.
function rules.path(char_name)
    return windower.addon_path .. 'data/' .. (char_name or 'default') .. '.lua'
end

--- Load rules for a character.
-- Returns { rules = {...}, options = {...}, problems = {...}, path, exists }.
-- A missing file is not an error: it yields an empty rule set.
function rules.load(char_name)
    local path = rules.path(char_name)
    local out = {
        rules = {}, options = {}, problems = {}, path = path, exists = false,
    }

    out.options = new_options()

    if not windower.file_exists(path) then
        return out
    end
    out.exists = true

    -- dofile can throw on a syntax error; never let that unload the add-on.
    local ok, data = pcall(dofile, path)
    if not ok then
        out.problems[#out.problems + 1] = 'could not read rule file: ' .. tostring(data)
        return out
    end
    if type(data) ~= 'table' then
        out.problems[#out.problems + 1] = 'rule file did not return a table'
        return out
    end

    local clean, problems = rules.validate(data.rules)
    out.rules = clean
    for _, p in ipairs(problems) do out.problems[#out.problems + 1] = p end

    if type(data.options) == 'table' then
        local o = data.options
        if tonumber(o.delay) then
            out.options.delay = math.max(0.3, tonumber(o.delay))
        end
        if tonumber(o.keep_free) then
            out.options.keep_free = math.max(0, math.floor(tonumber(o.keep_free)))
        end
        if o.protect_gear ~= nil then
            out.options.protect_gear = o.protect_gear and true or false
        end
        if type(o.protect) == 'table' then
            local list = {}
            for _, name in ipairs(o.protect) do list[#list + 1] = tostring(name) end
            out.options.protect = list
        end
    end

    -- `defaults` is a sibling of `options` in the file, which is where save()
    -- writes it. Also accept it nested inside `options` for hand-written files.
    local raw_defaults = data.defaults
    if raw_defaults == nil and type(data.options) == 'table' then
        raw_defaults = data.options.defaults
    end
    out.options.defaults = baseline.sanitize(raw_defaults)

    return out
end

--- The full rule list the planner evaluates: your rules first, then defaults.
-- First match wins, so anything you write overrides the built-in behaviour.
function rules.effective(config)
    local out = {}
    for i, r in ipairs(config.rules or {}) do
        out[#out + 1] = {
            match = r.match,
            category = r.category,
            to = r.to,
            targets = { r.to },
            keep = (r.to == 'keep'),
            source = 'user',
            index = i,
            label = ('your rule #%d'):format(i),
        }
    end
    local d = config.options and config.options.defaults
    for _, r in ipairs(baseline.rules(d)) do out[#out + 1] = r end
    return out
end

--- Is this item pinned by the protect list?
function rules.protected(item, protect_list)
    for _, glob in ipairs(protect_list or {}) do
        if rules.name_matches(item.name, glob) then return true end
    end
    return false
end

--- Write a starter rule file for a character. Never overwrites.
function rules.write_starter(char_name)
    local path = rules.path(char_name)
    if windower.file_exists(path) then
        return false, 'file already exists: ' .. path
    end
    local dir = windower.addon_path .. 'data'
    if not windower.dir_exists(dir) then
        windower.create_dir(dir)
    end
    local fh = io.open(path, 'w')
    if not fh then return false, 'could not create ' .. path end
    fh:write([[
-- AutoSort rules for ]] .. (char_name or 'this character') .. [[

--
-- You do not need to write anything here. AutoSort has built-in defaults that
-- sort by what you own and which bags you can reach. Add rules below ONLY to
-- override them: yours are checked first, and the first match wins.
--
-- Rule fields:
--   match     item name, * wildcard, case-insensitive
--   category  Equipment Weapon Armor General Usable Crystal Currency Furniture
--             or a slot: Main Sub Ranged Ammo Head Body Hands Legs Feet
--                        Neck Waist Ear Ring Back
--   to        inventory safe storage locker satchel sack case
--             wardrobe wardrobe2 ... wardrobe8 safe2
--             or 'keep' to leave the item exactly where it is
--
-- Run "//as reload" after editing, then "//as preview" to check the result.

return {
    options = {
        delay        = 0.8,   -- seconds between moves
        keep_free    = 2,     -- inventory slots never filled by a sort
        protect_gear = true,  -- keep gear your GearSwap files reference equippable
        protect      = {},    -- never move these, e.g. { 'Warp Ring' }
    },

    -- Turn defaults off entirely with enabled = false, or switch off single
    -- groups. inventory_free is how many Inventory slots the defaults try to
    -- keep open; "auto" means a quarter of your Inventory.
    defaults = {
        enabled        = true,
        inventory_free = "auto",
        essentials     = true,
        currency       = true,
        crystals       = true,
        furniture      = true,
        gear           = true,
        consumables    = true,
        misc           = true,
    },

    -- Your overrides. Examples (remove the leading -- to use one):
    rules = {
        -- { match = '*Ninja Tool*', to = 'sack'      },
        -- { category = 'Weapon',    to = 'wardrobe'  },
        -- { match = 'Hi-Potion',    to = 'keep'      },
    },
}
]])
    fh:close()
    return true, path
end

--- Escape a Lua string literal.
local function quote(s)
    return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', ' ') .. '"'
end

--- Write a rule set back to the character's rule file.
-- `data` is { rules = {...}, options = {...} }. Rules are validated first, so
-- a bad payload from the UI cannot produce a file that fails to load.
-- The previous file is kept as <name>.lua.bak.
function rules.save(char_name, data)
    local path = rules.path(char_name)
    local clean, problems = rules.validate(data.rules)

    local o = new_options()
    if type(data.options) == 'table' then
        if tonumber(data.options.delay) then
            o.delay = math.max(0.3, tonumber(data.options.delay))
        end
        if tonumber(data.options.keep_free) then
            o.keep_free = math.max(0, math.floor(tonumber(data.options.keep_free)))
        end
        if data.options.protect_gear ~= nil then
            o.protect_gear = data.options.protect_gear and true or false
        end
        if type(data.options.protect) == 'table' then
            local list = {}
            for _, n in ipairs(data.options.protect) do
                if tostring(n) ~= '' then list[#list + 1] = tostring(n) end
            end
            o.protect = list
        end
        o.defaults = baseline.sanitize(data.options.defaults)
    end

    local dir = windower.addon_path .. 'data'
    if not windower.dir_exists(dir) then windower.create_dir(dir) end

    -- Back up whatever is there before overwriting.
    if windower.file_exists(path) then
        local src = io.open(path, 'r')
        if src then
            local old = src:read('*a')
            src:close()
            local bak = io.open(path .. '.bak', 'w')
            if bak then bak:write(old); bak:close() end
        end
    end

    local out = {}
    out[#out + 1] = '-- AutoSort rules for ' .. tostring(char_name)
    out[#out + 1] = '-- Written by the AutoSort Web UI. Safe to hand-edit.'
    out[#out + 1] = '-- First matching rule wins.'
    out[#out + 1] = ''
    out[#out + 1] = 'return {'
    out[#out + 1] = '    options = {'
    out[#out + 1] = ('        delay        = %.2f,'):format(o.delay)
    out[#out + 1] = ('        keep_free    = %d,'):format(o.keep_free)
    out[#out + 1] = ('        protect_gear = %s,'):format(tostring(o.protect_gear))
    if #o.protect > 0 then
        out[#out + 1] = '        protect      = {'
        for _, n in ipairs(o.protect) do
            out[#out + 1] = ('            %s,'):format(quote(n))
        end
        out[#out + 1] = '        },'
    else
        out[#out + 1] = '        protect      = {},'
    end
    out[#out + 1] = '    },'
    out[#out + 1] = ''
    out[#out + 1] = '    -- Built-in defaults. Your rules below are checked first and override these.'
    out[#out + 1] = '    defaults = {'
    out[#out + 1] = ('        enabled        = %s,'):format(tostring(o.defaults.enabled))
    local free = o.defaults.inventory_free
    out[#out + 1] = ('        inventory_free = %s,'):format(
        type(free) == 'number' and tostring(free) or '"auto"')
    for _, g in ipairs(baseline.groups) do
        out[#out + 1] = ('        %-14s = %s,'):format(g.id, tostring(o.defaults[g.id]))
    end
    out[#out + 1] = '    },'
    out[#out + 1] = ''
    out[#out + 1] = '    rules = {'
    for _, r in ipairs(clean) do
        local parts = {}
        if r.match then parts[#parts + 1] = 'match = ' .. quote(r.match) end
        if r.category then parts[#parts + 1] = 'category = ' .. quote(r.category) end
        parts[#parts + 1] = 'to = ' .. quote(r.to)
        out[#out + 1] = ('        { %s },'):format(table.concat(parts, ', '))
    end
    out[#out + 1] = '    },'
    out[#out + 1] = '}'
    out[#out + 1] = ''

    local fh = io.open(path, 'w')
    if not fh then return false, 'could not write ' .. path end
    fh:write(table.concat(out, '\n'))
    fh:close()

    return true, path, problems
end

return rules
