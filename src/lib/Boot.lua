-- Boot: the common start sequence.
--
-- Called from main.lua as  Safe.call("onInit", Boot.run, self, App)  and
--   0. appends the device ID to the log tag if this QuickApp is installed
--      more than once, so each instance can be told apart in the log,
--   1. logs name, version, platform, firmware and device ID,
--   2. validates the options in App.OPTIONS (Config.OPTIONS + App.OPTION_SCHEMA)
--      and applies the log level; an invalid option is logged and replaced by
--      its default,
--   3. loads and validates the QuickApp variables (App.CONFIG), registers
--      secrets for redaction, and logs a summary without addresses or secrets,
--   4. selects the UI language and translates the static UI,
--   5. stops in a visible "not configured" state if anything is invalid,
--   6. otherwise calls App.start(self, cfg, options) protected by Safe.

Boot = {}

local function controllerInfo()
  local ok, data = pcall(api.get, "/settings/info")
  if ok and type(data) == "table" then return data end
  return {}
end

--- Number of other QuickApps of the same type built from the same repository.
function Boot.countSiblings(qa, repository)
  if not (qa.id and repository) then return 0 end
  local ok, devices = pcall(api.get, "/devices?interface=quickApp")
  if not ok or type(devices) ~= "table" then return 0 end
  local count = 0
  for _, device in ipairs(devices) do
    if device.id ~= qa.id and device.type == qa.type then
      local fileOk, file = pcall(api.get, "/quickApp/" .. tostring(device.id) .. "/files/QaInfo")
      if fileOk and type(file) == "table" and type(file.content) == "string"
        and file.content:find(repository, 1, true) then
        count = count + 1
      end
    end
  end
  return count
end

--- Returns true when the app started, false otherwise.
function Boot.run(qa, app)
  local info = QA_INFO or { name = "QuickApp", version = "dev" }
  local siblings = Boot.countSiblings(qa, info.repository)
  local baseTag = info.logTag or __TAG
  __TAG = siblings > 0 and baseTag .. "_" .. tostring(qa.id) or baseTag
  Log.init()
  local controller = controllerInfo()
  Log.info("%s v%s starting on %s firmware %s (device %s%s)", info.name, info.version,
    controller.platform or "unknown platform", controller.softVersion or "unknown", qa.id or "?",
    siblings > 0 and ", " .. (siblings + 1) .. " instances installed" or "")

  local optionSchema = Config.merge(Config.OPTIONS, app.OPTION_SCHEMA or {})
  local options, problems = Config.loadOptions(optionSchema, app.OPTIONS)
  Log.setLevel(options.logLevel)
  for _, p in ipairs(problems) do
    if p.default ~= nil then
      Log.error("App.OPTIONS.%s = %s %s; using %s", p.name, p.value, p.reason, tostring(p.default))
    else
      Log.error("App.OPTIONS.%s %s and is ignored", p.name, p.reason)
    end
  end

  local schema = Config.merge(Config.COMMON, app.CONFIG or {})
  local cfg, errors, secrets = Config.load(schema, function(name) return qa:getVariable(name) end)
  for _, secret in ipairs(secrets) do Log.addSecret(secret) end

  I18n.register(LibStrings)
  I18n.register(app.STRINGS or {})
  I18n.setLanguage(I18n.resolve(options.language, controller.defaultLanguage))
  Log.info("Options: %s", Config.describe(optionSchema, options))
  Log.info("Configuration: %s; UI language %s", Config.describe(schema, cfg, errors), I18n.language())
  Ui.init(qa, app.UI)

  if #errors > 0 then
    local names = {}
    for i, e in ipairs(errors) do
      names[i] = e.name
      Log.error("QuickApp variable '%s' %s", e.name, e.reason)
    end
    Ui.setStatus("lib.status.notConfigured", { names = Util.join(names) })
    Log.warn("Not configured: the QuickApp stays idle until the variables above are fixed")
    return false
  end

  Ui.setStatus("lib.status.starting")
  if not Safe.call("App.start", app.start, qa, cfg, options) then
    Ui.setStatus("lib.status.error")
    return false
  end
  Log.info("Started")
  return true
end
