--[[
    inventory.lua — Read bag contents and expose them in a UI-friendly shape.

    Wraps the Windower FFXI item APIs:
        windower.ffxi.get_items(bag_id)       -> raw item table for a bag
        windower.ffxi.get_bag_count(bag_id)    -> capacity of a bag (max slots)
        res.items[item_id]                     -> static item resource data

    Item categories are derived from the resource data so sort rules can match
    on broad types (Weapon, Armor, Food, Currency, etc.) as well as names.
]]

local res = require('resources')
local bags = require('lib/bags')

local inventory = {}

-- Map a resource item to a coarse, human-friendly category used by rules.
-- The FFXI item resource exposes `category` ('Weapon', 'Armor', 'General',
-- 'Usable', 'Crystal', ...) and `type`. We normalise these into buckets that
-- make sense for sorting.
local function derive_category(item_res)
    if not item_res then return 'Unknown' end

    local category = item_res.category or 'General'
    local skill = item_res.skill

    if category == 'Weapon' then
        return 'Weapon'
    elseif category == 'Armor' then
        return 'Armor'
    elseif category == 'Ranged Weapon' then
        return 'Ranged'
    elseif category == 'Ammunition' then
        return 'Ammo'
    elseif category == 'Usable' then
        -- Food, potions, scrolls, etc.
        if item_res.type == 4 or (item_res.name and item_res.name:lower():find('food')) then
            return 'Food'
        end
        return 'Usable'
    elseif category == 'Crystal' then
        return 'Crystal'
    elseif category == 'Currency' then
        return 'Currency'
    end

    -- Fall back on flags for a few common types.
    if skill and skill ~= 0 then
        return 'Weapon'
    end
    return category or 'General'
end

--- Return details for a single item resource id.
-- Returns a table { id, name, category, stack } or a placeholder for unknowns.
function inventory.item_info(item_id)
    local r = res.items[item_id]
    if not r then
        return { id = item_id, name = 'Unknown (' .. tostring(item_id) .. ')', category = 'Unknown', stack = 1 }
    end
    return {
        id = item_id,
        name = r.english or r.name or ('Item ' .. tostring(item_id)),
        category = derive_category(r),
        stack = r.stack or 1,
    }
end

--- Read the capacity (max slots) of a bag. Falls back to the definition max.
function inventory.bag_capacity(bag_id)
    local def = bags.get_by_id(bag_id)
    local cap = nil
    if windower.ffxi.get_bag_count then
        -- get_bag_count returns { count, max } on some builds; guard it.
        local ok, result = pcall(windower.ffxi.get_bag_count, bag_id)
        if ok and type(result) == 'number' then
            cap = result
        end
    end
    return cap or (def and def.max_slots) or 80
end

--- Read all items currently in a bag.
-- Returns { items = { {slot, id, count, name, category, stack}, ... },
--           used = N, max = M }.
function inventory.read_bag(bag_id)
    local result = { items = {}, used = 0, max = inventory.bag_capacity(bag_id) }

    local raw = windower.ffxi.get_items(bag_id)
    if type(raw) ~= 'table' then
        return result
    end

    -- The Windower items table for a bag has numeric slot keys plus metadata
    -- fields like `count`, `max`, `enabled`. Use `max` when present.
    if type(raw.max) == 'number' and raw.max > 0 then
        result.max = raw.max
    end

    for slot = 1, (result.max or 80) do
        local entry = raw[slot]
        if type(entry) == 'table' and entry.id and entry.id ~= 0 then
            local info = inventory.item_info(entry.id)
            result.items[#result.items + 1] = {
                slot = slot,
                id = entry.id,
                count = entry.count or 1,
                name = info.name,
                category = info.category,
                stack = info.stack,
            }
            result.used = result.used + 1
        end
    end

    return result
end

--- Build a full status snapshot for every enabled bag.
-- `enabled_bags` is a table keyed by bag key -> boolean.
-- Returns an ordered array of bag snapshots.
function inventory.snapshot(enabled_bags)
    enabled_bags = enabled_bags or {}
    local out = {}
    for _, b in ipairs(bags.list) do
        if enabled_bags[b.key] then
            local data = inventory.read_bag(b.id)
            out[#out + 1] = {
                id = b.id,
                key = b.key,
                name = b.name,
                used = data.used,
                max = data.max,
                items = data.items,
            }
        end
    end
    return out
end

--- Find the first free slot in a bag, or nil if full.
function inventory.first_free_slot(bag_id)
    local raw = windower.ffxi.get_items(bag_id)
    if type(raw) ~= 'table' then return nil end
    local max = (type(raw.max) == 'number' and raw.max > 0) and raw.max or inventory.bag_capacity(bag_id)
    for slot = 1, max do
        local entry = raw[slot]
        if not (type(entry) == 'table' and entry.id and entry.id ~= 0) then
            return slot
        end
    end
    return nil
end

--- Count used / free slots for a bag.
function inventory.usage(bag_id)
    local data = inventory.read_bag(bag_id)
    return data.used, data.max, (data.max - data.used)
end

return inventory
