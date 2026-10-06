-- Ui: translated labels, buttons and the status line under the device tile.
--
-- The UI spec comes from App.UI:
--   App.UI = {
--     text = { btnRefresh = "ui.refresh" },   -- element id -> string key, set on start
--     statusLabel = "lblStatus",              -- optional label mirroring the status line
--   }

Ui = {}

local qa = nil
local statusLabel = nil

local function safeUpdateView(id, property, value)
  local ok, err = pcall(qa.updateView, qa, id, property, value)
  if not ok then Log.warn("Cannot update UI element '%s': %s", id, err) end
end

--- Bind to the QuickApp and translate every static element.
function Ui.init(quickApp, spec)
  qa = quickApp
  spec = spec or {}
  statusLabel = spec.statusLabel
  for id, key in pairs(spec.text or {}) do
    safeUpdateView(id, "text", I18n.t(key))
  end
end

--- Set the translated text of one element.
function Ui.setText(id, key, params)
  if qa then safeUpdateView(id, "text", I18n.t(key, params)) end
end

--- Show a translated status in the device's log line and the status label.
-- The HC3 keeps only one byte per character in the log line ("ü" becomes
-- invalid UTF-8, "…" becomes "&"), so it gets ASCII; the label shows the
-- full text.
function Ui.setStatus(key, params)
  if not qa then return end
  local text = I18n.t(key, params)
  local ok, err = pcall(qa.updateProperty, qa, "log", Util.toAscii(text))
  if not ok then Log.warn("Cannot update status line: %s", err) end
  if statusLabel then safeUpdateView(statusLabel, "text", text) end
end
