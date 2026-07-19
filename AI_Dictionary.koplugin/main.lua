local InputContainer = require("ui/widget/container/inputcontainer")

local Actions = require("actions")
local Context = require("context")
local ErrorBoundary = require("error_boundary")
local Config = require("configuration_manager")
local LookupsReportUI = require("lookups_report_ui")
local QuerySession = require("query_session")
local SettingsMenu = require("settings_menu")
local TTS = require("tts")
local Updater = require("updater")

local Benedict = InputContainer:new {
  name = "benedict",
  is_doc_only = true,
}

function Benedict:Query(reader_highlight_instance, dialog_title, preface_with_selection, query, request_parameters)
  return ErrorBoundary.call("query", QuerySession.query,
    self, reader_highlight_instance, dialog_title, preface_with_selection, query, request_parameters)
end

function Benedict:Regenerate(chatgpt_viewer)
  return ErrorBoundary.call("regenerate", QuerySession.regenerate, self, chatgpt_viewer)
end

function Benedict:getCurrentChapterName()
  return ErrorBoundary.call("get current chapter", Context.get_current_chapter_name, self)
end

function Benedict:createDictionaryTTSRequest(text, context)
  return ErrorBoundary.call("create TTS request", TTS.create_request, text, context, self.path)
end

function Benedict:markDictionaryTextQueryFinished(tts_request)
  return ErrorBoundary.call("finish TTS text query", TTS.mark_text_query_finished, tts_request)
end

function Benedict:startDictionaryTTSRequest(tts_request, play_when_ready)
  return ErrorBoundary.call("start TTS request", TTS.start_request, tts_request, play_when_ready)
end

function Benedict:playDictionaryPronunciation(tts_request)
  return ErrorBoundary.call("play pronunciation", TTS.play, tts_request)
end

function Benedict:showLookupsReportRequestDialog(selected_index)
  return ErrorBoundary.call("show lookups report dialog", LookupsReportUI.show_request_dialog, self, selected_index)
end

function Benedict:showLookupsReportTimeframeDialog(selected_index)
  return ErrorBoundary.call("show report timeframe dialog", LookupsReportUI.show_timeframe_dialog, self, selected_index)
end

function Benedict:generateLookupsReport(timeframe)
  return ErrorBoundary.call("generate lookups report", LookupsReportUI.generate, self, timeframe)
end

function Benedict:getSettingsMenuItems()
  return ErrorBoundary.call("build settings menu", SettingsMenu.get_items, self)
end

function Benedict:saveConfiguration(configuration)
  return ErrorBoundary.call("save configuration", SettingsMenu.save_configuration, self, configuration)
end

function Benedict:editConfigurationValue(key, parse_as_literal)
  return ErrorBoundary.call("edit configuration", SettingsMenu.edit_configuration_value, self, key, parse_as_literal)
end

function Benedict:addConfigurationValue()
  return ErrorBoundary.call("add configuration value", SettingsMenu.add_configuration_value, self)
end

function Benedict:editNewConfigurationLiteral(key)
  return ErrorBoundary.call("edit new configuration value", SettingsMenu.edit_new_configuration_literal, self, key)
end

function Benedict:deleteConfigurationValue(key)
  return ErrorBoundary.call("delete configuration value", SettingsMenu.delete_configuration_value, self, key)
end

function Benedict:addToMainMenu(menu_items)
  return ErrorBoundary.call("build main menu", function()
    menu_items.ai_dictionary_lookups_report = {
      text = "AI Dictionary Lookups Report",
      sorting_hint = "search",
      callback = ErrorBoundary.wrap("open lookups report", function()
        self:showLookupsReportRequestDialog()
      end),
    }
    menu_items.ai_dictionary_settings = {
      text = "AI Dictionary settings",
      sorting_hint = "more_tools",
      sub_item_table_func = function()
        return self:getSettingsMenuItems()
      end,
    }
  end)
end

function Benedict:init()
  ErrorBoundary.call("startup TTS cleanup", TTS.cleanup, self.path)

  if self.ui and self.ui.menu then
    ErrorBoundary.call("main menu registration", function()
      self.ui.menu:registerToMainMenu(self)
    end)
  end

  ErrorBoundary.call("updater setup", function()
    self.updater = Updater:new(self)
    if Config.is_update_check_enabled() then
      self.updater:checkOnStartup()
    end
  end)

  if self.ui and self.ui.highlight then
    ErrorBoundary.call("highlight action registration", Actions.register, self)
  end
end

return Benedict
