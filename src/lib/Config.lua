-- Config: typed, validated QuickApp variables.
--
-- A schema is a list of fields:
--   { name = "pollIntervalSec", type = "integer", default = 300, min = 30, max = 86400 }
--   { name = "deviceHost", type = "host", required = true }
--   { name = "apiToken", type = "secret" }
--
-- Types: string, secret, integer, number, boolean, enum, host, port, url.
-- Options: required, default, reveal (show value in the log), min, max (integer/number), maxLength
-- (string/secret, default 256), values (enum), schemes (url, default {"https"}).
--
-- Config.load never raises and never puts a raw value into an error message,
-- because values may be secrets.

Config = {}

local DEFAULT_MAX_LENGTH = 256

--- QuickApp variables every QuickApp has (none; projects add App.CONFIG).
Config.COMMON = {}

--- Options every QuickApp has. They are set in App.OPTIONS in the code, not as
-- QuickApp variables; projects add their own fields with App.OPTION_SCHEMA.
Config.OPTIONS = {
  { name = "logLevel", type = "enum", values = Log.LEVEL_NAMES,                    default = "info" },
  { name = "language", type = "enum", values = { "auto", "en", "de", "fr", "it" }, default = "auto" },
}

local function isIPv4(s)
  local a, b, c, d = s:match("^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$")
  if not a then return false end
  for _, part in ipairs({ a, b, c, d }) do
    if tonumber(part) > 255 then return false end
  end
  return true
end

local function isHostname(s)
  if #s > 253 or s:find("^%d+%.%d+%.%d+%.%d+$") then return false end
  for label in (s .. "."):gmatch("([^.]*)%.") do
    if #label == 0 or #label > 63 then return false end
    if not label:find("^[%w][%w-]*$") or label:find("-$") then return false end
  end
  return true
end

local parsers = {}

function parsers.string(raw, field)
  if #raw > (field.maxLength or DEFAULT_MAX_LENGTH) then return nil, "is too long" end
  if field.pattern and not raw:find(field.pattern) then return nil, "has an invalid format" end
  return raw
end

parsers.secret = parsers.string

function parsers.integer(raw, field)
  local n = math.tointeger(tonumber(raw))
  if not n then return nil, "is not a whole number" end
  if (field.min and n < field.min) or (field.max and n > field.max) then
    return nil, "must be between " .. tostring(field.min or "-inf") .. " and " .. tostring(field.max or "inf")
  end
  return n
end

function parsers.number(raw, field)
  local n = tonumber(raw)
  if not n or n ~= n or n == math.huge or n == -math.huge then return nil, "is not a number" end
  if (field.min and n < field.min) or (field.max and n > field.max) then
    return nil, "must be between " .. tostring(field.min or "-inf") .. " and " .. tostring(field.max or "inf")
  end
  return n
end

local BOOLEANS = { ["true"] = true, ["1"] = true, yes = true, on = true,
                   ["false"] = false, ["0"] = false, no = false, off = false }

function parsers.boolean(raw)
  local value = BOOLEANS[raw:lower()]
  if value == nil then return nil, "must be true or false" end
  return value
end

function parsers.enum(raw, field)
  local wanted = raw:lower()
  for _, allowed in ipairs(field.values) do
    if wanted == allowed:lower() then return allowed end
  end
  return nil, "must be one of: " .. Util.join(field.values)
end

function parsers.host(raw)
  if isIPv4(raw) or isHostname(raw) then return raw end
  return nil, "must be an IPv4 address or host name without scheme, port or path"
end

function parsers.port(raw)
  return parsers.integer(raw, { min = 1, max = 65535 })
end

