-- A tiny test framework, so the tests need nothing but a Lua 5.3 interpreter.

TESTS = {}

--- Register a test case.
function test(name, fn)
  TESTS[#TESTS + 1] = { name = name, fn = fn }
end

local function describe(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

local function deepEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deepEqual(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

--- Fail unless actual equals expected (tables are compared deeply).
function eq(actual, expected, message)
  if not deepEqual(actual, expected) then
    error((message and message .. ": " or "") ..
      "expected " .. describe(expected) .. ", got " .. describe(actual), 2)
  end
end

--- Fail unless value is truthy.
function ok(value, message)
  if not value then error(message or "expected a truthy value", 2) end
end

--- Fail unless fn raises an error whose message contains `fragment`.
function raises(fn, fragment)
  local success, err = pcall(fn)
  if success then error("expected an error", 2) end
  if fragment and not tostring(err):find(fragment, 1, true) then
    error("error " .. describe(tostring(err)) .. " does not contain " .. describe(fragment), 2)
  end
end
