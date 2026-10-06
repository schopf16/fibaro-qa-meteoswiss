-- App: retrieve MeteoSwiss forecasts for a Swiss postal code and publish them
-- as forecast tables for scenes, weather properties and child signals.
--
-- All project code lives in the global App table (App.Children in Children.lua).

App = {}
App.STRINGS = Strings

-- Options of this QuickApp. Change a value here and save; the QuickApp restarts.
-- An invalid value is reported in the log and replaced by its default.
App.OPTIONS = {
  pollIntervalSec = 300,    -- seconds between two forecast requests: 300 to 3600
  logLevel        = "info", -- "error", "warn", "info" or "debug" (for bug reports)
  language        = "auto", -- "auto" (controller language), "en", "de", "fr" or "it"
}

App.OPTION_SCHEMA = {
  { name = "pollIntervalSec", type = "integer", default = 300, min = 300, max = 3600 },
}

App.CONFIG = {
  { name = "postalCode", type = "string", required = true, pattern = "^%d%d%d%d$", maxLength = 4 },
  { name = "rainThresholdMm", type = "number", default = 1.0, min = 0, max = 50 },
  { name = "strongWindThresholdKmh", type = "number", default = 45, min = 1, max = 250 },
  { name = "warmDayThresholdC", type = "number", default = 18, min = -30, max = 60 },
  { name = "forecast10m", type = "string", default = "", maxLength = 60000 },
  { name = "forecastHourly", type = "string", default = "", maxLength = 60000 },
  { name = "forecast3h", type = "string", default = "", maxLength = 60000 },
  { name = "forecastDaily", type = "string", default = "", maxLength = 60000 },
}

App.UI = {
  text = { btnRefresh = "ui.refresh", lblLocation = "ui.location" },
  statusLabel = "lblStatus",
}

App.Children = {}

local API_BASE = "https://app-prod-ws.meteoswiss-app.ch/v1/plzDetail?plz="
local HTTP_TIMEOUT_MS = 15000
local OUTPUT_VARIABLES = { "forecast10m", "forecastHourly", "forecast3h", "forecastDaily" }
local RETRY_BASE_MS, RETRY_MAX_MS = 60000, 1800000
local MAX_TABLE_BYTES = 60000 -- per output variable; longer tables lose their last rows

local qa, config = nil, {}
local requestInFlight = false
local retryCount = 0

local CHILD_CATALOG = {
  rainExpected = { labelKey = "child.rainExpected", source = "rain", binary = true },
  strongWindExpected = { labelKey = "child.strongWindExpected", source = "wind", binary = true },
  niceWeather = { labelKey = "child.niceWeather", source = "today", binary = true },
  niceWeatherTomorrow = { labelKey = "child.niceWeatherTomorrow", source = "tomorrow", binary = true },
}

local function utcText(epoch)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function valueAt(values, index)
  if type(values) ~= "table" then return nil end
  local value = values[index]
  if isFiniteNumber(value) then return value end
  return nil
end

local function tableEnvelope(resolution, generatedAt, rows, units)
  return {
    schemaVersion = 1,
    source = "MeteoSwiss app forecast",
    location = { postalCode = config.postalCode },
    timeZone = "Europe/Zurich",
    resolution = resolution,
    generatedAtUtc = utcText(generatedAt),
    units = units,
    rows = rows,
  }
end

--- Sunshine minutes and number of hours per local calendar date, from hourly
-- values starting at graphStart. A day has 23 or 25 hours when daylight saving
-- time starts or ends, so hours are grouped by date, not in blocks of 24.
function App.sunshinePerDay(graphStart, hourly)
  local minutesByDate, hoursByDate = {}, {}
  if type(hourly) ~= "table" then return minutesByDate, hoursByDate end
  for i = 1, #hourly do
    local minutes = valueAt(hourly, i)
    if minutes ~= nil then
      local date = os.date("%Y-%m-%d", graphStart + (i - 1) * 3600)
      minutesByDate[date] = (minutesByDate[date] or 0) + minutes
      hoursByDate[date] = (hoursByDate[date] or 0) + 1
    end
  end
  return minutesByDate, hoursByDate
