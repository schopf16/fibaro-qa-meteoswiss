-- Tests for App and Children. Run with: python tools/run_tests.py
--
-- The forecast response is synthetic: it has the structure of the MeteoSwiss
-- app endpoint, starts at local midnight today, and covers DAYS days.

local DAYS = 6
local CONFIG = { postalCode = "8001", rainThresholdMm = 1.0, strongWindThresholdKmh = 45, warmDayThresholdC = 18 }

local function midnight(offsetDays)
  local t = os.date("*t")
  return os.time({ year = t.year, month = t.month, day = t.day + (offsetDays or 0), hour = 0, min = 0, sec = 0 })
end

local function series(count, fn)
  local values = {}
  for i = 1, count do values[i] = fn(i) end
  return values
end

--- A response; overrides: { graph = { field = values }, forecast = {...} }.
local function response(overrides)
  overrides = overrides or {}
  local start = midnight(0)
  local hours = math.floor((midnight(DAYS) - start) / 3600)
  local graph = {
    start = start * 1000,
    precipitation10m = series(160, function() return 0 end),
    precipitationMin10m = series(160, function() return 0 end),
    precipitationMax10m = series(160, function() return 0.2 end),
    temperatureMean1h = series(hours, function() return 15 end),
    temperatureMin1h = series(hours, function() return 14 end),
    temperatureMax1h = series(hours, function() return 16 end),
    precipitation1h = series(hours, function() return 0 end),
    precipitationMin1h = series(hours, function() return 0 end),
    precipitationMax1h = series(hours, function() return 0.1 end),
    windSpeed1h = series(hours, function() return 10 end),
    windSpeed1hq10 = series(hours, function() return 5 end),
    windSpeed1hq90 = series(hours, function() return 15 end),
    gustSpeed1h = series(hours, function() return 20 end),
    gustSpeed1hq10 = series(hours, function() return 15 end),
    gustSpeed1hq90 = series(hours, function() return 30 end),
    sunshine1h = series(hours, function(i) local hour = (i - 1) % 24 return (hour >= 8 and hour < 16) and 60 or 0 end),
    precipitationProbability3h = series(DAYS * 8, function() return 10 end),
    windSpeed3h = series(DAYS * 8, function() return 10 end),
    windDirection3h = series(DAYS * 8, function() return 270 end),
    weatherIcon3hV2 = series(DAYS * 8, function() return 1 end),
    sunrise = series(DAYS, function(i) return (midnight(i - 1) + 7 * 3600) * 1000 end),
    sunset = series(DAYS, function(i) return (midnight(i - 1) + 19 * 3600) * 1000 end),
  }
  for key, value in pairs(overrides.graph or {}) do graph[key] = value end
  local forecast = overrides.forecast or series(DAYS, function(i)
    return { dayDate = os.date("%Y-%m-%d", midnight(i - 1)), temperatureMin = 8, temperatureMax = 20,
             precipitation = 0, precipitationMin = 0, precipitationMax = 0.5, iconDayV2 = 1 }
  end)
  return { graph = graph, forecast = forecast }
end

local function build(overrides, config)
  App.setConfig(config or CONFIG)
  return App.buildTables(response(overrides))
end

-- Options ---------------------------------------------------------------------

test("the poll interval is limited to 5 to 60 minutes", function()
  local field = App.OPTION_SCHEMA[1]
  eq(Config.parse(field, "600"), 600)
  eq(select(2, Config.parse(field, "60")), "must be between 300 and 3600")
end)

-- Forecast tables ----------------------------------------------------------------

