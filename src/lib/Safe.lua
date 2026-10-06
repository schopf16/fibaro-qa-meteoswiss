-- Safe: run entry points protected, so no error reaches the HC3 runtime.
-- An uncaught error would stop the QuickApp and be logged without its tag.
-- Errors are logged under the QuickApp's tag, and execution continues.
--
--   function QuickApp:uibtnRefreshOnReleased(event) Safe.call("btnRefresh", App.refresh, event) end
--   http:request(url, { success = Safe.wrap("poll.success", onData), error = Safe.wrap("poll.error", onError) })

Safe = {}

local MAX_FRAMES = 8

--- Turn a traceback into one line: "file.lua:12: in function 'x' <- ...".
local function compact(traceback)
  local frames = {}
  for line in tostring(traceback):gmatch("[^\n]+") do
    line = Util.trim(line)
    local skip = line == "stack traceback:" or line:find("^%[C%]") or line:find("LibSafe")
      or line:find("^%(%.%.%.") or line:find("in function <%[string")
    if not skip and #frames < MAX_FRAMES then frames[#frames + 1] = line end
  end
  return table.concat(frames, " <- ")
end

local function handler(err)
  local trace = ""
  if debug and debug.traceback then trace = compact(debug.traceback("", 2)) end
  return { message = tostring(err), trace = trace }
end

--- Call fn(...) protected. Returns true, first result - or false, error message.
function Safe.call(name, fn, ...)
  local ok, result = xpcall(fn, handler, ...)
  if ok then return true, result end
  if type(result) ~= "table" then result = { message = tostring(result), trace = "" } end
  Log.error("%s failed: %s", name, result.message)
  if result.trace ~= "" then Log.error("%s stack: %s", name, result.trace) end
  return false, result.message
end

--- A protected version of fn for callbacks. Returns fn's first result, or nil on error.
function Safe.wrap(name, fn)
  return function(...)
    local ok, result = Safe.call(name, fn, ...)
    if ok then return result end
    return nil
  end
end
