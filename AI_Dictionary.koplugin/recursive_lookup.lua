local UIManager = require("ui/uimanager")
local AIViewer = require("ai_viewer")
local AnswerFormatter = require("answer_formatter")
local Config = require("configuration_manager")
local DeepDive = require("deep_dive")
local DictionaryPrompt = require("dictionary_prompt")
local ErrorBoundary = require("error_boundary")
local LookupHistory = require("lookup_history")
local PopupLookup = require("popup_lookup")
local TTS = require("tts")
local WikipediaImage = require("wikipedia_image")
local save_lookup_entry = require("lookups_log")

local RecursiveLookup = {}
RecursiveLookup.__index = RecursiveLookup

local function copy_list(values)
  local copy = {}
  for i, value in ipairs(values or {}) do copy[i] = value end
  return copy
end

local function dispose_entry(entry)
  entry.cancelled = true
  if entry.query_start_action then
    UIManager:unschedule(entry.query_start_action)
    entry.query_start_action = nil
  end
  -- One failed cancellation must not prevent other entries/buffers being freed.
  for _, key in ipairs({ "stream_cancel", "image_lookup_cancel" }) do
    local cancel = entry[key]
    entry[key] = nil
    if cancel then ErrorBoundary.call("cancel history entry", cancel) end
  end
  ErrorBoundary.call("cancel history pronunciation", TTS.cancel, entry.tts_request)
  ErrorBoundary.call("free history image", WikipediaImage.free, entry.image_descriptor)
  if entry.image_download_path then os.remove(entry.image_download_path) end
  entry.current_viewer = nil
  entry.image_descriptor = nil
  entry.image_download_path = nil
  entry.tts_request = nil
  entry.message_history = nil
  entry.deep_dive_path = nil
  entry.answer_text = nil
  entry.header_text = nil
end

function RecursiveLookup:detach_current()
  local entry = self.history:current()
  local viewer = entry and entry.current_viewer
  if not viewer then return end
  entry.answer_text = viewer.text
  entry.header_text = viewer.header_text
  entry.text_lookup_enabled = viewer.text_lookup_enabled
  -- Selection confirmation temporarily disables lookup on the widget itself.
  -- The saved answer remains selectable when revisited.
  if viewer.pending_text_lookup then entry.text_lookup_enabled = entry.succeeded == true end
  viewer:cancelPendingTextLookup()
  entry.current_viewer = nil
  TTS.cancel(entry.tts_request)
  UIManager:close(viewer)
end

function RecursiveLookup:show(entry)
  local viewer = AIViewer:new {
    title = self.title,
    text = entry.answer_text or "Getting the answer...",
    header_text = entry.header_text,
    images = entry.image_descriptor and { entry.image_descriptor } or nil,
    benedict = self.plugin,
    lookup_session = entry,
    lookup_history = self.history,
    onHistoryNavigate = self.navigate_callback,
    tts_request = entry.tts_request,
    onPronunciation = entry.tts_request and function()
      self.plugin:playDictionaryPronunciation(entry.tts_request)
    end or nil,
    onDeepDive = entry.succeeded and entry.deep_dive_callback or false,
    deep_dive_focus = entry.deep_dive_focus,
    text_selection_callback = entry.text_lookup_callback,
    text_lookup_enabled = entry.text_lookup_enabled == true,
    user_scroll_enabled = entry.finished == true,
    bottom_sheet = true,
    bottom_sheet_position = self.context.viewer_position,
    bottom_sheet_min_body_height = self.image_protocol and WikipediaImage.required_viewport_height() or nil,
    bottom_sheet_selection_bounds = self.context.selection_bounds,
    auxiliary_cancel = self.close_callback,
  }
  entry.current_viewer = viewer
  UIManager:show(viewer)
  return viewer
end

function RecursiveLookup:navigate(offset)
  local entry = self.history:current()
  local viewer = entry and entry.current_viewer
  if not self.history:can_move(offset) or not viewer or viewer:isTextLookupPending() then return end
  self:detach_current()
  self:show(self.history:move(offset))
end

