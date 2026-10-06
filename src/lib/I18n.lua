-- I18n: user-visible strings in English, German, French and Italian.
--
-- String tables map a key to one text per language:
--   Strings = { ["status.ok"] = { en = "Updated at {time}", de = "...", fr = "...", it = "..." } }
--
-- Placeholders {name} are filled from a params table; their values are
-- HTML-escaped because the HC3 renders labels and log lines as HTML.
-- Log messages are never translated.

I18n = {}

I18n.LANGUAGES = { "en", "de", "fr", "it" }
I18n.DEFAULT = "en"

local supported = {}
for _, code in ipairs(I18n.LANGUAGES) do supported[code] = true end

local strings = {}
local current = I18n.DEFAULT

--- Add a string table; later registrations override earlier keys.
function I18n.register(tbl)
  for key, texts in pairs(tbl or {}) do strings[key] = texts end
end

--- Pick the language: an explicit setting wins, then the controller language, then English.
function I18n.resolve(setting, controllerLanguage)
  setting = type(setting) == "string" and setting:lower() or ""
  if supported[setting] then return setting end
  local code = type(controllerLanguage) == "string" and controllerLanguage:sub(1, 2):lower() or ""
  if supported[code] then return code end
  return I18n.DEFAULT
end

function I18n.setLanguage(code)
  current = supported[code] and code or I18n.DEFAULT
end

function I18n.language()
  return current
end

--- Translate `key`, falling back to English and finally to the key itself.
function I18n.t(key, params)
  local texts = strings[key]
  local text = texts and (texts[current] or texts[I18n.DEFAULT]) or key
  return (text:gsub("{([%w_]+)}", function(name)
    local value = params and params[name]
    if value == nil then return "{" .. name .. "}" end
    return Util.escapeHtml(value)
  end))
end

--- All registered keys, sorted (used by the tests).
function I18n.keys()
  local keys = {}
  for key in pairs(strings) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

--- The raw text table for `key` (used by the tests).
function I18n.entry(key)
  return strings[key]
end
