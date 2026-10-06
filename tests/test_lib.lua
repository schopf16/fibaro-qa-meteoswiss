-- Tests for the library in src/lib.

-- Util ------------------------------------------------------------------

test("Util.escapeHtml neutralises markup", function()
  eq(Util.escapeHtml('<b a="x">&'), "&lt;b a=&quot;x&quot;&gt;&amp;")
end)

test("Util.toAscii keeps the meaning of accented and typographic characters", function()
  eq(Util.toAscii("Batterie prüfen – Réseau … 20 °C · «ok» ½"), 'Batterie pruefen - Reseau ... 20  degC | "ok" ?')
  eq(Util.toAscii("plain ASCII"), "plain ASCII")
end)

test("Util.replaceAll treats the needle literally", function()
  eq(Util.replaceAll("a.b%c.d", ".b%", "!"), "a!c.d")
  eq(Util.replaceAll("abc", "b", "%1"), "a%1c")
end)

-- Log -------------------------------------------------------------------

test("Log redacts secrets, also inside longer values", function()
  Log.init({ tag = "T" })
  Log.addSecret("hunter22")
  Log.info("token=%s url=%s", "hunter22", "https://example.com/?k=hunter22")
  ok(not logText():find("hunter22", 1, true), "secret leaked: " .. logText())
  ok(logText():find("token=***", 1, true))
end)

test("Log escapes HTML in arguments but not in the literal format", function()
  Log.init({ tag = "T" })
  Log.info("<b>%s</b>", "<script>")
  ok(logText():find("<b>&lt;script&gt;</b>", 1, true), logText())
end)