function RecursiveLookup:new_entry(selection, selection_context, messages, path)
  local entry = {
    cancelled = false,
    finished = false,
    image_protocol = self.image_protocol,
    no_image_placeholder_path = self.plugin.path .. "/Resources/no-image-placeholder.jpg",
    plugin_path = self.plugin.path,
    selection = selection,
    selection_context = selection_context,
    message_history = messages,
    deep_dive_path = path,
    deep_dive_focus = path and path[#path],
  }
  if self.is_dictionary then
    entry.header_text = select(1, AnswerFormatter.format_dictionary_output(selection, ""))
    entry.tts_request = TTS.create_request_if_available(selection, selection_context, self.plugin.path)
  else
    entry.deep_dive_callback = self.lookup_callback
  end
  entry.text_lookup_callback = self.lookup_callback
  entry.regenerate = self.regenerate_callback
  return entry
end

function RecursiveLookup:run(entry)
  self:show(entry)
  entry.query_start_action = ErrorBoundary.wrap("start history query", function()
    entry.query_start_action = nil
    if entry.cancelled or self.history:current() ~= entry then return end
    local prompt = entry.message_history[#entry.message_history].content
    self.stream_answer(
      entry.current_viewer, entry.message_history, self.is_dictionary, entry.selection,
      self.is_dictionary,
      function(answer)
        entry.succeeded = true
        if self.is_dictionary then
          if not entry.is_regeneration and answer and answer ~= "" then
            local saved, err = save_lookup_entry(self.plugin.path, entry.selection, entry.selection_context)
            if not saved and err then print(err) end
          end
        else
          entry.message_history[#entry.message_history + 1] = { role = "assistant", content = answer }
        end
      end,
      self.request_parameters,
      function()
        if entry.cancelled then return end
        entry.finished = true
        local viewer = entry.current_viewer
        if viewer then
          entry.answer_text = viewer.text
          entry.header_text = viewer.header_text
          entry.text_lookup_enabled = viewer.text_lookup_enabled
          viewer:refreshHistoryButtons()
        end
        if entry.tts_request then TTS.mark_text_query_finished(entry.tts_request) end
      end,
      Config.is_debug_mode_enabled() and prompt or nil, entry
    )
  end)
  UIManager:scheduleIn(0.01, entry.query_start_action)
end

function RecursiveLookup:lookup(selection, popup_context)
  local current = self.history:current()
  if not current or current.cancelled or not current.finished then return end
  selection = PopupLookup.clean_selection(selection)
  if selection == "" then return end

  local messages, path, prompt
  if self.is_dictionary then
    prompt = DictionaryPrompt.for_popup_selection(selection, popup_context, self.context.selection_context)
    if self.image_protocol then prompt = prompt .. WikipediaImage.prompt_suffix end
    messages = {}
  else
    path = copy_list(current.deep_dive_path)
    path[#path + 1] = selection
    prompt = DeepDive.build_prompt(path)
    if self.image_protocol then prompt = prompt .. WikipediaImage.prompt_suffix_for_deep_dive(selection) end
    -- Lists are copied; immutable messages can be shared without sharing the
    -- mutable conversation tail with previous or discarded nodes.
    messages = copy_list(current.message_history)
  end
  prompt = prompt .. self.language_suffix
  messages[#messages + 1] = { role = "user", content = prompt }
  local entry = self:new_entry(selection, popup_context, messages, path)
  self:detach_current()
  self.history:append(entry)
  self:run(entry)
end

function RecursiveLookup:regenerate()
  local current = self.history:current()
  if not current or current.cancelled then return end
  local viewer = current.current_viewer
  if not viewer or viewer:isTextLookupPending() then return end
  local messages = copy_list(current.message_history)
  if messages[#messages].role == "assistant" then table.remove(messages) end
  local entry = self:new_entry(current.selection, current.selection_context, messages,
    current.deep_dive_path and copy_list(current.deep_dive_path))
  entry.is_regeneration = true
  self:detach_current()
  -- Regeneration is local: both earlier and later answers remain intact.
  self.history:replace(entry)
  self:run(entry)
end

function RecursiveLookup.start(options)
  local self = setmetatable(options, RecursiveLookup)
  self.history = LookupHistory.new(dispose_entry)
  self.navigate_callback = ErrorBoundary.wrap("navigate answer history", function(offset) self:navigate(offset) end)
  self.lookup_callback = ErrorBoundary.wrap("start recursive lookup", function(...) self:lookup(...) end)
  self.regenerate_callback = ErrorBoundary.wrap("regenerate history answer", function() self:regenerate() end)
  self.close_callback = ErrorBoundary.wrap("close answer history", function()
    self.history:clear()
    local ui = self.plugin.ui
    if ui and ui.highlight and type(ui.highlight.onClose) == "function" then ui.highlight:onClose() end
  end)
  local prompt = self.query_text
  self.query_text = nil
  if self.image_protocol then prompt = prompt .. WikipediaImage.prompt_suffix end
  prompt = prompt .. self.language_suffix
  local entry = self:new_entry(self.context.display_selection, self.context.selection_context,
    { { role = "user", content = prompt } },
    not self.is_dictionary and { self.context.selected_text } or nil)
  self.history:append(entry)
  self:run(entry)
end

return RecursiveLookup
