local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")

local AIViewer = require("ai_viewer")
local AnswerFormatter = require("answer_formatter")
local Context = require("context")
local Config = require("configuration_manager")
local ErrorBoundary = require("error_boundary")
local TTS = require("tts")
local queryAI = require("ai_query")
local save_lookup_entry = require("lookups_log")
local WikipediaImage = require("wikipedia_image")

local QuerySession = {}

local STREAM_UPDATE_TOKEN_INTERVAL = 10
local OFFLINE_WAIT_MESSAGE = "You are offline. AI lookup requires an active internet connection."
local ONLINE_WAIT_MESSAGE = "Getting the answer..."

local function output_language_suffix()
  if Config.is_english_output() then return "" end
  local language = Config.get_output_language()
  return "\n\nWrite the user-visible answer in " .. language .. ". " ..
      "Keep machine-readable metadata, the exact English Wikipedia article title, formatting markers, " ..
      "and required dictionary section labels exactly as specified. Translate only the user-visible content."
end

local state = {
  last_query = "",
  last_preface_with_selection = false,
  last_display_selection = "",
  last_request_parameters = nil,
  last_is_report = false,
  last_is_dictionary = false,
  last_image_protocol = false,
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

function QuerySession.stream_answer(chatgpt_viewer, message_history, is_dictionary, display_selection, preface_with_selection, on_success, request_parameters, on_complete, debug_prompt, session)
  local current_viewer = chatgpt_viewer
  local last_rendered_token_count = 0
  local last_rendered_dictionary_boundary = 0
  local last_rendered_answer = nil
  local cancel_stream

  current_viewer.user_scroll_enabled = false

  local function refresh_current_viewer()
    local viewer = session and session.current_viewer or current_viewer
    if not viewer then return end
    current_viewer = viewer:update(viewer.text, nil, { user_scroll_enabled = viewer.user_scroll_enabled })
    current_viewer.stream_cancel = cancel_stream
    if session then session.current_viewer = current_viewer end
    repaint_now()
  end

  local function keep_empty_image_box()
    if not session or session.cancelled or not session.current_viewer then return end
    WikipediaImage.clear_placeholder(session.image_descriptor)
    refresh_current_viewer()
  end

  local function schedule_wikipedia_image(title)
    if not session or session.image_lookup_scheduled or not title then return end
    session.image_lookup_scheduled = true
    local placeholder = WikipediaImage.new_placeholder(title, true)
    session.image_descriptor = placeholder
    session.current_viewer.images = { placeholder }
    refresh_current_viewer()

    session.image_lookup_action = ErrorBoundary.wrap("Wikipedia image lookup", function()
      session.image_lookup_action = nil
      if session.cancelled then return end
      local image = WikipediaImage.fetch(title, function() return session.cancelled end)
      if session.cancelled then
        if image and image.bb then image.bb:free() end
        return
      end
      if not image then
        image = WikipediaImage.from_file(session.no_image_placeholder_path, title)
        if not image then
          keep_empty_image_box()
          return
        end
      end
      local old_bb = placeholder.bb
      placeholder.bb = image.bb
      -- TextBoxWidget may adjust descriptor dimensions during an earlier
      -- placeholder layout. Restore them to the final bitmap's exact bounds.
      placeholder.width = image.width
      placeholder.height = image.height
      placeholder.title = image.title
      refresh_current_viewer()
      if old_bb and old_bb.free then old_bb:free() end
    end)
    UIManager:scheduleIn(0, session.image_lookup_action)
  end

  local function visible_response(response)
    if not session or not session.image_protocol then
      return response, true
    end
    local title, visible, complete = WikipediaImage.parse_response(response)
    if not complete then return "", false end
    if not session.metadata_received then
      session.metadata_received = true
      schedule_wikipedia_image(title)
    end
    return visible, true
  end

  local function update_viewer(answer, final_debug_prompt, update_options)
    last_rendered_answer = answer
    current_viewer = AnswerFormatter.render_answer(
      current_viewer,
      is_dictionary,
      display_selection,
      preface_with_selection,
      answer,
      final_debug_prompt,
      update_options
    )
    current_viewer.stream_cancel = cancel_stream
    if session then
      session.current_viewer = current_viewer
    end
    repaint_now()
  end

  cancel_stream = queryAI(message_history, {
    request_parameters = request_parameters,
    on_delta = function(_, accumulated, token_count)
      local visible, metadata_complete = visible_response(accumulated)
      if not metadata_complete then return end
      if is_dictionary then
        local boundary = AnswerFormatter.find_dictionary_section_boundary(visible, last_rendered_dictionary_boundary)
        if boundary then
          last_rendered_dictionary_boundary = boundary
          local partial_answer = visible:sub(1, boundary - 1):gsub("%s+$", "")
          update_viewer(partial_answer, nil, { user_scroll_enabled = false })
        end
      elseif token_count - last_rendered_token_count >= STREAM_UPDATE_TOKEN_INTERVAL then
        last_rendered_token_count = token_count
        update_viewer(visible, nil, { user_scroll_enabled = false })
      end
    end,
    on_done = function(accumulated)
      local visible, metadata_complete = visible_response(accumulated)
      if not metadata_complete then
        visible = WikipediaImage.strip_metadata_fallback(accumulated)
      end
      if visible ~= last_rendered_answer or debug_prompt then
        update_viewer(visible, debug_prompt, { user_scroll_enabled = true })
      else
        current_viewer.user_scroll_enabled = true
      end
      if on_success then
        on_success(visible)
      end
      if on_complete then
        on_complete()
      end
    end,
    on_error = function(err)
      update_viewer("Error querying AI: " .. tostring(err), nil, { user_scroll_enabled = true })
      if on_complete then
        on_complete()
      end
    end,
  })

  current_viewer.stream_cancel = cancel_stream
  if session then
    session.current_viewer = current_viewer
  end
end

function QuerySession.stream_plain_answer(chatgpt_viewer, message_history, on_complete)
  local current_viewer = chatgpt_viewer
  local last_rendered_token_count = 0
  local last_rendered_answer = nil
  local cancel_stream

  current_viewer.user_scroll_enabled = false

  local function update_viewer(answer, update_options)
    last_rendered_answer = answer
    current_viewer = current_viewer:update(answer, nil, update_options)
    current_viewer.stream_cancel = cancel_stream
    repaint_now()
  end

  cancel_stream = queryAI(message_history, {
    on_delta = function(_, accumulated, token_count)
      if token_count - last_rendered_token_count >= STREAM_UPDATE_TOKEN_INTERVAL then
        last_rendered_token_count = token_count
        update_viewer(accumulated, { user_scroll_enabled = false })
      end
    end,
    on_done = function(accumulated)
      if accumulated ~= last_rendered_answer then
        update_viewer(accumulated, { user_scroll_enabled = true })
      else
        current_viewer.user_scroll_enabled = true
      end
      if on_complete then
        on_complete()
      end
    end,
    on_error = function(err)
      update_viewer("Error querying AI: " .. tostring(err), { user_scroll_enabled = true })
      if on_complete then
        on_complete()
      end
    end,
  })

  current_viewer.stream_cancel = cancel_stream
end

function QuerySession.query(plugin, reader_highlight_instance, dialog_title, preface_with_selection, query, request_parameters)
  local ui = plugin.ui
  local context = Context.build_query_context(plugin, reader_highlight_instance, dialog_title)
  local is_dictionary_query = dialog_title == "AI Dictionary"
  local is_explain_query = dialog_title == "AI Explain"
  local image_protocol = (is_dictionary_query or is_explain_query) and Config.is_images_enabled()
  local session = {
    cancelled = false,
    image_protocol = image_protocol,
    no_image_placeholder_path = plugin.path .. "/resources/no-image-placeholder.jpg",
  }
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
      plugin:playDictionaryPronunciation(tts_request)
    end or nil,
    benedict = plugin,
    user_scroll_enabled = not NetworkMgr:isOnline(),
    bottom_sheet = true,
    bottom_sheet_position = context.viewer_position,
    bottom_sheet_selection_bounds = context.selection_bounds,
    close_callback = ErrorBoundary.wrap("close lookup session", function()
      session.cancelled = true
      close_selection_highlight(ui)
    end),
  }
  session.current_viewer = chatgpt_viewer
  chatgpt_viewer.auxiliary_cancel = ErrorBoundary.wrap("cancel lookup session", function()
    session.cancelled = true
    if session.image_lookup_action then UIManager:unschedule(session.image_lookup_action) end
    local bb = session.image_descriptor and session.image_descriptor.bb
    if bb and bb.free then
      bb:free()
      session.image_descriptor.bb = nil
    end
  end)

  close_selection_highlight(ui, true)
  UIManager:show(chatgpt_viewer)

  state.last_query = resolve_query(query, context.replacements)
  if image_protocol then
    state.last_query = state.last_query .. WikipediaImage.prompt_suffix
  end
  if is_dictionary_query or is_explain_query then
    state.last_query = state.last_query .. output_language_suffix()
  end
  state.last_preface_with_selection = preface_with_selection
  state.last_display_selection = context.display_selection
  state.last_request_parameters = request_parameters
  state.last_is_report = false
  state.last_is_dictionary = is_dictionary_query
  state.last_image_protocol = image_protocol

  if not NetworkMgr:isOnline() then
    return
  end

  UIManager:scheduleIn(0.01, ErrorBoundary.wrap("start query stream", function()
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
    end, Config.is_debug_mode_enabled() and state.last_query or nil, session)
  end))
