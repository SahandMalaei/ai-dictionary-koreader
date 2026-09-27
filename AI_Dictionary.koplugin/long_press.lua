local GestureDetector = require("device/gesturedetector")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Actions = require("actions")
local ErrorBoundary = require("error_boundary")

local LongPress = {}
local SETTING = "aidictionary_long_press_action"
local actions = {
  { id = "dictionary", text = _("AI Dictionary"), run = Actions.dictionary },
  { id = "explain", text = _("AI Explain"), run = Actions.explain },
}

local function current_action()
  if G_reader_settings:readSetting("default_highlight_action", "ask") ~= "ask" then
    return nil
  end
  local selected = G_reader_settings:readSetting(SETTING)
  for _, action in ipairs(actions) do
    if selected == action.id then return action end
  end
end

local function clear_action()
  G_reader_settings:delSetting(SETTING)
end

local function select_action(highlight, action)
  -- Keep a valid native fallback if the plugin is disabled or removed.
  -- KOReader still owns selection, timer handling and the single-word override.
  G_reader_settings:saveSetting("default_highlight_action", "ask")
  G_reader_settings:saveSetting(SETTING, action.id)
  if highlight.view and highlight.view.highlight then
    highlight.view.highlight.disabled = false
  end
end

local function add_menu_items(highlight, menu_items)
  local menu = menu_items.long_press
  local items = menu and menu.sub_item_table
  if type(items) ~= "table" then return end

  local insert_at = #items + 1
  for index, item in ipairs(items) do
    if item.aidictionary_long_press then return end
    if item.radio then
      insert_at = index + 1
      local checked = item.checked_func
      if checked then
        item.checked_func = function(...)
          return current_action() == nil and checked(...)
        end
      end
      local callback = item.callback
      if callback then
        item.callback = function(...)
          clear_action()
          return callback(...)
        end
      end
    end
  end

  for offset, action in ipairs(actions) do
    table.insert(items, insert_at + offset - 1, {
      text = action.text,
      radio = true,
      aidictionary_long_press = true,
      help_text = _("To use this action for single words too, disable 'Dictionary on single word selection'."),
      checked_func = function() return current_action() == action end,
      callback = ErrorBoundary.wrap("select AI long-press action", function()
        select_action(highlight, action)
      end),
    })
  end
end

function LongPress.register(plugin)
  local highlight = plugin.ui and plugin.ui.highlight
  if not highlight or not G_reader_settings
      or type(highlight.addToMainMenu) ~= "function"
      or type(highlight.onHoldRelease) ~= "function"
      or type(highlight.onShowHighlightMenu) ~= "function" then
    return false
  end

  highlight._aidictionary_long_press_plugin = plugin
  if highlight._aidictionary_long_press_registered then return true end

  local original_menu = highlight.addToMainMenu
  highlight.addToMainMenu = function(self, menu_items, ...)
    local result = original_menu(self, menu_items, ...)
    ErrorBoundary.call("add AI long-press settings", add_menu_items, self, menu_items)
    return result
  end

  -- Also clear the AI choice when a native action is selected by a gesture.
  local original_set_action = highlight.onSetHighlightAction
  if type(original_set_action) == "function" then
    highlight.onSetHighlightAction = function(self, ...)
      clear_action()
      return original_set_action(self, ...)
    end
  end

  -- Native "ask" normally suppresses this timer. AI actions need the same
  -- very-long-press escape to the popup as the other automatic actions.
  local original_timer = highlight._resetHoldTimer
  if type(original_timer) == "function" then
    highlight._resetHoldTimer = function(self, clear, ...)
      local result = original_timer(self, clear, ...)
      if not clear and current_action() and type(self.long_hold_reached_action) == "function" then
        ErrorBoundary.call("schedule AI long-press escape", function()
          UIManager:unschedule(self.long_hold_reached_action)
          UIManager:scheduleIn(G_reader_settings:readSetting("highlight_long_hold_threshold_s")
            or GestureDetector.LONG_HOLD_INTERVAL_S, self.long_hold_reached_action)
        end)
      end
      return result
    end
  end

  local original_popup = highlight.onShowHighlightMenu
  highlight.onShowHighlightMenu = function(self, ...)
    local action = self._aidictionary_pending_long_press
    local text = self.selected_text and self.selected_text.text
    if action and type(text) == "string" and text:find("%S") then
      -- Consume before dispatch so any subsequent popup uses normal behavior.
      self._aidictionary_pending_long_press = nil
      local _, err = ErrorBoundary.call("run AI long-press action", action.run,
        self._aidictionary_long_press_plugin, self)
      if not err then return true end
    end
    return original_popup(self, ...)
  end

  local original_release = highlight.onHoldRelease
  highlight.onHoldRelease = function(self, ...)
    local action = current_action()
    -- Very-long holds must retain KOReader's escape to the selection popup.
    -- Extended selection and pending clears also belong entirely to KOReader.
    if not action or self.long_hold_reached or self.select_mode or self.clear_id then
      return original_release(self, ...)
    end
    self._aidictionary_pending_long_press = action
    local result, err = ErrorBoundary.call("handle AI long-press release", original_release, self, ...)
    self._aidictionary_pending_long_press = nil
    if err then
      return ErrorBoundary.call("restore highlight popup", original_popup, self)
    end
    return result
  end

  highlight._aidictionary_long_press_registered = true
  return true
end

return LongPress
