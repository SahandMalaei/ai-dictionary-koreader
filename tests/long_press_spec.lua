-- Run from the repository root: luajit tests/long_press_spec.lua
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path

local requests, errors, scheduled = {}, {}, {}
local native_popups, native_dictionaries, native_highlights = 0, 0, 0
local clipboard = true
package.loaded.device = { hasClipboard = function() return clipboard end }
package.loaded.gettext = function(text) return text end
package.loaded.logger = { err = function(err) errors[#errors + 1] = err end }
package.loaded["device/gesturedetector"] = { LONG_HOLD_INTERVAL_S = 3 }
package.loaded["ui/uimanager"] = {
  scheduleIn = function(_, delay, callback)
    assert(not scheduled[callback], "duplicate hold timer")
    scheduled[callback] = delay
  end,
  unschedule = function(_, callback) scheduled[callback] = nil end,
}
local UI = package.loaded["ui/uimanager"]

G_reader_settings = { data = {} }
function G_reader_settings:readSetting(key, default)
  local value = self.data[key]
  if value == nil then return default end
  return value
end
function G_reader_settings:saveSetting(key, value) self.data[key] = value end
function G_reader_settings:delSetting(key) self.data[key] = nil end
function G_reader_settings:isTrue(key) return self.data[key] == true end

local Actions = require("actions")
local LongPress = require("long_press")
local native_actions = {
  { "Ask with popup dialog", "ask" },
  { "Do nothing", "nothing" },
  { "Highlight", "highlight" },
}

-- Model KOReader's routing contract; only the adapter and real plugin action
-- functions are under test. Touch input and document rendering need device QA.
local function new_plugin()
  local highlight = { view = { highlight = {} }, buttons = {} }
  function highlight:addToHighlightDialog(id, builder) self.buttons[id] = builder end
  function highlight:onSetHighlightAction(index)
    local id = native_actions[index][2]
    G_reader_settings:saveSetting("default_highlight_action", id)
    self.view.highlight.disabled = id == "nothing"
    return true
  end
  function highlight:addToMainMenu(items)
    local choices = { { text = "Dictionary on single word selection" } }
    for index, action in ipairs(native_actions) do
      choices[#choices + 1] = {
        text = action[1], radio = true,
        checked_func = function()
          return G_reader_settings:readSetting("default_highlight_action", "ask") == action[2]
        end,
        callback = function() self:onSetHighlightAction(index) end,
      }
    end
    choices[#choices + 1] = { text = "Highlight dialog position", sub_item_table = {} }
    items.long_press = { sub_item_table = choices }
  end
  function highlight:onShowHighlightMenu()
    native_popups = native_popups + 1
    return "popup"
  end
  function highlight:_resetHoldTimer(clear)
    if not self.long_hold_reached_action then
      self.long_hold_reached_action = function() self.long_hold_reached = true end
    end
    UI:unschedule(self.long_hold_reached_action)
    local default = G_reader_settings:readSetting("default_highlight_action", "ask")
    local native_needs_timer = default ~= "ask"
      or (self.is_word_selection and not G_reader_settings:isTrue("highlight_action_on_single_word"))
    if not clear and native_needs_timer then
      UI:scheduleIn(G_reader_settings:readSetting("highlight_long_hold_threshold_s", 3),
        self.long_hold_reached_action)
    end
    self.long_hold_reached = false
  end
  function highlight:onHoldRelease()
    if self.fail_release then error("native release failure") end
    if self.clear_id then return true end
    local very_long = self.long_hold_reached
    self:_resetHoldTimer(true)
    if self.select_mode then return self:onShowHighlightMenu() end
    if not self.selected_text then return true end
    if self.is_word_selection and not very_long
        and not G_reader_settings:isTrue("highlight_action_on_single_word") then
      native_dictionaries = native_dictionaries + 1
    elseif very_long or G_reader_settings:readSetting("default_highlight_action", "ask") == "ask" then
      self:onShowHighlightMenu()
    elseif G_reader_settings:readSetting("default_highlight_action") == "highlight" then
      native_highlights = native_highlights + 1
    end
    return true
  end
  local plugin = { ui = { highlight = highlight } }
  function plugin:Query(reader, title, preface, prompt, parameters)
    if self.fail_query == "throw" then error("query failure") end
    if self.fail_query == "return" then return nil, "caught query failure" end
    requests[#requests + 1] = {
      reader = reader, plugin = self, title = title, preface = preface,
      prompt = prompt, parameters = parameters, selection = reader.selected_text,
    }
  end
  return plugin, highlight
end

local function menu(highlight)
  local result = {}
  highlight:addToMainMenu(result)
  local items = result.long_press.sub_item_table
  local by_name = {}
  for _, item in ipairs(items) do by_name[item.text] = item end
  return by_name, items
end
local function assert_choice(highlight, name)
  local _, items = menu(highlight)
  local selected = {}
  for _, item in ipairs(items) do
    if item.radio and item.checked_func() then selected[#selected + 1] = item.text end
  end
  assert(#selected == 1 and selected[1] == name, "incorrect radio selection: " .. table.concat(selected, ", "))
end
local function release(highlight, text, single_word)
  highlight.selected_text = text and { text = text, pos0 = "start", pos1 = "end" } or nil
  highlight.is_word_selection = single_word
  return highlight:onHoldRelease()
end

local plugin, highlight = new_plugin()
assert(LongPress.register(plugin))
assert(LongPress.register(plugin)) -- idempotent on an existing reader
Actions.register(plugin)
local choices, items = menu(highlight)
assert(#items == 8 and items[5].text == "AI Dictionary" and items[6].text == "AI Explain")
assert(items[7].text == "AI Simplify" and items[8].text == "Highlight dialog position")
assert_choice(highlight, "Ask with popup dialog")

-- Native single-word override remains independent of the selected AI action.
choices["AI Dictionary"].callback()
assert_choice(highlight, "AI Dictionary")
assert(G_reader_settings:readSetting("default_highlight_action") == "ask")
release(highlight, "word", true)
assert(native_dictionaries == 1 and #requests == 0)
G_reader_settings:saveSetting("highlight_action_on_single_word", true)
release(highlight, "word", true)
assert(#requests == 1 and requests[1].title == "AI Dictionary" and requests[1].preface)
assert(requests[1].reader == highlight and requests[1].selection.pos0 == "start")

-- Both entry points send exactly the same prompt, options and reader context.
highlight.buttons.aidictionary_3(highlight).callback()
assert(requests[1].prompt == requests[2].prompt)
choices["AI Explain"].callback()
assert_choice(highlight, "AI Explain")
release(highlight, "a passage", false)
highlight.buttons.aidictionary_1(highlight).callback()
assert(requests[3].title == "AI Explain" and requests[3].preface == false)
assert(requests[3].prompt == requests[4].prompt and requests[3].parameters == requests[4].parameters)
assert(requests[3].parameters.plugins[1].id == "web")

choices["AI Simplify"].callback()
assert_choice(highlight, "AI Simplify")
release(highlight, "a difficult passage", false)
highlight.buttons.aidictionary_2(highlight).callback()
assert(requests[5].title == "AI Simplify" and requests[5].preface == false)
assert(requests[5].prompt == requests[6].prompt)
assert(requests[5].parameters == nil and requests[6].parameters == nil)
assert(requests[5].reader == highlight and requests[5].selection.text == "a difficult passage")

-- A direct long-press needs no clipboard, and ordinary popup calls stay native.
clipboard = false
local before = #requests
release(highlight, "another passage", false)
assert(#requests == before + 1)
local popups_before = native_popups
highlight:onShowHighlightMenu(12)
assert(native_popups == popups_before + 1 and #requests == before + 1)

-- Keep the very-long-press escape, honoring native duration and cleanup.
G_reader_settings:saveSetting("highlight_long_hold_threshold_s", 4.5)
for _, single_word in ipairs({ true, false }) do
  highlight.is_word_selection = single_word
  highlight:_resetHoldTimer()
  assert(scheduled[highlight.long_hold_reached_action] == 4.5)
  highlight.long_hold_reached_action()
  before, popups_before = #requests, native_popups
  release(highlight, "held selection", single_word)
  assert(#requests == before and native_popups == popups_before + 1)
  assert(scheduled[highlight.long_hold_reached_action] == nil and not highlight.long_hold_reached)
end
G_reader_settings:saveSetting("highlight_action_on_single_word", false)
highlight.is_word_selection = true
highlight:_resetHoldTimer() -- native and adapter scheduling must not duplicate
assert(scheduled[highlight.long_hold_reached_action] == 4.5)
highlight:_resetHoldTimer(true)
assert(scheduled[highlight.long_hold_reached_action] == nil)

-- Extended selection, pending clears and empty/OCR-only selections stay native.
for _, flag in ipairs({ "select_mode", "clear_id" }) do
  before = #requests
  highlight[flag] = true
  release(highlight, "extended selection", false)
  assert(#requests == before)
  highlight[flag] = nil
end
before = #requests
release(highlight, "", false)
release(highlight, "   ", false)
release(highlight, nil, false)
assert(#requests == before)

-- Failures fall back to the popup and never leave a pending AI dispatch.
for _, failure in ipairs({ "throw", "return" }) do
  plugin.fail_query = failure
  popups_before = native_popups
  assert(release(highlight, "failed query", false))
  assert(native_popups == popups_before + 1 and highlight._aidictionary_pending_long_press == nil)
end
plugin.fail_query = nil
highlight.fail_release = true
popups_before = native_popups
release(highlight, "failed release", false)
assert(native_popups == popups_before + 1 and highlight._aidictionary_pending_long_press == nil)
highlight.fail_release = nil
assert(#errors == 2 and errors[1]:find("query failure") and errors[2]:find("native release failure"))

-- A new reader restores the choice and binds queries to the new plugin instance.
local next_plugin, next_highlight = new_plugin()
assert(LongPress.register(next_plugin))
assert_choice(next_highlight, "AI Simplify")
release(next_highlight, "next book", false)
assert(requests[#requests].plugin == next_plugin and requests[#requests].title == "AI Simplify")

-- Removing/disabling the adapter leaves a valid native popup action on restart.
local _, unmodified_highlight = new_plugin()
popups_before = native_popups
release(unmodified_highlight, "no plugin", false)
assert(native_popups == popups_before + 1)

-- Native menu choices and action changes through gestures clear the AI choice.
choices["Ask with popup dialog"].callback()
assert_choice(highlight, "Ask with popup dialog")
choices["AI Explain"].callback()
highlight:onSetHighlightAction(3)
assert_choice(highlight, "Highlight")
release(highlight, "normal highlight", false)
assert(native_highlights == 1)
choices["Do nothing"].callback()
assert(highlight.view.highlight.disabled)
choices["AI Dictionary"].callback()
assert(not highlight.view.highlight.disabled)
assert_choice(highlight, "AI Dictionary")
assert(not LongPress.register({ ui = {} }))
assert(not LongPress.register({ ui = { highlight = {} } }))

print("long_press_spec: all checks passed")
