-- Children: four fixed boolean forecast signals for scene triggers.

local MANAGED_KEY = "meteoSwissChildren"
local VALUE_KEY = "meteoSwissChildValues"
local CHILD_ORDER = { "rainExpected", "strongWindExpected", "niceWeather", "niceWeatherTomorrow" }
local qa = nil
local active = {}

local function readKey(child)
  local ok, value = pcall(child.getVariable, child, "key")
  if ok and type(value) == "string" then return value end
  return ""
end

-- A table from internal storage, or an empty table if it is missing or unreadable.
local function stored(key)
  local ok, value = pcall(qa.internalStorageGet, qa, key)
  if ok and type(value) == "table" then return value end
  return {}
end

local function childIds()
  local result = {}
  for id, child in pairs(qa.childDevices or {}) do result[tostring(id)] = child end
  return result
end

local function create(name, definition)
  local childName = I18n.t(definition.labelKey)
  local child = qa:createChildDevice({
    name = childName,
    type = "com.fibaro.binarySensor",
  }, QuickAppChild)
  child:setVariable("key", name)
  child:updateProperty("value", false)
  return child
end

--- Create the four signal children once; reuse them by stored ID or by their
-- key variable after a restart. A child deleted by hand is created again at
-- the next start.
function App.Children.sync(quickApp)
  qa, active = quickApp, {}
  qa:initChildDevices({ ["com.fibaro.binarySensor"] = QuickAppChild })

  local definitions = App.childCatalog()
  local mapping = stored(MANAGED_KEY)
  local values = stored(VALUE_KEY)
  local existing = childIds()
  local byKey = {}
  for _, child in pairs(existing) do
    local key = readKey(child)
    if definitions[key] then byKey[key] = child end
  end

  for _, name in ipairs(CHILD_ORDER) do
    local child = existing[tostring(mapping[name] or "")] or byKey[name]
    if not child then
      local ok, result = pcall(create, name, definitions[name])
      if ok then
        child = result
        values[name] = false
        Log.info("Created child for signal '%s'", name)
      else
        Log.error("Cannot create child for signal '%s': %s", name, tostring(result))
      end
    end
    if child then
      mapping[name] = child.id
      active[name] = child
    end
  end

  qa:internalStorageSet(MANAGED_KEY, mapping)
  qa:internalStorageSet(VALUE_KEY, values)
end

function App.Children.update(tables)
  if not qa then return end
  local wantedValues = App.childValuesFrom(tables)
  local current = stored(VALUE_KEY)
  local existing = childIds()
  local changed = false
  for name, child in pairs(active) do
    if existing[tostring(child.id)] and wantedValues[name] ~= nil and current[name] ~= wantedValues[name] then
      child:updateProperty("value", wantedValues[name])
      current[name] = wantedValues[name]
      changed = true
      Log.info("Signal '%s' changed to %s", name, tostring(wantedValues[name]))
    end
  end
  if changed then qa:internalStorageSet(VALUE_KEY, current) end
end
