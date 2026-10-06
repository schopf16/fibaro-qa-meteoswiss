-- Consistency between qa.manifest.json and the code.
-- MANIFEST is the parsed qa.manifest.json, provided by tools/run_tests.py.

local function schema()
  return Config.merge(Config.COMMON, App.CONFIG or {})
end

local function manifestVariables()
  local byName = {}
  for _, v in ipairs(MANIFEST.quickAppVariables or {}) do byName[v.name] = v end
  return byName
end

test("every config field has a manifest variable of the right type", function()
  local vars = manifestVariables()
  for _, field in ipairs(schema()) do
    local v = vars[field.name]
    ok(v, "qa.manifest.json lacks variable '" .. field.name .. "'")
    eq(v.type, Config.variableType(field), "type of variable '" .. field.name .. "'")
  end
end)

test("every manifest variable belongs to the config schema", function()
  local known = {}
  for _, field in ipairs(schema()) do known[field.name] = true end
  for _, v in ipairs(MANIFEST.quickAppVariables or {}) do
    ok(known[v.name], "variable '" .. v.name .. "' is not in Config.COMMON or App.CONFIG")
  end
end)

test("shipped defaults are valid and secrets ship empty", function()
  local vars = manifestVariables()
  for _, field in ipairs(schema()) do
    local raw = vars[field.name] and vars[field.name].value or ""
    if field.type == "secret" then
      eq(raw, "", "secret '" .. field.name .. "' must ship empty")
    elseif raw ~= "" then
      local _, reason = Config.parse(field, raw)
      ok(not reason, "default of '" .. field.name .. "' " .. tostring(reason))
    end
  end
end)

test("UI texts refer to existing elements and strings", function()
  local elements = {}
  for _, row in ipairs(MANIFEST.ui or {}) do
    for _, element in ipairs(row) do elements[element.id] = element end
  end
  local ui = App.UI or {}
  for id, key in pairs(ui.text or {}) do
    ok(elements[id], "App.UI.text refers to unknown element '" .. id .. "'")
    ok((App.STRINGS or {})[key] or LibStrings[key], "App.UI.text refers to unknown string '" .. key .. "'")
  end
  if ui.statusLabel then
    ok(elements[ui.statusLabel] and elements[ui.statusLabel].type == "label",
      "App.UI.statusLabel must be a label in the manifest")
  end
end)
