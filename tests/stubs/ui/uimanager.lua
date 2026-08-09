--[[
  Stub UIManager.

  scheduleIn records (deadline, fn) on a queue driven by virtual_clock
  so debounce logic can be exercised without real sleep.
]]
local UIManager = {}

local _queue = {}        -- {deadline, fn}
local _shown = {}        -- widgets passed to show()
local _closed = {}       -- widgets passed to close()
local _clock = nil       -- virtual_clock module reference

function UIManager._reset()
    _queue  = {}
    _shown  = {}
    _closed = {}
end

function UIManager._set_clock(vc)
    _clock = vc
end

local function now()
    if _clock then return _clock.now() end
    return os.time()
end

function UIManager:scheduleIn(delay, fn)
    table.insert(_queue, { deadline = now() + delay, fn = fn })
end

function UIManager:unschedule(fn)
    for i = #_queue, 1, -1 do
        if _queue[i].fn == fn then
            table.remove(_queue, i)
        end
    end
end

function UIManager:show(widget)
    table.insert(_shown, widget)
end

function UIManager:close(widget)
    table.insert(_closed, widget)
end

-- Fire callbacks whose deadline <= current virtual time.
function UIManager.tickBy(seconds)
    if _clock then _clock.advance(seconds) end
    local t = now()
    local fired = true
    while fired do
        fired = false
        for i, entry in ipairs(_queue) do
            if entry.deadline <= t then
                table.remove(_queue, i)
                entry.fn()
                fired = true
                break
            end
        end
    end
end

-- Drain all pending callbacks regardless of deadline.
-- Bounded at 1000 iterations to defuse self-rescheduling tasks like
-- GrimmorySync:_periodicFlush() that would otherwise loop forever during
-- spec_helper.teardown (cleanup never advances the clock).
function UIManager._drain_all()
    local iter = 0
    while #_queue > 0 and iter < 1000 do
        local entry = table.remove(_queue, 1)
        entry.fn()
        iter = iter + 1
    end
end

function UIManager.shown() return _shown end
function UIManager.closed() return _closed end

return UIManager
