--[[
  Virtual clock for deterministic debounce testing.

  UIManager stub plugs into this: scheduleIn deadlines are computed using
  now(), and tickBy(s) / advance(s) fires elapsed callbacks without sleeping.
]]
local virtual_clock = {}

local _time = 0

function virtual_clock.now()
    return _time
end

function virtual_clock.advance(seconds)
    _time = _time + seconds
end

function virtual_clock.reset()
    _time = 0
end

-- set(t) places the clock at an absolute time.
function virtual_clock.set(t)
    _time = t
end

return virtual_clock