test("Log respects the level", function()
  Log.init({ tag = "T", level = "warn" })
  Log.info("hidden")
  Log.warn("shown")
  eq(#LOGS, 1)
  eq(LOGS[1].level, "warning")
  eq(Log.setLevel("verbose"), false)
end)

test("Log uses the manifest tag and maps levels to the four HC3 types", function()
  Log.init({ level = "debug" })
  Log.error("e")
  Log.warn("w")
  Log.info("i")
  Log.debug("d")
  eq(__TAG, MANIFEST.logTag, "QaInfo must set __TAG before anything else runs")
  local types = {}
  for i, entry in ipairs(LOGS) do
    eq(entry.tag, MANIFEST.logTag)
    types[i] = entry.level
  end
  eq(types, { "error", "warning", "debug", "trace" })
end)

test("Log adds the version to error lines only", function()
  Log.init()
  Log.error("boom")
  Log.warn("careful")
  eq(LOGS[1].message, "boom [v" .. MANIFEST.version .. "]")
  eq(LOGS[2].message, "careful")
end)

test("Log folds identical consecutive lines after three", function()
  Log.init()
  for _ = 1, 25 do Log.warn("Device unreachable") end
  Log.info("Device back")
  local text = logText()
  eq(#LOGS, 6, text)
  eq(LOGS[3].message, "Device unreachable")
  eq(LOGS[4].message, "(10 times so far) Device unreachable")
  eq(LOGS[5].message, "(previous message occurred 25 times in total)")
  eq(LOGS[6].message, "Device back")
end)

test("Log survives a broken format string", function()
  Log.init({ tag = "T" })
  Log.info("%d apples", "many")
  ok(logText():find("many", 1, true))
end)

-- Safe ------------------------------------------------------------------

test("Safe.call returns results and logs errors under the QuickApp tag", function()
  Log.init()
  eq({ Safe.call("add", function(a, b) return a + b end, 2, 3) }, { true, 5 })
  local success, message = Safe.call("onRefreshPressed", function() local t = nil; return t.x end)
  eq(success, false)
  ok(message:find("attempt to index", 1, true), message)
  eq(LOGS[1].level, "error")
  eq(LOGS[1].tag, MANIFEST.logTag)
  ok(LOGS[1].message:find("^onRefreshPressed failed: "), LOGS[1].message)
end)

test("Safe.call handles non-string errors", function()
  Log.init()
  eq(select(1, Safe.call("x", function() error({ code = 1 }) end)), false)
  eq(select(1, Safe.call("y", function() error() end)), false)
end)

test("Safe.wrap protects callbacks", function()
  Log.init()
  local callback = Safe.wrap("http.success", function(response) return response.status end)
  eq(callback({ status = 200 }), 200)
  eq(callback(nil), nil)
  ok(logText():find("http.success failed", 1, true))
end)

-- Config ----------------------------------------------------------------

test("Config parses every type", function()
  eq(Config.parse({ type = "integer" }, " 42 "), 42)
  eq(Config.parse({ type = "number" }, "1.5"), 1.5)
  eq(Config.parse({ type = "boolean" }, "Yes"), true)
  eq(Config.parse({ type = "enum", values = { "a", "B" } }, "b"), "B")
  eq(Config.parse({ type = "host" }, "192.0.2.10"), "192.0.2.10")
  eq(Config.parse({ type = "host" }, "inverter.local"), "inverter.local")
  eq(Config.parse({ type = "port" }, "502"), 502)
  eq(Config.parse({ type = "url" }, "HTTPS://example.com/a"), "https://example.com/a")
end)

test("Config rejects invalid values", function()
  local function reason(field, raw) return select(2, Config.parse(field, raw)) end
  ok(reason({ type = "integer" }, "1.5"))
  ok(reason({ type = "integer", min = 1, max = 5 }, "6"))
  ok(reason({ type = "number" }, "nan"))
  ok(reason({ type = "host" }, "256.1.1.1"))
  ok(reason({ type = "host" }, "http://device.invalid"))
  ok(reason({ type = "host" }, "host:80"))
  ok(reason({ type = "host" }, "-bad.example"))
  ok(reason({ type = "port" }, "70000"))
  ok(reason({ type = "url" }, "http://example.com"), "plain http must be opt-in")
  ok(reason({ type = "string", maxLength = 3 }, "abcd"))
end)

test("Config uses defaults and reports missing required values", function()
  local schema = {
    { name = "a", type = "integer", default = 7 },
    { name = "b", type = "host", required = true },
  }
  local cfg, errors = Config.load(schema, function() return "" end)
  eq(cfg.a, 7)
  eq(errors, { { name = "b", reason = "is required" } })
end)

test("Config never puts a value into an error and collects secrets", function()
  local schema = { { name = "token", type = "secret", maxLength = 4 } }
  local _, errors, secrets = Config.load(schema, function() return "  s3cr3t-value " end)
  eq(secrets, { "s3cr3t-value" })
  ok(not errors[1].reason:find("s3cr3t", 1, true))
end)

test("Config.load survives a failing getter", function()
  local cfg = Config.load({ { name = "a", type = "integer", default = 1 } }, function() error("boom") end)
  eq(cfg.a, 1)
end)

test("Config.describe hides secrets and addresses", function()
  local schema = {
    { name = "interval", type = "integer" },
    { name = "host", type = "host" },
    { name = "pin", type = "secret", reveal = true },
    { name = "model", type = "string", reveal = true },
    { name = "port", type = "port" },
    { name = "empty", type = "string" },
  }
  local cfg = { interval = 60, host = "192.0.2.7", pin = "4711", model = "G2", port = 502 }
  eq(Config.describe(schema, cfg, { { name = "port" } }),
    "interval=60, host=set, pin=set, model=G2, port=INVALID, empty=empty")
end)

test("invalid options fall back to their default and are reported", function()
  local schema = Config.merge(Config.OPTIONS, { { name = "interval", type = "integer", default = 30, min = 10 } })
  local options, problems = Config.loadOptions(schema, { logLevel = "verbose", interval = 5, colour = "red" })
  eq(options, { logLevel = "info", language = "auto", interval = 30 })
  eq(#problems, 3)
  eq(problems[1].name, "logLevel")
  eq(problems[1].reason, "must be one of: error, warn, info, debug")
  eq(problems[3], { name = "colour", value = "red", reason = "is not a known option" })
  local good = Config.loadOptions(schema, { logLevel = "debug", interval = 60 })
  eq(good.logLevel, "debug")
  eq(good.interval, 60)
end)

test("Boot reports invalid options in the log", function()
  local app = { CONFIG = {}, STRINGS = {}, UI = {}, OPTIONS = { language = "klingon" }, start = function() end }
  eq(Boot.run(FakeQA.new({}), app), true)
  ok(logText():find("App.OPTIONS.language = klingon must be one of: auto, en, de, fr, it; using auto", 1, true),
    logText())
end)

test("Config.merge lets later fields win", function()
  local merged = Config.merge({ { name = "x", type = "string" } }, { { name = "x", type = "integer" } })
  eq(#merged, 1)
  eq(merged[1].type, "integer")
end)

-- I18n ------------------------------------------------------------------

test("I18n resolves the language", function()
  eq(I18n.resolve("auto", "de"), "de")
  eq(I18n.resolve("fr", "de"), "fr")
  eq(I18n.resolve("auto", "pl"), "en")
  eq(I18n.resolve(nil, nil), "en")
  eq(I18n.resolve("auto", "it_CH"), "it")
end)

test("I18n falls back to English and escapes parameters", function()
  I18n.register({ k = { en = "Hi {who}", de = "Hallo {who}" } })
  I18n.setLanguage("fr")
  eq(I18n.t("k", { who = "<x>" }), "Hi &lt;x&gt;")
  I18n.setLanguage("de")
  eq(I18n.t("k", { who = "%1" }), "Hallo %1")
  eq(I18n.t("missing.key"), "missing.key")
end)

-- Timer -----------------------------------------------------------------

test("Timer.every keeps running after an error and never overlaps", function()
  Log.init({ tag = "T" })
  local runs = 0
  Timer.every("t", 1000, function()
    runs = runs + 1
    if runs == 1 then error("first run fails") end
  end, { runNow = true })
  advance(0)
  advance(2000)
  eq(runs, 3)
  eq(pendingTimers(), 1)
  ok(logText():find("first run fails", 1, true))
  Timer.cancel("t")
  eq(pendingTimers(), 0)
end)

test("Timer.cancel inside the callback stops the timer", function()
  local runs = 0
  Timer.every("t", 10, function() runs = runs + 1; Timer.cancel("t") end)
  advance(100)
  eq(runs, 1)
  eq(Timer.isActive("t"), false)
end)

test("Timer.backoff grows and is capped", function()
  eq(Timer.backoff(1, 1000, 60000), 1000)
  eq(Timer.backoff(3, 1000, 60000), 4000)
  eq(Timer.backoff(99, 1000, 60000), 60000)
end)

-- Boot ------------------------------------------------------------------

local function fakeApp()
  return {
    CONFIG = { { name = "host", type = "host", required = true }, { name = "key", type = "secret" } },
    STRINGS = {},
    UI = { text = {}, statusLabel = "lblStatus" },
    start = function(_, cfg) STARTED = cfg end,
  }
end

test("Boot stops visibly when the configuration is invalid", function()
  STARTED = nil
  local qa = FakeQA.new({ host = "", key = "topsecret" })
  eq(Boot.run(qa, fakeApp()), false)
  eq(STARTED, nil)
  ok(qa.properties.log:find("host", 1, true), qa.properties.log)
  eq(Util.toAscii(qa.views.lblStatus.text), qa.properties.log)
end)

test("Boot redacts secrets from the very first log line", function()
  local qa = FakeQA.new({ host = "192.0.2.1", key = "topsecret" })
  local app = fakeApp()
  app.start = function(_, cfg) Log.info("key is %s", cfg.key) end
  eq(Boot.run(qa, app), true)
  ok(not logText():find("topsecret", 1, true), logText())
end)

test("the status line is ASCII while the label keeps the full text", function()
  API["/settings/info"] = { defaultLanguage = "de" }
  local qa = FakeQA.new({ host = "" })
  Boot.run(qa, fakeApp())
  ok(not qa.properties.log:find("[\128-\255]"), qa.properties.log)
  ok(qa.properties.log:find("pruefen", 1, true), qa.properties.log)
  ok(qa.views.lblStatus.text:find("prüfen", 1, true), qa.views.lblStatus.text)
end)

test("Boot follows the controller language", function()
  API["/settings/info"] = { defaultLanguage = "de" }
  local qa = FakeQA.new({ host = "192.0.2.1" })
  Boot.run(qa, fakeApp())
  eq(I18n.language(), "de")
  eq(qa.properties.log, Util.toAscii(LibStrings["lib.status.starting"].de))
end)

test("Boot logs what a maintainer needs to read a user's log", function()
  API["/settings/info"] = { platform = "HC3", softVersion = "5.220.11", defaultLanguage = "fr" }
  local qa = FakeQA.new({ host = "192.0.2.1", key = "topsecret" })
  qa.id = 1234
  Boot.run(qa, fakeApp())
  local text = logText()
  ok(text:find(QA_INFO.name .. " v" .. QA_INFO.version .. " starting on HC3 firmware 5.220.11 (device 1234)",
    1, true), text)
  ok(text:find("Configuration: host=set, key=set; UI language fr", 1, true), text)
  ok(text:find("Options: logLevel=info, language=auto", 1, true), text)
  ok(not text:find("192.0.2.1", 1, true), "address leaked: " .. text)
  ok(text:find("Started", 1, true), text)
end)

local function installed(ids)
  local devices = {}
  for id, repository in pairs(ids) do
    devices[#devices + 1] = { id = id, type = "com.fibaro.genericDevice" }
    API["/quickApp/" .. id .. "/files/QaInfo"] = { name = "QaInfo", content = 'repository = "' .. repository .. '"' }
  end
  API["/devices?interface=quickApp"] = devices
end

local function bootAs(id)
  local qa = FakeQA.new({ host = "192.0.2.1" })
  qa.id, qa.type = id, "com.fibaro.genericDevice"
  Boot.run(qa, fakeApp())
end

test("a single instance logs under the plain tag", function()
  installed({ [10] = QA_INFO.repository, [11] = "https://example.com/other-qa" })
  bootAs(10)
  eq(LOGS[1].tag, MANIFEST.logTag)
end)

test("several instances append the device ID to the tag", function()
  installed({ [10] = QA_INFO.repository, [12] = QA_INFO.repository })
  bootAs(12)
  eq(LOGS[1].tag, MANIFEST.logTag .. "_12")
  ok(LOGS[1].message:find("(device 12, 2 instances installed)", 1, true), LOGS[1].message)
  installed({ [12] = QA_INFO.repository })
  bootAs(12)
  eq(LOGS[#LOGS].tag, MANIFEST.logTag, "tag must return to plain once alone")
end)

test("Boot catches a failing App.start", function()
  local app = fakeApp()
  app.start = function() error("kaputt") end
  eq(Boot.run(FakeQA.new({ host = "192.0.2.1" }), app), false)
  ok(logText():find("kaputt", 1, true))
end)
