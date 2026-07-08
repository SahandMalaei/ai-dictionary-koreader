local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local AIViewer = require("ai_viewer")
local AnswerFormatter = require("answer_formatter")
local BookContext = require("book_context")
local Config = require("configuration_manager")
local TTS = require("tts")
local queryAI = require("ai_query")
local save_lookup_entry = require("lookups_log")

local QuerySession = {}

local STREAM_UPDATE_TOKEN_INTERVAL = 10
local OFFLINE_WAIT_MESSAGE = "You are offline. AI lookup requires an active internet connection."
local ONLINE_WAIT_MESSAGE = "Getting the answer..."

local state = {
  last_query = "",
  last_preface_with_selection = false,
  last_display_selection = "",
  last_request_parameters = nil,
  last_is_report = false,
  last_is_dictionary = false,
}

local function repaint_now()
  if UIManager.forceRePaint then
    pcall(function() UIManager:forceRePaint() end)
  end
  if UIManager.yieldToEPDC then
    pcall(function() UIManager:yieldToEPDC() end)
  end
end

local function close_selection_highlight(ui, keep_highlight)
  if ui and ui.highlight and type(ui.highlight.onClose) == "function" then
    ui.highlight:onClose(keep_highlight)
  end
end

local function wait_message()
  if NetworkMgr:isOnline() then
    return ONLINE_WAIT_MESSAGE
  end
  return OFFLINE_WAIT_MESSAGE
end

local function resolve_query(query, replacements)
  local resolved_query = query
  for key, value in pairs(replacements) do
    resolved_query = resolved_query:gsub(key, value)
  end
  return resolved_query
end

function QuerySession.stream_answer(chatgpt_viewer, message_history, is_dictionary, display_selection, preface_with_selection, on_success, request_parameters, on_complete, debug_prompt)
  local current_viewer = chatgpt_viewer
  local last_rendered_token_count = 0
  local last_rendered_dictionary_boundary = 0
  local last_rendered_answer = nil
  local cancel_stream

  local function update_viewer(answer, final_debug_prompt)
    last_rendered_answer = answer
    current_viewer = AnswerFormatter.render_answer(
      current_viewer,
      is_dictionary,
      display_selection,
      preface_with_selection,
      answer,
      final_debug_prompt
    )
    current_viewer.stream_cancel = cancel_stream
    repaint_now()
  end

  cancel_stream = queryAI(message_history, {
    request_parameters = request_parameters,
    on_delta = function(_, accumulated, token_count)
      if is_dictionary then
        local boundary = AnswerFormatter.find_dictionary_section_boundary(accumulated, last_rendered_dictionary_boundary)
        if boundary then
          last_rendered_dictionary_boundary = boundary
          local partial_answer = accumulated:sub(1, boundary - 1):gsub("%s+$", "")
          update_viewer(partial_answer)
        end
      elseif token_count - last_rendered_token_count >= STREAM_UPDATE_TOKEN_INTERVAL then
        last_rendered_token_count = token_count
        update_viewer(accumulated)
      end
    end,
    on_done = function(accumulated)
      if accumulated ~= last_rendered_answer or debug_prompt then
        update_viewer(accumulated, debug_prompt)
      end
      if on_success then
        on_success(accumulated)
      end
      if on_complete then
        on_complete()
      end
    end,
    on_error = function(err)
      update_viewer("Error querying AI: " .. tostring(err))
      if on_complete then
        on_complete()
      end
    end,
  })

  current_viewer.stream_cancel = cancel_stream
end

