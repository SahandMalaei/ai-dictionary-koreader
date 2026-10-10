local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Config = require("configuration_manager")
local ErrorBoundary = require("error_boundary")
local Parameters = require("request_parameters")

local SettingsMenu = {}

local function show_message(text)
  UIManager:show(InfoMessage:new {
    text = text,
    timeout = 3,
  })
end

function SettingsMenu.save_configuration(plugin, configuration)
  local ok, err = Config.save(plugin, configuration)
  if not ok then
    show_message("Could not save configuration.lua:\n" .. tostring(err))
    return false
  end

  show_message("AI Dictionary settings saved.")
  return true
end

function SettingsMenu.edit_configuration_value(plugin, key, parse_as_literal)
  if Config.CONFIG_ONLY_CONFIGURATION_KEYS[key] then return end
  local configuration = Config.load()
  local current_value = configuration[key]
  local current_type = type(current_value)
  local label = Config.CONFIGURATION_LABELS[key] or tostring(key)
  local input_value

  if parse_as_literal or current_type == "table" then
    input_value = Config.serialize_lua_value(current_value)
  else
    input_value = current_value == nil and "" or tostring(current_value)
  end

  local input_dialog
  input_dialog = InputDialog:new {
    title = "Edit " .. label,
    input = input_value,
    input_type = current_type == "number" and "number" or "text",
    description = (key == "word_sense_model" or key == "dictionary_model" or key == "explain_model")
      and "Leave blank to use Default text model. Uses the same text endpoint and API key."
      or ((parse_as_literal or current_type == "table") and "Enter a Lua literal: string, number, boolean, or table." or nil),
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(input_dialog)
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = ErrorBoundary.wrap("save edited setting", function()
            local raw_value = input_dialog:getInputText()
            local new_value = raw_value

            if current_type == "number" then
              new_value = tonumber(raw_value)
              if new_value == nil then
                show_message("Please enter a valid number.")
                return
              end
            elseif current_type == "boolean" then
              new_value = raw_value == "true" or raw_value == "1"
            elseif parse_as_literal or current_type == "table" then
              local parsed_value, parse_error = Config.parse_lua_literal(raw_value)
              if parsed_value == nil then
                show_message("Please enter a valid non-nil Lua value.\n" .. tostring(parse_error or ""))
                return
              end
              new_value = parsed_value
            end

            configuration[key] = new_value
            if plugin:saveConfiguration(configuration) then
              UIManager:close(input_dialog)
            end
          end),
        },
      },
    },
  }

  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

function SettingsMenu.edit_new_configuration_literal(plugin, key)
  if Config.CONFIG_ONLY_CONFIGURATION_KEYS[key] then return end
  local value_dialog
  value_dialog = InputDialog:new {
    title = "Set " .. key,
    input = "\"\"",
    input_type = "text",
    description = "Enter a Lua literal: string, number, boolean, or table.",
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(value_dialog)
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = ErrorBoundary.wrap("save new setting value", function()
            local value, parse_error = Config.parse_lua_literal(value_dialog:getInputText())
            if value == nil then
              show_message("Please enter a valid non-nil Lua value.\n" .. tostring(parse_error or ""))
              return
            end

            local configuration = Config.load()
            configuration[key] = value
            if plugin:saveConfiguration(configuration) then
              UIManager:close(value_dialog)
            end
          end),
        },
      },
    },
  }

  UIManager:show(value_dialog)
  value_dialog:onShowKeyboard()
end

function SettingsMenu.add_configuration_value(plugin)
  local key_dialog
  key_dialog = InputDialog:new {
    title = "Add setting",
    input = "",
    input_type = "text",
    description = "Enter a Lua identifier, for example: additional_parameters",
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(key_dialog)
          end,
        },
        {
          text = _("Next"),
          is_enter_default = true,
          callback = ErrorBoundary.wrap("continue adding setting", function()
            local key = key_dialog:getInputText()
            if not Config.is_lua_identifier(key) then
              show_message("Setting names must be Lua identifiers.")
              return
            end
            if Config.DEPRECATED_CONFIGURATION_KEYS[key] then
              show_message("That setting is no longer used.")
              return
            end
            if Config.CONFIG_ONLY_CONFIGURATION_KEYS[key] then
              show_message("Edit that setting in configuration.lua.")
              return
            end
            if Config.CORE_CONFIGURATION_KEY_SET[key] then
              show_message("That setting is already available in settings.")
              return
            end

            local configuration = Config.load()
            if configuration[key] ~= nil then
              show_message("That setting already exists.")
              return
            end

            UIManager:close(key_dialog)
            plugin:editNewConfigurationLiteral(key)
          end),
        },
      },
    },
  }

  UIManager:show(key_dialog)
  key_dialog:onShowKeyboard()
