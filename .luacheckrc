-- luacheck configuration.
-- The HC3 runs Lua 5.3; code that needs 5.4 must fail here.
std = "lua53"
max_line_length = 120
codes = true

-- Unused arguments named with a leading underscore are intentional.
ignore = { "212/_.*" }

-- Provided by the HC3 QuickApp runtime.
read_globals = {
  "fibaro", "api", "net", "json", "hub", "plugin", "mqtt",
  "QuickAppBase", "QuickAppChild", "class", "property",
  "setTimeout", "clearTimeout", "setInterval", "clearInterval",
  "urlencode",
}

-- Defined by this project: QuickApp methods, the generated QA_INFO, the
-- library, and one global table per project part.
globals = {
  "__TAG", "QuickApp", "QA_INFO",
  "Util", "Log", "Safe", "Config", "I18n", "Timer", "Ui", "LibStrings", "Boot",
  "Strings", "App",
}

-- QuickApp methods receive self from the runtime.
files["src/main.lua"] = { self = false }

files["tests/"] = {
  std = "+lua53",
  self = false,
  globals = {
    "TESTS", "test", "eq", "ok", "raises", "LOGS", "logText", "advance",
    "pendingTimers", "resetStub", "API", "FakeQA", "MANIFEST", "STARTED",
    "fibaro", "api", "json", "setTimeout", "clearTimeout", "__TAG",
  },
}