test("a response becomes four tables with the same envelope", function()
  local tables = build()
  for _, name in ipairs({ "forecast10m", "forecastHourly", "forecast3h", "forecastDaily" }) do
    local t = tables[name]
    eq(t.schemaVersion, 1, name)
    eq(t.timeZone, "Europe/Zurich")
    eq(t.generatedAtUtc, tables.forecast10m.generatedAtUtc, "one timestamp for all tables")
    ok(#t.rows > 0, name .. " has no rows")
  end
  eq(tables.forecastHourly.resolution, "PT1H")
  eq(tables.forecastHourly.units.windGustKmh, "km/h")
end)

test("only the current and future intervals are published, the first marked current", function()
  local now = os.time()
  local tables = build()
  for _, name in ipairs({ "forecast10m", "forecastHourly", "forecast3h" }) do
    local rows = tables[name].rows
    eq(rows[1].current, true, name)
    ok(rows[1].epochSeconds <= now, name)
    eq(rows[2].current, false, name)
    ok(rows[2].epochSeconds > now, name)
    eq(rows[1].time, os.date("!%Y-%m-%dT%H:%M:%SZ", rows[1].epochSeconds), "UTC text matches epoch")
  end
end)

test("invalid responses are rejected with a reason", function()
  App.setConfig(CONFIG)
  for _, case in ipairs({
    { nil, "response structure is incomplete" },
    { { forecast = {} }, "response structure is incomplete" },
    { response({ graph = { start = "x" } }), "graph start time is missing" },
    { response({ graph = { precipitation10m = {} } }), "10-minute precipitation data is missing" },
    { response({ forecast = { { dayDate = "tomorrow" } } }), "daily forecast contains an invalid date" },
    { response({ forecast = series(13, function() return { dayDate = "2026-01-01" } end) }),
      "daily forecast exceeds the accepted size limit" },
  }) do
    local tables, reason = App.buildTables(case[1])
    eq(tables, nil)
    eq(reason, case[2])
  end
end)

test("missing or non-finite values are omitted, not replaced by zero", function()
  local hours = math.floor((midnight(DAYS) - midnight(0)) / 3600)
  local tables = build({ graph = {
    temperatureMean1h = series(hours, function() return 0 / 0 end),
    windSpeed1h = series(hours, function() return math.huge end),
  } })
  local values = tables.forecastHourly.rows[1].values
  eq(values.temperatureC, nil)
  eq(values.windSpeedKmh, nil)
  eq(values.windGustKmh, 20)
end)

test("daily sunshine is summed per local date and omitted for incomplete days", function()
  local tables = build()
  local hours = math.floor((midnight(DAYS) - midnight(0)) / 3600)
  local expected = {}
  local sunshine = response().graph.sunshine1h
  for i = 1, hours do
    local date = os.date("%Y-%m-%d", midnight(0) + (i - 1) * 3600)
    expected[date] = (expected[date] or 0) + sunshine[i]
  end
  for _, row in ipairs(tables.forecastDaily.rows) do
    eq(row.values.sunshineMinutes, expected[row.time], row.time)
    eq(row.values.sunshinePercent, math.floor(expected[row.time] / 60 / 12 * 100 + 0.5), row.time)
  end
  -- Only five days of hourly data: the sixth day is incomplete.
  local short = build({ graph = { sunshine1h = series(5 * 24 - 2, function() return 30 end) } })
  eq(short.forecastDaily.rows[6].values.sunshineMinutes, nil)
  eq(short.forecastDaily.rows[6].values.niceWeather, nil)
end)

test("sunshine is grouped by local date, also on the day daylight saving time ends", function()
  -- 2026-10-25 has 25 hours in Switzerland. In a runner without daylight
  -- saving time (UTC) every day has 24 hours; the grouping must hold in both.
  local start = os.time({ year = 2026, month = 10, day = 24, hour = 0, min = 0, sec = 0 })
  local stop = os.time({ year = 2026, month = 10, day = 27, hour = 0, min = 0, sec = 0 })
  local hours = math.floor((stop - start) / 3600)
  local minutes, counts = App.sunshinePerDay(start, series(hours, function() return 1 end))
  local day25 = os.time({ year = 2026, month = 10, day = 26, hour = 0, min = 0, sec = 0 })
    - os.time({ year = 2026, month = 10, day = 25, hour = 0, min = 0, sec = 0 })
  eq(counts["2026-10-24"], 24)
  eq(counts["2026-10-25"], math.floor(day25 / 3600 + 0.5))
  eq(minutes["2026-10-25"], counts["2026-10-25"])
  eq(counts["2026-10-26"], 24)
end)

test("a sunny day reaching the temperature threshold is a nice day", function()
  local days = build().forecastDaily.rows
  eq(days[1].values.condition, "sunny")
  eq(days[1].values.niceWeather, true)
  local cold = build(nil, { postalCode = "8001", rainThresholdMm = 1, strongWindThresholdKmh = 45,
                            warmDayThresholdC = 25 })
  eq(cold.forecastDaily.rows[1].values.niceWeather, false)
end)

-- Size limit ----------------------------------------------------------------------

test("a table larger than the variable limit loses its most distant rows", function()
  local tables = build()
  local hourly = tables.forecastHourly
  local full = json.encode(hourly)
  local limit = math.floor(#full / 2)
  local encoded = App.encodeTable("forecastHourly", hourly, limit)
  ok(#encoded <= limit)
  local decoded = json.decode(encoded)
  ok(#decoded.rows < #hourly.rows and #decoded.rows > 0)
  eq(decoded.rows[1].epochSeconds, hourly.rows[1].epochSeconds, "the nearest rows are kept")
  ok(logText():find("forecastHourly shortened", 1, true), logText())
  eq(App.encodeTable("forecast10m", tables.forecast10m, #full), json.encode(tables.forecast10m), "small: unchanged")
end)

-- Signals -----------------------------------------------------------------------------

test("rain needs more than the threshold in the current or next 10 minutes", function()
  local function rain(amounts)
    local values = series(160, function(i) return amounts[i] or 0 end)
    -- Place the amounts at the current 10-minute slot.
    local slot = math.floor((os.time() - midnight(0)) / 600)
    local shifted = series(160, function(i) return amounts[i - slot] or 0 end)
    return App.childValuesFrom(build({ graph = { precipitation10m = shifted } })).rainExpected, values
  end
  eq(rain({ 1.0, 1.0 }), false, "equal to the threshold is not enough")
  eq(rain({ 0, 1.1 }), true, "next slot")
  eq(rain({ 0, 0, 5 }), false, "the slot after next does not count")
end)

test("strong wind needs a gust at or above the threshold in the current or next hour", function()
  local hours = math.floor((midnight(DAYS) - midnight(0)) / 3600)
  local hour = math.floor((os.time() - midnight(0)) / 3600)
  local function wind(currentGust, nextGust)
    local gusts = series(hours, function(i)
      if i == hour + 1 then return currentGust elseif i == hour + 2 then return nextGust end
      return 0
    end)
    return App.childValuesFrom(build({ graph = { gustSpeed1h = gusts } })).strongWindExpected
  end
  eq(wind(45, 0), true)
  eq(wind(0, 45), true)
  eq(wind(44.9, 0), false)
end)

-- Children ------------------------------------------------------------------------------

local NEXT_ID, DEVICES

local function childObject(id)
  local child = { id = id }
  function child:getVariable(name) return DEVICES[self.id] and DEVICES[self.id].vars[name] or "" end
  function child:setVariable(name, value) DEVICES[self.id].vars[name] = value end
  function child:updateProperty(name, value) if DEVICES[self.id] then DEVICES[self.id][name] = value end end
  return child
end

local function childQA(storage)
  local qa = FakeQA.new({})
  qa.id, qa.name, qa.storage = 100, "Swiss Weather Forecast", storage
  function qa:internalStorageGet(key) return self.storage[key] end
  function qa:internalStorageSet(key, value) self.storage[key] = value end
  function qa:initChildDevices()
    self.childDevices = {}
    for id in pairs(DEVICES) do self.childDevices[id] = childObject(id) end
  end
  function qa:createChildDevice(options)
    NEXT_ID = NEXT_ID + 1
    DEVICES[NEXT_ID] = { name = options.name, type = options.type, vars = {} }
    self.childDevices[NEXT_ID] = childObject(NEXT_ID)
    return self.childDevices[NEXT_ID]
  end
  return qa
end

local function keys()
  local result = {}
  for id, device in pairs(DEVICES) do result[device.vars.key] = id end
  return result
end

test("the four children are created once, in a fixed order, and keep their IDs", function()
  DEVICES, NEXT_ID = {}, 200
  local storage = {}
  App.Children.sync(childQA(storage))
  eq(keys(), { rainExpected = 201, strongWindExpected = 202, niceWeather = 203, niceWeatherTomorrow = 204 })
  eq(DEVICES[201].type, "com.fibaro.binarySensor")
  for _ = 1, 3 do App.Children.sync(childQA(storage)) end
  eq(NEXT_ID, 204, "no further children")
  App.Children.sync(childQA({}))
  eq(NEXT_ID, 204, "a lost ID mapping finds the children by their key")
end)

test("a child deleted by hand is created again at the next start", function()
  DEVICES, NEXT_ID = {}, 200
  local storage = {}
  App.Children.sync(childQA(storage))
  DEVICES[202] = nil
  App.Children.sync(childQA(storage))
  eq(keys().strongWindExpected, 205)
end)

test("a child value is written only when its signal changes", function()
  DEVICES, NEXT_ID = {}, 200
  local qa = childQA({})
  App.Children.sync(qa)
  local writes = {}
  for id, child in pairs(qa.childDevices) do
    local update = child.updateProperty
    function child:updateProperty(name, value)
      writes[#writes + 1] = DEVICES[id].vars.key .. "=" .. tostring(value)
      return update(self, name, value)
    end
  end
  local tables = build()
  App.Children.update(tables)
  App.Children.update(tables)
  table.sort(writes)
  eq(writes, { "niceWeather=true", "niceWeatherTomorrow=true" }, "only changed signals, only once")
end)

-- Requests -------------------------------------------------------------------------------

local function stubHttp(status, body)
  local requests = 0
  net = { HTTPClient = function()
    return { request = function(_, url, options)
      requests = requests + 1
      ok(url:find("plz=800100", 1, true), url)
      eq(options.options.checkCertificate, true)
      if status then options.success({ status = status, data = body }) else options.error("timeout") end
    end }
  end }
  return function() return requests end
end

local function startQA()
  DEVICES, NEXT_ID = {}, 200
  local qa = childQA({})
  I18n.register(App.STRINGS)
  Ui.init(qa, App.UI)
  App.start(qa, CONFIG)
  return qa
end

test("a successful response publishes the tables and the weather properties", function()
  stubHttp(200, json.encode(response()))
  local qa = startQA()
  advance(0)
  local hourly = json.decode(qa.variables.forecastHourly)
  eq(hourly.schemaVersion, 1)
  eq(qa.properties.Temperature, { value = 15, unit = "C" })
  eq(qa.properties.Wind, 20)
  ok(qa.properties.log:find("updated", 1, true), qa.properties.log)
  Timer.cancelAll()
end)

test("an unknown postal code is reported once with a clear status", function()
  stubHttp(404, "")
  local qa = startQA()
  advance(0)
  advance(60000)
  local errors = 0
  for _, entry in ipairs(LOGS) do
    if entry.message:find("does not know the configured postal code", 1, true) then errors = errors + 1 end
  end
  eq(errors, 1, "logged once, not on every retry")
  ok(not logText():find("8001", 1, true), "the postal code is not logged")
  ok(qa.properties.log:find("Postal code unknown", 1, true), qa.properties.log)
  Timer.cancelAll()
end)

test("failures keep the old tables and retry with back-off", function()
  local requests = stubHttp(500, "")
  local qa = startQA()
  advance(0)
  eq(qa.variables.forecastHourly, nil)
  ok(logText():find("HTTP 500; retry in 60 s", 1, true), logText())
  advance(60000)
  eq(requests(), 2)
  stubHttp(200, string.rep(" ", 100001))
  advance(120000)
  ok(logText():find("response exceeds 100000 bytes", 1, true), logText())
  stubHttp(nil)
  advance(240000)
  ok(logText():find("connection error", 1, true), logText())
  Timer.cancelAll()
end)