end

function QuerySession.start_report(report_viewer, report_prompt)
  state.last_query = report_prompt
  state.last_preface_with_selection = false
  state.last_display_selection = ""
  state.last_request_parameters = nil
  state.last_is_dictionary = false
  state.last_is_report = true
  state.last_image_protocol = false

  local message_history = {
    {
      role = "user",
      content = report_prompt,
    },
  }

  QuerySession.stream_plain_answer(report_viewer, message_history)
end

function QuerySession.regenerate(plugin, chatgpt_viewer)
  local online = NetworkMgr:isOnline()
  local old_images = chatgpt_viewer.images
  chatgpt_viewer.images = nil
  local updated_viewer = chatgpt_viewer:update(wait_message(), nil, { user_scroll_enabled = not online })
  local old_bb = old_images and old_images[1] and old_images[1].bb
  if old_bb and old_bb.free then old_bb:free() end

  local session = {
    cancelled = false,
    image_protocol = state.last_image_protocol,
    current_viewer = updated_viewer,
    no_image_placeholder_path = plugin.path .. "/resources/no-image-placeholder.jpg",
  }
  updated_viewer.auxiliary_cancel = ErrorBoundary.wrap("cancel regenerated session", function()
    session.cancelled = true
    if session.image_lookup_action then UIManager:unschedule(session.image_lookup_action) end
    local bb = session.image_descriptor and session.image_descriptor.bb
    if bb and bb.free then
      bb:free()
      session.image_descriptor.bb = nil
    end
  end)

  if not online then
    return
  end

  UIManager:scheduleIn(0.01, ErrorBoundary.wrap("start regenerated query stream", function()
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
        Config.is_debug_mode_enabled() and state.last_query or nil,
        session
      )
    end
  end))
end

return QuerySession
