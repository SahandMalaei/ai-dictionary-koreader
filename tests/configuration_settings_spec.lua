-- Run from the repository root: luajit tests/configuration_settings_spec.lua
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path
package.loaded.gettext = function(value) return value end
package.loaded.logger = { err = function(err) error(err) end }
local shown
package.loaded["ui/uimanager"] = {
  show = function(_, dialog) shown = dialog end,
  close = function() end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, value) return value end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, value)
  value.getInputText = function(self) return self.input end
  value.onShowKeyboard = function() end
  return value
end }
local Config = require("configuration_manager")
local Settings = require("settings_menu")
local Parameters = require("request_parameters")
local configuration = Config.normalize({ text_model = "existing-model", word_sense_model = "existing-sense" })
Config.load = function() return configuration end
local edited
local plugin = {
  editConfigurationValue = function(_, key, literal) edited = { key = key, literal = literal } end,
  saveConfiguration = function(_, value) configuration = Config.normalize(value); return true end,
}
for _, feature in ipairs(Parameters.FEATURES) do
  local model, effort, custom = feature .. "_model", feature .. "_reasoning_effort", feature .. "_parameters_json"
  assert(configuration[effort] == "" and configuration[custom] == "")
  assert(configuration[model] == (feature == "word_sense" and "existing-sense" or ""))
  for _, invalid in ipairs({ false, {}, 12, " \t ", "bad\nmodel" }) do
    assert(Config.normalize({ [model] = invalid })[model] == "")
  end
  local raw = [[
{
  "provider": {"order": ["google"], "allow_fallbacks": false},
  "stop": ["\n"], "metadata": {}
}
]]
  configuration[custom] = raw
  local saved = assert(loadstring(Config.serialize_configuration(configuration)))()
  assert(saved[custom] == raw and saved.text_model == "existing-model" and saved.word_sense_model == "existing-sense")
  local found_model, found_effort = false, false
  for _, item in ipairs(Settings.get_items(plugin)) do
    assert(item.text ~= "Delete custom setting")
    assert(not item.text:find(custom, 1, true), "config-only JSON appeared in settings")
    if item.text:find(Config.CONFIGURATION_LABELS[model] .. ":", 1, true) == 1 then
      item.callback(); assert(edited.key == model and edited.literal == false); found_model = true
    elseif item.text:find(Config.CONFIGURATION_LABELS[effort] .. ":", 1, true) == 1 then
      local choices = item.sub_item_table
      assert(choices[1].text == "Use provider default" and choices[1].checked_func())
      choices[4].callback(); assert(configuration[effort] == "low" and choices[4].checked_func())
      choices[1].callback(); assert(configuration[effort] == "" and choices[1].checked_func())
      found_effort = true
    end
  end
  assert(found_model and found_effort)
  shown = nil
  Settings.edit_configuration_value(plugin, custom, true)
  Settings.edit_new_configuration_literal(plugin, custom)
  assert(shown == nil)
  assert(configuration[custom] == raw)
end
-- Retired keys in an unnormalized config must not reappear as custom settings.
configuration.word_wise_level, configuration.word_wise_model = "Advanced", "old-model"
configuration.additional_parameters = { temperature = 0.2 }
local found_custom = false
for _, item in ipairs(Settings.get_items(plugin)) do
  assert(not item.text:find("word_wise_", 1, true) and item.text ~= "Delete custom setting")
  if item.text:find("Additional parameters:", 1, true) == 1 then found_custom = true end
end
assert(found_custom, "valid custom settings should remain editable")
print("configuration_settings_spec: upgrade defaults, feature editors, JSON preservation and menu hiding passed")