function parsers.url(raw, field)
  local scheme, rest = raw:match("^(%a[%w+.-]*)://([^%s]+)$")
  if not scheme then return nil, "is not a valid URL" end
  scheme = scheme:lower()
  for _, allowed in ipairs(field.schemes or { "https" }) do
    if scheme == allowed then
      if #raw > (field.maxLength or DEFAULT_MAX_LENGTH) then return nil, "is too long" end
      return scheme .. "://" .. rest
    end
  end
  return nil, "must start with " .. Util.join(field.schemes or { "https" }, " or ") .. "://"
end

--- Concatenate schemas; later fields with the same name replace earlier ones.
function Config.merge(...)
  local result, index = {}, {}
  for _, schema in ipairs({ ... }) do
    for _, field in ipairs(schema) do
      if index[field.name] then
        result[index[field.name]] = field
      else
        result[#result + 1] = field
        index[field.name] = #result
      end
    end
  end
  return result
end

--- Parse one raw value against one field. Returns value or nil, reason.
function Config.parse(field, raw)
  local parser = parsers[field.type]
  if not parser then return nil, "has unknown type '" .. tostring(field.type) .. "'" end
  if raw == nil then raw = "" end
  raw = Util.trim(tostring(raw))
  if raw == "" then
    if field.required then return nil, "is required" end
    return field.default
  end
  return parser(raw, field)
end

--- Load all fields through getter(name) -> raw value.
-- Returns cfg (valid values and defaults), errors ({ name, reason }), secrets (raw strings).
function Config.load(schema, getter)
  local cfg, errors, secrets = {}, {}, {}
  for _, field in ipairs(schema) do
    local ok, raw = pcall(getter, field.name)
    if not ok then raw = nil end
    if field.type == "secret" and type(raw) == "string" and raw ~= "" then
      secrets[#secrets + 1] = Util.trim(raw)
    end
    local value, reason = Config.parse(field, raw)
    if reason then
      errors[#errors + 1] = { name = field.name, reason = reason }
      value = field.default
    end
    cfg[field.name] = value
  end
  return cfg, errors, secrets
end

-- Types whose values are safe to show in a public log. Host names, URLs and
-- free text may identify a home; they are shown only with field.reveal = true.
local REVEALED = { integer = true, number = true, boolean = true, enum = true, port = true }

--- One line for the log: "a=5, host=set, token=set, b=INVALID". Never shows secrets.
function Config.describe(schema, cfg, errors)
  local invalid = {}
  for _, e in ipairs(errors or {}) do invalid[e.name] = true end
  local parts = {}
  for _, field in ipairs(schema) do
    local value, text = cfg[field.name], "set"
    if invalid[field.name] then
      text = "INVALID"
    elseif value == nil or value == "" then
      text = "empty"
    elseif field.type ~= "secret" and (REVEALED[field.type] or field.reveal) then
      text = tostring(value)
    end
    parts[#parts + 1] = field.name .. "=" .. text
  end
  return table.concat(parts, ", ")
end

--- Validate options given in code (App.OPTIONS). An invalid value falls back
-- to the field's default; unknown names are reported. Returns the options and
-- a list of problems: { name, value, reason, default }.
function Config.loadOptions(schema, given)
  given = type(given) == "table" and given or {}
  local options, problems, known = {}, {}, {}
  for _, field in ipairs(schema) do
    known[field.name] = true
    local raw = given[field.name]
    local value, reason = Config.parse(field, raw ~= nil and tostring(raw) or nil)
    if reason then
      problems[#problems + 1] = { name = field.name, value = tostring(raw), reason = reason, default = field.default }
      value = field.default
    end
    options[field.name] = value
  end
  local unknown = {}
  for name in pairs(given) do
    if not known[name] then unknown[#unknown + 1] = tostring(name) end
  end
  table.sort(unknown)
  for _, name in ipairs(unknown) do
    problems[#problems + 1] = { name = name, value = tostring(given[name]), reason = "is not a known option" }
  end
  return options, problems
end

--- The HC3 variable type the manifest must declare for a field.
function Config.variableType(field)
  return field.type == "secret" and "password" or "string"
end
