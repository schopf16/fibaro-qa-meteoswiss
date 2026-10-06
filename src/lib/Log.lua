-- Log: levelled logging with secret redaction, HTML escaping and repeat folding.
--
-- Usage:  Log.info("Polled %s in %s ms", host, elapsed)
--
-- The format string must be a literal from this source code and may only use
-- %s: every argument is converted with tostring, redacted and HTML-escaped
-- before formatting. Log messages are always English.
--
-- The HC3 knows four message types and no "info". The levels map to them as:
--   Log.error -> ERROR, Log.warn -> WARNING, Log.info -> DEBUG, Log.debug -> TRACE
-- Every line carries the QuickApp's tag (__TAG, set from qa.manifest.json
-- before any other code runs), and error lines carry the version as well.

Log = {}

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }
local HC3_TYPES = { error = "error", warn = "warning", info = "debug", debug = "trace" }
local REDACTED = "***"
local MIN_SECRET_LENGTH = 3

local tag = nil
local threshold = LEVELS.info
local secrets = {}
local sink = nil
local last = { key = nil, level = nil, count = 0 }

local function defaultSink(level, logTag, message)
  fibaro[HC3_TYPES[level]](logTag, message)
end

--- Configure the logger. opts.tag (default __TAG), opts.level, opts.sink(level, tag, message).
function Log.init(opts)
  opts = opts or {}
  tag = opts.tag
  sink = opts.sink
  secrets = {}
  threshold = LEVELS.info
  last = { key = nil, level = nil, count = 0 }
  if opts.level then Log.setLevel(opts.level) end
end

--- Set the minimum level ("error", "warn", "info", "debug"). Returns false if unknown.
function Log.setLevel(name)
  local value = LEVELS[name]
  if not value then return false end
  threshold = value
  return true
end

function Log.level()
  for name, value in pairs(LEVELS) do
    if value == threshold then return name end
  end
end

--- Never show `value` in any log line from now on.
function Log.addSecret(value)
  if type(value) ~= "string" or #value < MIN_SECRET_LENGTH then return end
  for _, known in ipairs(secrets) do
    if known == value then return end
  end
  secrets[#secrets + 1] = value
  -- Longest first, so a secret containing another one is redacted as a whole.
  table.sort(secrets, function(a, b) return #a > #b end)
end

--- Replace every registered secret in `text`.
function Log.redact(text)
  text = tostring(text)
  for _, secret in ipairs(secrets) do
    text = Util.replaceAll(text, secret, REDACTED)
  end
  return text
end

local function render(fmt, ...)
  local args = table.pack(...)
  for i = 1, args.n do
    args[i] = Util.escapeHtml(Log.redact(tostring(args[i])))
  end
  local ok, message = pcall(string.format, fmt, table.unpack(args, 1, args.n))
  if not ok then
    -- A broken format string must not hide the message itself.
    message = fmt .. " [" .. Util.join({ table.unpack(args, 1, args.n) }) .. "]"
  end
  return Log.redact(message)
end

local function write(level, message)
  local logTag = tag or __TAG or "QuickApp"
  local ok = pcall(sink or defaultSink, level, logTag, message)
  if not ok and print then print("[" .. level .. "] " .. message) end
end

-- 10, 100, 1000, ...
local function isPowerOfTen(n)
  if n < 10 then return false end
  while n % 10 == 0 do n = n // 10 end
  return n == 1
end

-- Identical consecutive lines are folded so a recurring problem cannot flood
-- the log: the first SHOW_REPEATS occurrences are logged, then only the 10th,
-- 100th, 1000th..., and the total once a different line follows. The first
-- occurrence is always there, so the cause never scrolls away.
local SHOW_REPEATS = 3

local function emit(level, fmt, ...)
  if LEVELS[level] > threshold then return end
  local message = render(fmt, ...)
  if level == "error" and QA_INFO and QA_INFO.version then
    message = message .. " [v" .. QA_INFO.version .. "]"
  end
  local key = level .. "|" .. message
  if key == last.key then
    last.count = last.count + 1
    if last.count <= SHOW_REPEATS then
      write(level, message)
    elseif isPowerOfTen(last.count) then
      write(level, string.format("(%d times so far) %s", last.count, message))
    end
    return
  end
  if last.count > SHOW_REPEATS and not isPowerOfTen(last.count) then
    write(last.level, string.format("(previous message occurred %d times in total)", last.count))
  end
  last = { key = key, level = level, count = 1 }
  write(level, message)
end

function Log.error(fmt, ...) emit("error", fmt, ...) end
function Log.warn(fmt, ...) emit("warn", fmt, ...) end
function Log.info(fmt, ...) emit("info", fmt, ...) end
function Log.debug(fmt, ...) emit("debug", fmt, ...) end

--- Level names in increasing verbosity, for configuration schemas.
Log.LEVEL_NAMES = { "error", "warn", "info", "debug" }
