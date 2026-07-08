local InputContainer = require("ui/widget/container/inputcontainer")

local Actions = require("actions")
local Context = require("context")
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
  return QuerySession.query(self, reader_highlight_instance, dialog_title, preface_with_selection, query, request_parameters)
end

function Benedict:Regenerate(chatgpt_viewer)
  return QuerySession.regenerate(self, chatgpt_viewer)
end

function Benedict:getCurrentChapterName()
  return Context.get_current_chapter_name(self)
end

function Benedict:createDictionaryTTSRequest(text, context)
  return TTS.create_request(text, context, self.path)
end

function Benedict:markDictionaryTextQueryFinished(tts_request)
  return TTS.mark_text_query_finished(tts_request)
end

function Benedict:startDictionaryTTSRequest(tts_request, play_when_ready)
  return TTS.start_request(tts_request, play_when_ready)
end

function Benedict:playDictionaryPronunciation(tts_request)
  return TTS.play(tts_request)
end

function Benedict:showLookupsReportRequestDialog(selected_index)
  return LookupsReportUI.show_request_dialog(self, selected_index)
end

function Benedict:showLookupsReportTimeframeDialog(selected_index)
  return LookupsReportUI.show_timeframe_dialog(self, selected_index)
end

function Benedict:generateLookupsReport(timeframe)
  return LookupsReportUI.generate(self, timeframe)
end

function Benedict:getSettingsMenuItems()
  return SettingsMenu.get_items(self)
end

function Benedict:saveConfiguration(configuration)
  return SettingsMenu.save_configuration(self, configuration)
end

function Benedict:editConfigurationValue(key, parse_as_literal)
  return SettingsMenu.edit_configuration_value(self, key, parse_as_literal)
end

function Benedict:addConfigurationValue()
  return SettingsMenu.add_configuration_value(self)
end

function Benedict:editNewConfigurationLiteral(key)
  return SettingsMenu.edit_new_configuration_literal(self, key)
end

function Benedict:deleteConfigurationValue(key)
  return SettingsMenu.delete_configuration_value(self, key)
end

function Benedict:addToMainMenu(menu_items)
  menu_items.ai_dictionary_lookups_report = {
    text = "AI Dictionary Lookups Report",
    sorting_hint = "search",
    callback = function()
      self:showLookupsReportRequestDialog()
    end,
  }
  menu_items.ai_dictionary_settings = {
    text = "AI Dictionary settings",
    sorting_hint = "more_tools",
    sub_item_table_func = function()
      return self:getSettingsMenuItems()
    end,
  }
end

function Benedict:init()
  TTS.cleanup(self.path)

  if self.ui and self.ui.menu then
    self.ui.menu:registerToMainMenu(self)
  end

  self.updater = Updater:new(self)
  if Config.is_update_check_enabled() then
    self.updater:checkOnStartup()
  end

  if self.ui and self.ui.highlight then
    Actions.register(self)
  end
end

return Benedict
