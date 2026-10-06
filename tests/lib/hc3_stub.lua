-- Minimal HC3 runtime for offline tests on Lua 5.3.
--
-- It imitates only what the library and typical app code need: logging,
-- timers on a fake clock, api.get and a fake QuickApp object. Anything else
-- belongs in a test on the real controller.

__TAG = "QUICKAPP_TEST"

-- Everything written through fibaro.debug/trace/warning/error: { level, tag, message }
LOGS = {}

fibaro = {}
for _, level in ipairs({ "debug", "trace", "warning", "error" }) do
  fibaro[level] = function(tag, ...)
    local parts = table.pack(...)
    for i = 1, parts.n do parts[i] = tostring(parts[i]) end
    LOGS[#LOGS + 1] = { level = level, tag = tag, message = table.concat(parts, " ", 1, parts.n) }
  end
end

--- All log messages joined by newlines, for find().
function logText()
  local lines = {}
  for i, entry in ipairs(LOGS) do lines[i] = entry.level .. ": " .. entry.message end
  return table.concat(lines, "\n")
end

-- Timers run on a fake clock that only moves with advance(ms).
local now, sequence, queue = 0, 0, {}

function setTimeout(fn, ms)
  sequence = sequence + 1
  queue[#queue + 1] = { id = sequence, at = now + (ms or 0), fn = fn }
  return sequence
end

function clearTimeout(id)
  for i, timer in ipairs(queue) do
    if timer.id == id then
      table.remove(queue, i)
      return
    end
  end
end

--- Move the fake clock forward and run every timer that becomes due, in order.
function advance(ms)
  local target = now + ms
  while true do
    table.sort(queue, function(a, b) return a.at < b.at or (a.at == b.at and a.id < b.id) end)
    local timer = queue[1]
    if not timer or timer.at > target then break end
    table.remove(queue, 1)
    now = timer.at
    timer.fn()
  end
  now = target
end

function pendingTimers()
  return #queue
end

-- api.* answers from this table: path -> response body.
API = {}

api = {
  get = function(path)
    local body = API[path]
    if body == nil then return nil, 404 end
    return body, 200
  end,
  post = function() return nil, 501 end,
  put = function() return nil, 501 end,
  delete = function() return nil, 501 end,
}

-- A QuickApp stand-in that records what the code does to it.
FakeQA = {}
FakeQA.__index = FakeQA

function FakeQA.new(variables)
  return setmetatable({ variables = variables or {}, views = {}, properties = {} }, FakeQA)
end

function FakeQA:getVariable(name)
  local value = self.variables[name]
  if value == nil then return "" end
  return value
end

function FakeQA:setVariable(name, value)
  self.variables[name] = value
end

function FakeQA:updateView(id, property, value)
  self.views[id] = self.views[id] or {}
  self.views[id][property] = value
end

function FakeQA:updateProperty(name, value)
  self.properties[name] = value
end

function FakeQA:debug(...)
  fibaro.debug(__TAG, ...)
end

--- Called by tools/run_tests.py before every test case.
function resetStub()
  LOGS = {}
  API = { ["/settings/info"] = { defaultLanguage = "en" } }
  now, queue = 0, {}
end