end

function SettingsMenu.get_items(plugin)
  local configuration = Config.load()
  local items = {
    {
      text = "Check for updates now",
      callback = ErrorBoundary.wrap("manual update check", function()
        plugin:checkForUpdates()
      end),
    },
  }
  local written = {}

  local function add_value_item(key)
    local value = configuration[key]
    local label = Config.CONFIGURATION_LABELS[key] or tostring(key)
    written[key] = true

    if type(key) == "string" and key:match("_reasoning_effort$") then
      local choices = {}
      for _, effort in ipairs(Parameters.EFFORTS) do
        choices[#choices + 1] = {
          text = effort == "" and "Use provider default" or effort,
          radio = true,
          checked_func = function() return Config.load()[key] == effort end,
          callback = ErrorBoundary.wrap("set reasoning effort", function()
            local updated_configuration = Config.load()
            updated_configuration[key] = effort
            plugin:saveConfiguration(updated_configuration)
          end),
        }
      end
      table.insert(items, {
        text = label .. ": " .. Config.display_value(key, value),
        text_func = function() return label .. ": " .. Config.display_value(key, Config.load()[key]) end,
        help_text = "Use provider default sends no automatic reasoning parameters. Supported effort levels depend on the model. Unknown endpoints use custom JSON in configuration.lua.",
        sub_item_table = choices,
      })
    elseif key == "word_sense_level" then
      local choices = {}
      for _, level in ipairs({ "Basic", "Intermediate", "Advanced" }) do
        choices[#choices + 1] = {
          text = level,
          radio = true,
          checked_func = function() return Config.load().word_sense_level == level end,
          callback = ErrorBoundary.wrap("set Word Sense reading level", function()
            local updated_configuration = Config.load()
            updated_configuration.word_sense_level = level
            plugin:saveConfiguration(updated_configuration)
          end),
        }
      end
      table.insert(items, {
        text = label .. ": " .. value,
        text_func = function() return label .. ": " .. Config.load().word_sense_level end,
        help_text = "Your reading level. Basic gives the most vocabulary help; Advanced marks only difficult words and expressions.",
        sub_item_table = choices,
      })
    elseif type(value) == "boolean" or Config.BOOLEAN_CONFIGURATION_KEYS[key] then
      table.insert(items, {
        text = label,
        checked_func = ErrorBoundary.wrap("read boolean setting", function() return Config.load()[key] == true end),
        callback = ErrorBoundary.wrap("toggle boolean setting", function()
          local updated_configuration = Config.load()
          updated_configuration[key] = not updated_configuration[key]
          plugin:saveConfiguration(updated_configuration)
        end),
      })
    else
      table.insert(items, {
        text = label .. ": " .. Config.display_value(key, value),
        callback = ErrorBoundary.wrap("open setting editor", function()
          plugin:editConfigurationValue(key, not Config.CORE_CONFIGURATION_KEY_SET[key])
        end),
      })
    end
  end

  for _, key in ipairs(Config.CORE_CONFIGURATION_KEYS) do
    add_value_item(key)
  end

  local custom_keys = {}
  for key, _ in pairs(configuration) do
    if not written[key] and not Config.DEPRECATED_CONFIGURATION_KEYS[key]
        and not Config.CONFIG_ONLY_CONFIGURATION_KEYS[key] then
      table.insert(custom_keys, key)
    end
  end
  table.sort(custom_keys, function(a, b) return tostring(a) < tostring(b) end)

  for _, key in ipairs(custom_keys) do
    add_value_item(key)
  end

  return items
end

return SettingsMenu
