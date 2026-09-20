--[[
    executor.lua — Perform planned moves, verifying each one.

    The Windower 4 API moves items relative to Inventory only:
        windower.ffxi.get_item(bag_id, index, count)   bag -> Inventory
        windower.ffxi.put_item(bag_id, index, count)   Inventory -> bag
    There is no direct bag-to-bag move, so a transfer between two non-Inventory
    bags is two hops with Inventory in the middle.

    The old version fired a packet and assumed it worked. This one issues a
    hop, then waits and re-reads the bags to confirm the item actually landed
    before moving on. A hop that does not land within `timeout` is reported as
    failed and the run continues with the next move.

    Execution is a frame-driven state machine so the game thread is never
    blocked: call tick() once per frame.
]]

local bags = require('lib/bags')
local inventory = require('lib/inventory')

local executor = {}

local INV = bags.INVENTORY_ID

-- States: idle, issue, verify, done
executor.state = {
    running = false,
    done = false,
    aborted = false,
    plan = nil,
    index = 0,
    phase = 'issue',
    hop = 1,
    next_time = 0,
    deadline = 0,
    delay = 0.8,
    timeout = 5.0,
    attempts = 0,
    staged_slot = nil,
    completed = 0,
    failed = 0,
    total = 0,
    log = {},
}

local function log(fmt, ...)
    local s = select('#', ...) > 0 and fmt:format(...) or fmt
    local e = executor.state
    e.log[#e.log + 1] = s
    if executor.on_log then executor.on_log(s) end
end

--- Begin executing a plan.
function executor.start(plan, opts)
    opts = opts or {}
    executor.state = {
        running = #plan.moves > 0,
        done = #plan.moves == 0,
        aborted = false,
        plan = plan,
        index = 1,
        phase = 'issue',
        hop = 1,
        next_time = os.clock(),
        deadline = 0,
        delay = math.max(0.3, tonumber(opts.delay) or 0.8),
        timeout = tonumber(opts.timeout) or 5.0,
        attempts = 0,
        staged_slot = nil,
        completed = 0,
        failed = 0,
        total = #plan.moves,
        log = {},
    }
    return executor.state.running
end

function executor.stop(reason)
    local e = executor.state
    if e.running then
        e.running = false
        e.done = true
        e.aborted = true
        log('Stopped: %s (%d of %d done)', reason or 'aborted', e.completed, e.total)
    end
end

function executor.progress()
    local e = executor.state
    return {
        running = e.running, done = e.done, aborted = e.aborted,
        completed = e.completed, failed = e.failed, total = e.total,
        index = e.index, log = e.log,
    }
end

-- Move on to the next planned item.
local function advance(e)
    e.index = e.index + 1
    e.phase = 'issue'
    e.hop = 1
    e.attempts = 0
    e.staged_slot = nil
    e.next_time = os.clock() + e.delay
end

local function fail(e, move, why)
    log('FAILED %s (%s -> %s): %s', move.name, move.from_name, move.to_name, why)
    e.failed = e.failed + 1
    advance(e)
end

-- Issue one hop. Returns true when the call was made.
local function issue_hop(e, move)
    if e.hop == 1 and move.hops == 2 then
        -- Stage: source bag -> Inventory.
        local slot = inventory.find(move.from_id, move.item_id, move.count)
        if not slot then
            fail(e, move, 'item no longer in ' .. move.from_name)
            return false
        end
        e.staged_from = slot
        return pcall(windower.ffxi.get_item, move.from_id, slot, move.count)

    elseif move.hops == 2 then
        -- Deliver: Inventory -> target bag.
        local slot = inventory.find(INV, move.item_id, move.count)
        if not slot then
            fail(e, move, 'lost track of the item after staging')
            return false
        end
        e.staged_slot = slot
        return pcall(windower.ffxi.put_item, move.to_id, slot, move.count)

    elseif move.to_id == INV then
        -- One hop into Inventory.
        local slot = inventory.find(move.from_id, move.item_id, move.count)
        if not slot then
            fail(e, move, 'item no longer in ' .. move.from_name)
            return false
        end
        return pcall(windower.ffxi.get_item, move.from_id, slot, move.count)

    else
        -- One hop out of Inventory.
        local slot = inventory.find(INV, move.item_id, move.count)
        if not slot then
            fail(e, move, 'item no longer in Inventory')
            return false
        end
        return pcall(windower.ffxi.put_item, move.to_id, slot, move.count)
    end
end

-- Which bag does the current hop deliver into?
local function hop_destination(e, move)
    if move.hops == 2 and e.hop == 1 then return INV end
    return move.to_id
end

-- Did the hop land? The destination's total of this item must have risen by
-- the moved quantity since the hop was issued. Comparing totals (rather than
-- looking for a matching stack) stays correct when a same-sized stack was
-- already there, or when stacks merge.
local function hop_landed(e, move)
    local now = inventory.total(hop_destination(e, move), move.item_id)
    return now >= (e.dest_before or 0) + move.count
end

--- Advance execution. Call once per frame. Returns true while running.
function executor.tick()
    local e = executor.state
    if not e.running then return false end

    local now = os.clock()
    if now < e.next_time then return true end

    local move = e.plan.moves[e.index]
    if not move then
        e.running = false
        e.done = true
        log('Sort complete: %d moved, %d failed.', e.completed, e.failed)
        if executor.on_finish then executor.on_finish(executor.progress()) end
        return false
    end

    if e.phase == 'issue' then
        -- Baseline for verification: what the destination holds right now.
        e.dest_before = inventory.total(hop_destination(e, move), move.item_id)

        local ok = issue_hop(e, move)
        if ok == false then
            -- issue_hop already failed and advanced, or the API call errored.
            if e.phase == 'issue' and e.index <= e.total then
                fail(e, move, 'the game rejected the move')
            end
            return true
        end
        e.phase = 'verify'
        e.deadline = now + e.timeout
        e.next_time = now + 0.3
        return true
    end

    -- phase == 'verify'
    if hop_landed(e, move) then
        if move.hops == 2 and e.hop == 1 then
            e.hop = 2
            e.phase = 'issue'
            e.next_time = now + e.delay
        else
            log('Moved %s x%d: %s -> %s',
                move.name, move.count, move.from_name, move.to_name)
            e.completed = e.completed + 1
            advance(e)
        end
        return true
    end

    if now >= e.deadline then
        fail(e, move, 'the move did not complete in time')
        return true
    end

    e.next_time = now + 0.3
    return true
end

return executor
