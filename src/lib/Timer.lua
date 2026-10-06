-- Timer: named, crash-safe timers on top of setTimeout.
--
-- Callbacks run through Safe.call: an error is logged under the QuickApp's tag
-- instead of stopping the QuickApp, and a repeating timer keeps running. A
-- repeating timer schedules its next run only after the current one returns,
-- so runs never overlap.

Timer = {}

-- setTimeout takes a signed 32-bit millisecond delay (about 24.8 days).
local MAX_DELAY_MS = 2147483647

local handles = {}
local tokens = {}

local function clamp(ms)
  ms = math.tointeger(math.floor(tonumber(ms) or 0)) or 0
  if ms < 0 then return 0 end
  if ms > MAX_DELAY_MS then return MAX_DELAY_MS end
  return ms
end

--- Run fn once after delayMs. Replaces any timer with the same name.
function Timer.after(name, delayMs, fn)
  Timer.cancel(name)
  local token = {}
  tokens[name] = token
  handles[name] = setTimeout(function()
    if tokens[name] ~= token then return end
    handles[name], tokens[name] = nil, nil
    Safe.call("timer " .. name, fn)
  end, clamp(delayMs))
end

--- Run fn every intervalMs. opts.runNow starts the first run immediately.
function Timer.every(name, intervalMs, fn, opts)
  Timer.cancel(name)
  local token = {}
  tokens[name] = token
  local function tick()
    if tokens[name] ~= token then return end
    Safe.call("timer " .. name, fn)
    if tokens[name] == token then
      handles[name] = setTimeout(tick, clamp(intervalMs))
    end
  end
  handles[name] = setTimeout(tick, (opts and opts.runNow) and 0 or clamp(intervalMs))
end

function Timer.cancel(name)
  if handles[name] then clearTimeout(handles[name]) end
  handles[name], tokens[name] = nil, nil
end

function Timer.cancelAll()
  for name in pairs(handles) do Timer.cancel(name) end
end

function Timer.isActive(name)
  return tokens[name] ~= nil
end

--- Exponential back-off delay for retry number `attempt` (1, 2, ...), capped at maxMs.
function Timer.backoff(attempt, baseMs, maxMs)
  local exponent = math.min(math.max((tonumber(attempt) or 1) - 1, 0), 30)
  return math.tointeger(math.floor(math.min(baseMs * 2 ^ exponent, maxMs)))
end
