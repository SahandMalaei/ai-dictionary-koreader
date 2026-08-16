local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("plugin_i18n")
local T = _.template

local Config = require("configuration_manager")
local ErrorBoundary = require("error_boundary")
local OutputLanguage = require("output_language")
local Providers = require("providers")
local RequestTimeout = require("request_timeout")

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
    show_message(T(_("Could not save configuration.lua:\n%1"), tostring(err)))
    return false
  end

  show_message(_("AI Dictionary settings saved."))
  return true
end

function SettingsMenu.edit_configuration_value(plugin, key, parse_as_literal)
  local configuration = Config.load()
  local current_value = configuration[key]
  local current_type = type(current_value)
  local label = Config.get_label(key)
  local input_value

  if parse_as_literal or current_type == "table" then
    input_value = Config.serialize_lua_value(current_value)
  else
    input_value = current_value == nil and "" or tostring(current_value)
  end

  local input_dialog
  input_dialog = InputDialog:new {
    title = T(_("Edit %1"), label),
    input = input_value,
    input_type = current_type == "number" and "number" or "text",
    description = (parse_as_literal or current_type == "table") and _("Enter a Lua literal: string, number, boolean, or table.") or nil,
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
                show_message(_("Please enter a valid number."))
                return
              end
            elseif current_type == "boolean" then
              new_value = raw_value == "true" or raw_value == "1"
            elseif parse_as_literal or current_type == "table" then
              local parsed_value, parse_error = Config.parse_lua_literal(raw_value)
              if parsed_value == nil then
                show_message(T(_("Please enter a valid non-nil Lua value.\n%1"), tostring(parse_error or "")))
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
  local value_dialog
  value_dialog = InputDialog:new {
    title = T(_("Set %1"), key),
    input = "\"\"",
    input_type = "text",
    description = _("Enter a Lua literal: string, number, boolean, or table."),
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
              show_message(T(_("Please enter a valid non-nil Lua value.\n%1"), tostring(parse_error or "")))
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
    title = _("Add setting"),
    input = "",
    input_type = "text",
    description = _("Enter a Lua identifier, for example: additional_parameters"),
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
              show_message(_("Setting names must be Lua identifiers."))
              return
            end
            if Config.DEPRECATED_CONFIGURATION_KEYS[key] then
              show_message(_("That setting is no longer used."))
              return
            end
            if Config.CORE_CONFIGURATION_KEY_SET[key] then
              show_message(_("That setting is already available in settings."))
              return
            end

            local configuration = Config.load()
            if configuration[key] ~= nil then
              show_message(_("That setting already exists."))
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

function SettingsMenu.delete_configuration_value(plugin, key)
  local configuration = Config.load()
  configuration[key] = nil
  plugin:saveConfiguration(configuration)
end

local function model_label(model)
  if not model then
    return _("Not set")
  end
  if model.cost == "free" then
    return model.id .. " [" .. _("free") .. "]"
  end
  if model.cost == "paid" then
    return model.id .. " [" .. _("paid") .. "]"
  end
  return model.id
end

function SettingsMenu.select_text_provider(plugin, provider_id)
  local configuration = Config.load()
  Providers.apply_text_provider(configuration, provider_id)
  plugin:saveConfiguration(configuration)
end

function SettingsMenu.select_text_model(plugin, model_id)
  local configuration = Config.load()
  Providers.apply_text_model(configuration, model_id)
  plugin:saveConfiguration(configuration)
end

function SettingsMenu.select_voice_model(plugin, model_id)
  local configuration = Config.load()
  Providers.apply_voice_model(configuration, model_id)
  plugin:saveConfiguration(configuration)
end

function SettingsMenu.select_output_language(plugin, mode)
  OutputLanguage.set_mode(mode)
end

function SettingsMenu.edit_request_timeout(plugin)
  local current_seconds = RequestTimeout.get_seconds()
  local input_dialog
  input_dialog = InputDialog:new {
    title = _("Request timeout"),
    input = tostring(current_seconds),
    input_type = "number",
    description = T(_("How long to wait for an AI reply before asking whether to keep waiting (%1–%2 seconds)."),
      RequestTimeout.MIN_SECONDS, RequestTimeout.MAX_SECONDS),
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
          callback = ErrorBoundary.wrap("save request timeout", function()
            local seconds = tonumber(input_dialog:getInputText())
            if not seconds then
              show_message(_("Please enter a valid number."))
              return
            end
            seconds = math.floor(seconds + 0.5)
            if seconds < RequestTimeout.MIN_SECONDS or seconds > RequestTimeout.MAX_SECONDS then
              show_message(T(_("Please enter a whole number of seconds between %1 and %2."),
                RequestTimeout.MIN_SECONDS, RequestTimeout.MAX_SECONDS))
              return
            end
            RequestTimeout.set_seconds(seconds)
            UIManager:close(input_dialog)
            show_message(_("AI Dictionary settings saved."))
          end),
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

function SettingsMenu.provider_menu_items(plugin)
  local items = {}

  for index, provider in ipairs(Providers.list_text()) do
    local provider_id = provider.id
    table.insert(items, {
      text = _(provider.label),
      keep_menu_open = true,
      checked_func = ErrorBoundary.wrap("read provider selection", function()
        return Providers.detect_text(Config.load().text_endpoint).id == provider_id
      end),
      callback = ErrorBoundary.wrap("select provider", function()
        plugin:selectTextProvider(provider_id)
      end),
    })
  end

  return items
end

function SettingsMenu.text_model_menu_items(plugin)
  local configuration = Config.load()
  local provider = Providers.detect_text(configuration.text_endpoint)
  local items = {}

  for index, model in ipairs(provider.models or {}) do
    local model_id = model.id
    table.insert(items, {
      text = model_label(model),
      keep_menu_open = true,
      checked_func = ErrorBoundary.wrap("read text model selection", function()
        return Config.load().text_model == model_id
      end),
      callback = ErrorBoundary.wrap("select text model", function()
        plugin:selectTextModel(model_id)
      end),
    })
  end

  table.insert(items, {
    text = _("Custom model…"),
    checked_func = ErrorBoundary.wrap("read custom text model", function()
      local selected = Config.load().text_model
      if not selected then
        return false
      end
      for index, model in ipairs(provider.models or {}) do
        if model.id == selected then
          return false
        end
      end
      return true
    end),
    callback = ErrorBoundary.wrap("edit custom text model", function()
      plugin:editConfigurationValue("text_model")
    end),
  })

  return items
end

function SettingsMenu.voice_model_menu_items(plugin)
  local configuration = Config.load()
  local provider = Providers.detect_voice(configuration.voice_endpoint)
  local items = {}

  if provider then
    for index, model in ipairs(provider.models or {}) do
      local model_id = model.id
      table.insert(items, {
        text = model_id,
        keep_menu_open = true,
        checked_func = ErrorBoundary.wrap("read voice model selection", function()
          return Config.load().voice_model == model_id
        end),
        callback = ErrorBoundary.wrap("select voice model", function()
          plugin:selectVoiceModel(model_id)
        end),
      })
    end
  end

  table.insert(items, {
    text = _("Custom model…"),
    callback = ErrorBoundary.wrap("edit custom voice model", function()
      plugin:editConfigurationValue("voice_model")
    end),
  })

  return items
end

function SettingsMenu.output_language_menu_items(plugin)
  local items = {
    {
      text = _("Automatic (follow system)"),
      keep_menu_open = true,
      checked_func = ErrorBoundary.wrap("read output language auto", function()
        return OutputLanguage.get_mode() == "auto"
      end),
      callback = ErrorBoundary.wrap("select output language auto", function()
        plugin:selectOutputLanguage("auto")
      end),
    },
    {
      text = _("Automatic (follow book)"),
      keep_menu_open = true,
      checked_func = ErrorBoundary.wrap("read output language book", function()
        return OutputLanguage.get_mode() == "book"
      end),
      callback = ErrorBoundary.wrap("select output language book", function()
        plugin:selectOutputLanguage("book")
      end),
      separator = true,
    },
  }

  for index, language in ipairs(OutputLanguage.LANGUAGES) do
    local language_id = language.id
    table.insert(items, {
      text = language.native_name,
      keep_menu_open = true,
      checked_func = ErrorBoundary.wrap("read output language", function()
        return OutputLanguage.get_mode() == language_id
      end),
      callback = ErrorBoundary.wrap("select output language", function()
        plugin:selectOutputLanguage(language_id)
      end),
    })
  end

  return items
end

function SettingsMenu.get_items(plugin)
  local configuration = Config.load()
  local items = {}
  local written = {}

  local function add_value_item(key)
    local value = configuration[key]
    local label = Config.get_label(key)
    written[key] = true

    if type(value) == "boolean" or Config.BOOLEAN_CONFIGURATION_KEYS[key] then
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

  for index, key in ipairs(Config.CORE_CONFIGURATION_KEYS) do
    if key == "text_endpoint" then
      local provider = Providers.detect_text(configuration.text_endpoint)
      table.insert(items, {
        text = _("Provider") .. ": " .. _(provider.label),
        sub_item_table_func = ErrorBoundary.wrap("build provider menu", function()
          return SettingsMenu.provider_menu_items(plugin)
        end),
      })
      add_value_item(key)
    elseif key == "text_model" then
      table.insert(items, {
        text = _("Text model") .. ": " .. Config.display_value("text_model", configuration.text_model),
        sub_item_table_func = ErrorBoundary.wrap("build text model menu", function()
          return SettingsMenu.text_model_menu_items(plugin)
        end),
      })
      written[key] = true
      table.insert(items, {
        text = _("Output language") .. ": " .. OutputLanguage.display_label(plugin),
        sub_item_table_func = ErrorBoundary.wrap("build output language menu", function()
          return SettingsMenu.output_language_menu_items(plugin)
        end),
      })
      table.insert(items, {
        text = T(_("Request timeout: %1 s"), RequestTimeout.get_seconds()),
        callback = ErrorBoundary.wrap("edit request timeout", function()
          plugin:editRequestTimeout()
        end),
      })
    elseif key == "voice_model" then
      table.insert(items, {
        text = _("Voice model") .. ": " .. Config.display_value("voice_model", configuration.voice_model),
        sub_item_table_func = ErrorBoundary.wrap("build voice model menu", function()
          return SettingsMenu.voice_model_menu_items(plugin)
        end),
      })
      written[key] = true
    else
      add_value_item(key)
    end
    if key == "update_check" then
      table.insert(items, {
        text = _("Check for updates now"),
        callback = ErrorBoundary.wrap("manual update check", function()
          plugin:checkForUpdates()
        end),
      })
    end
  end

  local custom_keys = {}
  for key in pairs(configuration) do
    if not written[key]
        and not Config.DEPRECATED_CONFIGURATION_KEYS[key]
        and not Config.CORE_CONFIGURATION_KEY_SET[key] then
      table.insert(custom_keys, key)
    end
  end
  table.sort(custom_keys, function(a, b) return tostring(a) < tostring(b) end)

  for index, key in ipairs(custom_keys) do
    add_value_item(key)
  end

  local delete_items = {}
  for index, key in ipairs(custom_keys) do
    if not Config.CORE_CONFIGURATION_KEY_SET[key] then
      table.insert(delete_items, {
        text = tostring(key),
        callback = ErrorBoundary.wrap("delete custom setting", function()
          plugin:deleteConfigurationValue(key)
        end),
      })
    end
  end

  if #delete_items > 0 then
    table.insert(items, {
      text = _("Delete custom setting"),
      sub_item_table = delete_items,
    })
  end

  return items
end

return SettingsMenu