function QuerySession.stream_plain_answer(chatgpt_viewer, message_history, on_complete)
  local current_viewer = chatgpt_viewer
  local last_rendered_token_count = 0
  local last_rendered_answer = nil
  local cancel_stream

  local function update_viewer(answer)
    last_rendered_answer = answer
    current_viewer = current_viewer:update(answer, nil, { scroll_to_bottom = false })
    current_viewer.stream_cancel = cancel_stream
    repaint_now()
  end

  cancel_stream = queryAI(message_history, {
    on_delta = function(_, accumulated, token_count)
      if token_count - last_rendered_token_count >= STREAM_UPDATE_TOKEN_INTERVAL then
        last_rendered_token_count = token_count
        update_viewer(accumulated)
      end
    end,
    on_done = function(accumulated)
      if accumulated ~= last_rendered_answer then
        update_viewer(accumulated)
      end
      if on_complete then
        on_complete()
      end
    end,
    on_error = function(err)
      update_viewer("Error querying AI: " .. tostring(err))
      if on_complete then
        on_complete()
      end
    end,
  })

  current_viewer.stream_cancel = cancel_stream
end

function QuerySession.query(plugin, reader_highlight_instance, dialog_title, preface_with_selection, query, request_parameters)
  local ui = plugin.ui
  local context = BookContext.build_query_context(plugin, reader_highlight_instance, dialog_title)
  local is_dictionary_query = dialog_title == "AI Dictionary"
  local tts_request = nil
  if is_dictionary_query then
    tts_request = TTS.create_request_if_available(context.selected_text, context.selection_context, plugin.path)
  end

  local chatgpt_viewer = AIViewer:new {
    title = dialog_title,
    text = wait_message(),
    header_text = is_dictionary_query and context.display_selection or nil,
    onAskQuestion = nil,
    onPronunciation = tts_request and function()
      TTS.play(tts_request)
    end or nil,
    benedict = plugin,
    bottom_sheet = true,
    bottom_sheet_position = context.viewer_position,
    close_callback = function()
      close_selection_highlight(ui)
    end,
  }

  close_selection_highlight(ui, true)
  UIManager:show(chatgpt_viewer)

  state.last_query = resolve_query(query, context.replacements)
  state.last_preface_with_selection = preface_with_selection
  state.last_display_selection = context.display_selection
  state.last_request_parameters = request_parameters
  state.last_is_report = false
  state.last_is_dictionary = is_dictionary_query

  if not NetworkMgr:isOnline() then
    return
  end

  UIManager:scheduleIn(0.01, function()
    local message_history = {
      {
        role = "user",
        content = state.last_query,
      },
    }

    QuerySession.stream_answer(chatgpt_viewer, message_history, state.last_is_dictionary, context.display_selection, preface_with_selection, function(answer)
      if state.last_is_dictionary and answer and answer ~= "" then
        save_lookup_entry(plugin.path, context.selected_text, context.selection_context)
      end
    end, request_parameters, function()
      if tts_request then
        TTS.mark_text_query_finished(tts_request)
      end
    end, Config.is_debug_mode_enabled() and state.last_query or nil)
  end)
end

function QuerySession.start_report(report_viewer, report_prompt)
  state.last_query = report_prompt
  state.last_preface_with_selection = false
  state.last_display_selection = ""
  state.last_request_parameters = nil
  state.last_is_dictionary = false
  state.last_is_report = true

  local message_history = {
    {
      role = "user",
      content = report_prompt,
    },
  }

  QuerySession.stream_plain_answer(report_viewer, message_history)
end

function QuerySession.regenerate(plugin, chatgpt_viewer)
  local updated_viewer = chatgpt_viewer:update(wait_message())

  if not NetworkMgr:isOnline() then
    return
  end

  UIManager:scheduleIn(0.01, function()
    local message_history = {
      {
        role = "user",
        content = state.last_query,
      },
    }

    if state.last_is_report then
      QuerySession.stream_plain_answer(updated_viewer, message_history)
    else
      QuerySession.stream_answer(
        updated_viewer,
        message_history,
        state.last_is_dictionary,
        state.last_display_selection,
        state.last_preface_with_selection,
        nil,
        state.last_request_parameters,
        nil,
        Config.is_debug_mode_enabled() and state.last_query or nil
      )
    end
  end)
end

return QuerySession
