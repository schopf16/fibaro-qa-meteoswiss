-- Util: small string helpers shared by the library.

Util = {}

local HTML_ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }

--- Remove leading and trailing whitespace.
function Util.trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Escape text for the HC3 console and UI, which both render HTML.
-- Apply it to every value that did not come from our own source code.
function Util.escapeHtml(s)
  return (tostring(s):gsub('[&<>"]', HTML_ESCAPES))
end

local ASCII = {
  ["ä"] = "ae", ["ö"] = "oe", ["ü"] = "ue", ["Ä"] = "Ae", ["Ö"] = "Oe", ["Ü"] = "Ue", ["ß"] = "ss",
  ["à"] = "a", ["â"] = "a", ["á"] = "a", ["ç"] = "c", ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e",
  ["î"] = "i", ["ï"] = "i", ["ì"] = "i", ["í"] = "i", ["ô"] = "o", ["ò"] = "o", ["ó"] = "o", ["ù"] = "u",
  ["û"] = "u", ["ú"] = "u", ["É"] = "E", ["È"] = "E", ["À"] = "A", ["Ç"] = "C",
  ["…"] = "...", ["–"] = "-", ["—"] = "-", ["·"] = "|", ["«"] = '"', ["»"] = '"', ["“"] = '"', ["”"] = '"',
  ["‘"] = "'", ["’"] = "'", ["°"] = " deg", ["€"] = "EUR", ["\u{A0}"] = " ",
}

--- Replace non-ASCII characters with ASCII look-alikes ("?" if unknown).
function Util.toAscii(s)
  return (tostring(s):gsub("[\xC2-\xF4][\x80-\xBF]*", function(ch) return ASCII[ch] or "?" end))
end

--- Escape Lua pattern magic characters so `s` can be matched literally.
function Util.escapePattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- Replace every literal occurrence of `needle` in `s`.
function Util.replaceAll(s, needle, replacement)
  if needle == "" then return s end
  return (s:gsub(Util.escapePattern(needle), function() return replacement end))
end

--- Join the string form of every list element.
function Util.join(list, separator)
  local parts = {}
  for i, v in ipairs(list) do parts[i] = tostring(v) end
  return table.concat(parts, separator or ", ")
end