end

--- Build the four forecast tables from a decoded response. Returns the
-- tables, or nil and the reason the response was rejected.
function App.buildTables(data)
  if type(data) ~= "table" or type(data.graph) ~= "table" or type(data.forecast) ~= "table" then
    return nil, "response structure is incomplete"
  end
  local graph = data.graph
  if not isFiniteNumber(graph.start) then return nil, "graph start time is missing" end

  local now = os.time()
  local graphStart = math.floor(graph.start / 1000)
  local generatedAt = now
  local rows10m, rowsHourly, rows3h, rowsDaily = {}, {}, {}, {}
  local rain10m = graph.precipitation10m
  local rain10mMin = graph.precipitationMin10m
  local rain10mMax = graph.precipitationMax10m
  local row

  if type(rain10m) ~= "table" or #rain10m == 0 then
    return nil, "10-minute precipitation data is missing"
  end
  for i = 1, #rain10m do
    local timestamp = graphStart + (i - 1) * 600
    if timestamp + 600 > now then
      row = { time = utcText(timestamp), epochSeconds = timestamp, current = timestamp <= now, values = {} }
      row.values.precipitationMm = valueAt(rain10m, i)
      row.values.precipitationMinMm = valueAt(rain10mMin, i)
      row.values.precipitationMaxMm = valueAt(rain10mMax, i)
      if row.values.precipitationMm then rows10m[#rows10m + 1] = row end
    end
  end

  local hourlyFields = {
    { "temperatureMean1h", "temperatureC" },
    { "temperatureMin1h", "temperatureMinC" },
    { "temperatureMax1h", "temperatureMaxC" },
    { "precipitation1h", "precipitationMm" },
    { "precipitationMin1h", "precipitationMinMm" },
    { "precipitationMax1h", "precipitationMaxMm" },
    { "windSpeed1h", "windSpeedKmh" },
    { "windSpeed1hq10", "windSpeedQ10Kmh" },
    { "windSpeed1hq90", "windSpeedQ90Kmh" },
    { "gustSpeed1h", "windGustKmh" },
    { "gustSpeed1hq10", "windGustQ10Kmh" },
    { "gustSpeed1hq90", "windGustQ90Kmh" },
    { "sunshine1h", "sunshineMinutes" },
  }
  local hourlyLength = 0
  for _, field in ipairs(hourlyFields) do
    if type(graph[field[1]]) == "table" then hourlyLength = math.max(hourlyLength, #graph[field[1]]) end
  end
  if hourlyLength == 0 then return nil, "hourly forecast data is missing" end
  for i = 1, hourlyLength do
    local timestamp = graphStart + (i - 1) * 3600
    if timestamp + 3600 > now then
      local values = {}
      for _, field in ipairs(hourlyFields) do
        local value = valueAt(graph[field[1]], i)
        if value ~= nil then values[field[2]] = value end
      end
      if values.sunshineMinutes ~= nil then
        values.sunshinePercent = math.floor(values.sunshineMinutes / 60 * 100 + 0.5)
      end
      if next(values) then
        rowsHourly[#rowsHourly + 1] = {
          time = utcText(timestamp), epochSeconds = timestamp, current = timestamp <= now, values = values,
        }
      end
    end
  end

  local threeHourFields = {
    { "precipitationProbability3h", "precipitationProbabilityPct" },
    { "windSpeed3h", "windSpeedKmh" },
    { "windDirection3h", "windDirectionDegrees" },
    { "weatherIcon3hV2", "weatherCode" },
  }
  local threeHourLength = 0
  for _, field in ipairs(threeHourFields) do
    if type(graph[field[1]]) == "table" then threeHourLength = math.max(threeHourLength, #graph[field[1]]) end
  end
  for i = 1, threeHourLength do
    local timestamp = graphStart + (i - 1) * 10800
    if timestamp + 10800 > now then
      local values = {}
      for _, field in ipairs(threeHourFields) do
        local value = valueAt(graph[field[1]], i)
        if value ~= nil then values[field[2]] = value end
      end
      if next(values) then
        rows3h[#rows3h + 1] = {
          time = utcText(timestamp), epochSeconds = timestamp, current = timestamp <= now, values = values,
        }
      end
    end
  end

  local sunshineByDate, hoursByDate = App.sunshinePerDay(graphStart, graph.sunshine1h)

  if #data.forecast > 12 then return nil, "daily forecast exceeds the accepted size limit" end
  for i, day in ipairs(data.forecast) do
    if type(day) ~= "table" or type(day.dayDate) ~= "string"
      or not day.dayDate:match("^%d%d%d%d%-%d%d%-%d%d$") then
      return nil, "daily forecast contains an invalid date"
    end
    local year, month, dayOfMonth = day.dayDate:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    local dayEpoch = os.time({
      year = tonumber(year), month = tonumber(month), day = tonumber(dayOfMonth),
      hour = 0, min = 0, sec = 0,
    })
    local values = {}
    local dailyFields = {
      { "temperatureMin", "temperatureMinC" },
      { "temperatureMax", "temperatureMaxC" },
      { "precipitation", "precipitationMm" },
      { "precipitationMin", "precipitationMinMm" },
      { "precipitationMax", "precipitationMaxMm" },
      { "iconDayV2", "weatherCode" },
    }
    for _, field in ipairs(dailyFields) do
      local value = day[field[1]]
      if isFiniteNumber(value) then values[field[2]] = value end
    end
    local nextDayEpoch = os.time({
      year = tonumber(year), month = tonumber(month), day = tonumber(dayOfMonth) + 1,
      hour = 0, min = 0, sec = 0,
    })
    local hoursInDay = math.floor((nextDayEpoch - dayEpoch) / 3600 + 0.5)
    local completeDay = hoursByDate[day.dayDate] == hoursInDay
    local sunshineMinutes = sunshineByDate[day.dayDate]
    if completeDay then values.sunshineMinutes = sunshineMinutes end
    local sunrise = valueAt(graph.sunrise, i)
    local sunset = valueAt(graph.sunset, i)
    if completeDay and sunrise and sunset and sunset > sunrise then
      local daylightHours = (sunset - sunrise) / 3600000
      values.sunshinePercent = math.floor(sunshineMinutes / 60 / daylightHours * 100 + 0.5)
    end
    if values.precipitationMm ~= nil and values.sunshinePercent ~= nil then
      if values.precipitationMm >= 5 then values.condition = "rainy"
      elseif values.precipitationMm >= 1 then values.condition = "mixed"
      elseif values.sunshinePercent >= 50 then values.condition = "sunny"
      elseif values.sunshinePercent >= 20 then values.condition = "mostly_sunny"
      else values.condition = "mixed" end
      values.niceWeather = values.temperatureMaxC ~= nil
        and values.temperatureMaxC >= config.warmDayThresholdC
        and (values.condition == "sunny" or values.condition == "mostly_sunny")
    end
    rowsDaily[#rowsDaily + 1] = {
      time = day.dayDate, epochSeconds = dayEpoch, current = i == 1, values = values,
    }
  end

  if #rows10m == 0 or #rowsHourly == 0 or #rows3h == 0 or #rowsDaily == 0 then
    return nil, "one or more forecast tables are empty"
  end

  local tables = {
    forecast10m = tableEnvelope("PT10M", generatedAt, rows10m, {
      precipitationMm = "mm", precipitationMinMm = "mm", precipitationMaxMm = "mm",
    }),
    forecastHourly = tableEnvelope("PT1H", generatedAt, rowsHourly, {
      temperatureC = "°C", temperatureMinC = "°C", temperatureMaxC = "°C",
      precipitationMm = "mm", precipitationMinMm = "mm", precipitationMaxMm = "mm",
      windSpeedKmh = "km/h", windSpeedQ10Kmh = "km/h", windSpeedQ90Kmh = "km/h",
      windGustKmh = "km/h", windGustQ10Kmh = "km/h", windGustQ90Kmh = "km/h",
      sunshineMinutes = "min", sunshinePercent = "%",
    }),
    forecast3h = tableEnvelope("PT3H", generatedAt, rows3h, {
      precipitationProbabilityPct = "%", windSpeedKmh = "km/h", windDirectionDegrees = "°",
      weatherCode = "MeteoSwiss code",
    }),
    forecastDaily = tableEnvelope("P1D", generatedAt, rowsDaily, {
      temperatureMinC = "°C", temperatureMaxC = "°C", precipitationMm = "mm",
      precipitationMinMm = "mm", precipitationMaxMm = "mm", weatherCode = "MeteoSwiss code",
      sunshineMinutes = "min", sunshinePercent = "%", condition = "category", niceWeather = "boolean",
    }),
  }
  return tables
end

local shortened = {} -- table name -> true once its shortening was logged

--- JSON text of a forecast table of at most `limit` bytes. Rows are removed
-- from the end (the most distant forecast) until the text fits.
function App.encodeTable(name, envelope, limit)
  local encoded = json.encode(envelope)
  if #encoded <= limit then return encoded end
  local rows = envelope.rows
  local total = #rows
  -- Estimate the number of rows that fit, then correct row by row.
  local keep = math.max(1, math.floor(total * limit / #encoded))
  local trimmed = {}
  for key, value in pairs(envelope) do trimmed[key] = value end
  repeat
    trimmed.rows = { table.unpack(rows, 1, keep) }
    encoded = json.encode(trimmed)
    keep = keep - 1
  until #encoded <= limit or keep < 1
  if #encoded > limit then error("forecast table " .. name .. " does not fit into " .. limit .. " bytes") end
  if not shortened[name] then
    shortened[name] = true
    Log.warn("Forecast table %s shortened from %s to %s rows to fit into %s bytes", name, total,
      #trimmed.rows, limit)
  end
  return encoded
end

local function writeTables(tables)
  for _, name in ipairs(OUTPUT_VARIABLES) do
    qa:setVariable(name, App.encodeTable(name, tables[name], MAX_TABLE_BYTES))
  end
  App.updateWeatherDevice(tables)
  App.Children.update(tables)
end

local function setStatus(key, args)
  Ui.setStatus(key, args)
end

local function scheduleNext(delayMs)
  Timer.after("poll", delayMs, App.poll)
end

local function onFailure(reason)
  requestInFlight = false
  retryCount = math.min(retryCount + 1, 10)
  Log.warn("Forecast request failed: %s; retry in %s s", reason,
    math.floor(Timer.backoff(retryCount, RETRY_BASE_MS, RETRY_MAX_MS) / 1000))
  setStatus("status.error")
  scheduleNext(Timer.backoff(retryCount, RETRY_BASE_MS, RETRY_MAX_MS))
end

local function onSuccess(response)
  requestInFlight = false
  if type(response) ~= "table" then
    onFailure("unexpected HTTP response")
    return
  end
  if response.status ~= 200 then
    onFailure("HTTP " .. tostring(response.status))
    return
  end
  if type(response.data) ~= "string" then
    onFailure("response body is missing")
    return
  end
  if #response.data > 100000 then
    onFailure("response exceeds 100000 bytes")
    return
  end
  local ok, data = pcall(json.decode, response.data)
  if not ok then
    onFailure("JSON decoding failed")
    return
  end
  local tables, reason = App.buildTables(data)
  if not tables then
    onFailure(reason)
    return
  end
  local writeOk, writeError = pcall(writeTables, tables)
  if not writeOk then
    onFailure("cannot publish forecast tables: " .. tostring(writeError))
    return
  end
  retryCount = 0
  setStatus("status.updated", { time = os.date("%H:%M") })
  Log.info("Forecast updated: %s 10-minute, %s hourly, %s three-hour and %s daily rows",
    #tables.forecast10m.rows, #tables.forecastHourly.rows, #tables.forecast3h.rows, #tables.forecastDaily.rows)
  scheduleNext(App.OPTIONS.pollIntervalSec * 1000)
end

local function onHttpError(_errorMessage)
  onFailure("connection error")
end

--- Start the fetch loop after Boot has validated configuration.
--- Configuration used to build tables and signals (also used by tests).
function App.setConfig(cfg)
  config = cfg
end

function App.start(quickApp, cfg)
  qa = quickApp
  App.setConfig(cfg)
  Ui.setText("lblLocation", "ui.location.configured", { postalCode = cfg.postalCode })
  App.Children.sync(qa)
  Log.info("Starting forecast for the configured postal code, polling every %s s",
    App.OPTIONS.pollIntervalSec)
  scheduleNext(0)
end

--- Fetch and validate one response. Only one request may be active at a time.
function App.poll()
  if requestInFlight then
    Log.warn("Forecast request is still running; skipping this poll")
    scheduleNext(App.OPTIONS.pollIntervalSec * 1000)
    return
  end
  requestInFlight = true
  local url = API_BASE .. config.postalCode .. "00"
  Log.debug("Requesting forecast")
  local ok = pcall(function()
    net.HTTPClient({ timeout = HTTP_TIMEOUT_MS }):request(url, {
      options = { method = "GET", timeout = HTTP_TIMEOUT_MS, checkCertificate = true },
      success = Safe.wrap("forecast response", onSuccess),
      error = Safe.wrap("forecast network error", onHttpError),
    })
  end)
  if not ok then onFailure("request could not be started") end
end

--- Handler for the Refresh button.
function App.refresh()
  Log.info("Manual forecast refresh")
  Timer.cancel("poll")
  retryCount = 0
  App.poll()
end

function App.childCatalog()
  return CHILD_CATALOG
end

function App.childValuesFrom(tables)
  local values = {}
  local rainExpected = false
  for i = 1, math.min(2, #tables.forecast10m.rows) do
    local amount = tables.forecast10m.rows[i].values.precipitationMm
    if isFiniteNumber(amount) and amount > config.rainThresholdMm then rainExpected = true end
  end
  values.rainExpected = rainExpected

  local strongWindExpected = false
  local foundGust = false
  for i = 1, math.min(2, #tables.forecastHourly.rows) do
    local gust = tables.forecastHourly.rows[i].values.windGustKmh
    if isFiniteNumber(gust) then
      foundGust = true
      if gust >= config.strongWindThresholdKmh then strongWindExpected = true end
    end
  end
  if foundGust then values.strongWindExpected = strongWindExpected end
  local today = tables.forecastDaily.rows[1]
  local tomorrow = tables.forecastDaily.rows[2]
  if today and type(today.values.niceWeather) == "boolean" then values.niceWeather = today.values.niceWeather end
  if tomorrow and type(tomorrow.values.niceWeather) == "boolean" then
    values.niceWeatherTomorrow = tomorrow.values.niceWeather
  end
  return values
end

function App.updateWeatherDevice(tables)
  local nextHour
  for _, row in ipairs(tables.forecastHourly.rows) do
    if not row.current then nextHour = row break end
  end
  if nextHour then
    local values = nextHour.values
    if isFiniteNumber(values.temperatureC) then
      qa:updateProperty("Temperature", { value = values.temperatureC, unit = "C" })
    end
    if isFiniteNumber(values.windGustKmh) then qa:updateProperty("Wind", values.windGustKmh) end
  end

  local rain = tables.forecast10m.rows[1]
  local probability = tables.forecast3h.rows[1] and tables.forecast3h.rows[1].values.precipitationProbabilityPct
  local sunshine = nextHour and nextHour.values.sunshinePercent
  local condition
  if (rain and rain.values.precipitationMm and rain.values.precipitationMm > 0.1)
    or (probability and probability >= 60) then
    condition = "rain"
  elseif sunshine and sunshine >= 70 then condition = "clear"
  elseif sunshine and sunshine >= 30 then condition = "partlyCloudy"
  else condition = "cloudy" end
  local conditionCodes = { clear = 32, rain = 40, partlyCloudy = 30, cloudy = 30 }
  qa:updateProperty("ConditionCode", conditionCodes[condition] or 3200)
  qa:updateProperty("WeatherCondition", condition)
end
