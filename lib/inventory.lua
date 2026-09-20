--[[
    inventory.lua — Live reads of bag contents and capacity.

    Everything here reads fresh from the game every call. The planner and the
    executor both re-read before acting, because slot indices shift as soon as
    an item moves.

    Item status values (from the game):
        0  normal, movable
        1  equipped
        5  linkshell equipped / in use
    Anything other than 0 cannot be moved, so those items are marked locked.
]]

local bags = require('lib/bags')
local items = require('lib/items')

local inventory = {}

--- Capacity and accessibility for one bag, without pushing every item.
-- Returns { count, max, enabled }.
function inventory.bag_info(bag_id)
    local ok, info = pcall(windower.ffxi.get_bag_info, bag_id)
    if ok and type(info) == 'table' then
        return {
            count   = tonumber(info.count) or 0,
            max     = tonumber(info.max) or 0,
            enabled = info.enabled and true or false,
        }
    end
    return { count = 0, max = 0, enabled = false }
end

--- Is this bag usable right now?
-- Inventory is always available. Other bags follow the game's own `enabled`
-- flag, which already accounts for Mog House-only containers. A bag that
-- reports items is treated as available even if the flag is false, because
-- the flag is known to lag on higher wardrobes.
function inventory.available(bag_id)
    if bag_id == bags.INVENTORY_ID then return true end
    local info = inventory.bag_info(bag_id)
    return info.enabled or info.count > 0
end

--- Read one bag.
-- Returns { id, key, name, max, used, free, items = { entry, ... },
--           available = bool }
-- Each entry: { slot, id, count, name, category, slot_name, stack,
--               locked, status, equippable, furniture, rare, ex }
function inventory.read(bag_id)
    local def = bags.get_by_id(bag_id)
    local info = inventory.bag_info(bag_id)
    local out = {
        id = bag_id,
        key = def and def.key,
        name = bags.name_for(bag_id),
        max = info.max,
        used = 0,
        free = 0,
        items = {},
        available = inventory.available(bag_id),
    }

    local ok, raw = pcall(windower.ffxi.get_items, bag_id)
    if not ok or type(raw) ~= 'table' then
        return out
    end

    if tonumber(raw.max) and tonumber(raw.max) > 0 then
        out.max = tonumber(raw.max)
    end

    for slot = 1, out.max do
        local e = raw[slot]
        if type(e) == 'table' and e.id and e.id ~= 0 then
            local meta = items.get(e.id)
            local status = tonumber(e.status) or 0
            out.items[#out.items + 1] = {
                slot = slot,
                id = e.id,
                count = tonumber(e.count) or 1,
                name = meta.name,
                category = meta.category,
                slot_name = meta.slot,
                stack = meta.stack,
                equippable = meta.equippable,
                furniture = meta.furniture,
                rare = meta.rare,
                ex = meta.ex,
                status = status,
                locked = status ~= 0,
                bag_id = bag_id,
                bag_name = out.name,
            }
            out.used = out.used + 1
        end
    end

    out.free = math.max(0, out.max - out.used)
    return out
end

--- Read every bag the player can currently use.
-- `keys` optionally limits the read to specific bag keys.
-- Returns an array of bag tables in canonical order.
function inventory.snapshot(keys)
    local out = {}
    for _, b in ipairs(bags.list) do
        if not keys or keys[b.key] then
            local data = inventory.read(b.id)
            if data.available then
                out[#out + 1] = data
            end
        end
    end
    return out
end

--- Find an item in a bag by slot, verifying the id matches.
-- Returns the entry, or nil when the slot no longer holds that item.
function inventory.at(bag_id, slot, expect_id)
    local ok, raw = pcall(windower.ffxi.get_items, bag_id)
    if not ok or type(raw) ~= 'table' then return nil end
    local e = raw[slot]
    if type(e) == 'table' and e.id and e.id ~= 0 then
        if not expect_id or e.id == expect_id then return e end
    end
    return nil
end

--- Find the slot of an item id in a bag, preferring a given stack count.
-- Returns slot, entry.
function inventory.find(bag_id, item_id, want_count)
    local ok, raw = pcall(windower.ffxi.get_items, bag_id)
    if not ok or type(raw) ~= 'table' then return nil end
    local max = tonumber(raw.max) or 80
    local fallback, fallback_entry
    for slot = 1, max do
        local e = raw[slot]
        if type(e) == 'table' and e.id == item_id and (tonumber(e.status) or 0) == 0 then
            if want_count and (tonumber(e.count) or 1) == want_count then
                return slot, e
            end
            if not fallback then fallback, fallback_entry = slot, e end
        end
    end
    return fallback, fallback_entry
end

--- Total quantity of an item id in a bag, summed across every stack.
-- Used to verify a move: the destination total must rise by the moved count,
-- which stays correct when stacks merge or a matching stack was already there.
function inventory.total(bag_id, item_id)
    local ok, raw = pcall(windower.ffxi.get_items, bag_id)
    if not ok or type(raw) ~= 'table' then return 0 end
    local max = tonumber(raw.max) or 80
    local sum = 0
    for slot = 1, max do
        local e = raw[slot]
        if type(e) == 'table' and e.id == item_id then
            sum = sum + (tonumber(e.count) or 1)
        end
    end
    return sum
end

--- Free slot count for a bag, read live.
function inventory.free_slots(bag_id)
    local info = inventory.bag_info(bag_id)
    if info.max > 0 then
        return math.max(0, info.max - info.count)
    end
    local data = inventory.read(bag_id)
    return data.free
end

return inventory
