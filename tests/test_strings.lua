-- Completeness of the translations.

local function placeholders(text)
  local found = {}
  for name in text:gmatch("{([%w_]+)}") do found[name] = true end
  return found
end

local function checkTable(label, tbl)
  for key, texts in pairs(tbl) do
    for _, lang in ipairs(I18n.LANGUAGES) do
      local text = texts[lang]
      ok(type(text) == "string" and text ~= "", label .. ": '" .. key .. "' lacks " .. lang)
      eq(placeholders(text), placeholders(texts.en), label .. ": placeholders of '" .. key .. "' in " .. lang)
    end
    for lang in pairs(texts) do
      ok(lang == "en" or lang == "de" or lang == "fr" or lang == "it",
        label .. ": '" .. key .. "' has unsupported language " .. tostring(lang))
    end
  end
end

test("library strings are complete in every language", function()
  checkTable("LibStrings", LibStrings)
end)

test("project strings are complete in every language", function()
  checkTable("Strings", App.STRINGS or {})
end)

test("German texts follow Swiss spelling (no sharp s)", function()
  for _, tbl in ipairs({ LibStrings, App.STRINGS or {} }) do
    for key, texts in pairs(tbl) do
      ok(not (texts.de or ""):find("ß", 1, true), "'" .. key .. "' uses ß; Swiss German writes ss")
    end
  end
end)
