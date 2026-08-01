local Device = require("device")

local AudioPlayer = require("audio_player")
local AndroidHttpWorker = require("android_http_worker")
local BackgroundWorker = require("background_worker")
local Pronunciation = require("pronunciation")
local REQUEST_TIMEOUT_SECONDS = require("constants").network.request_timeout_seconds

local TTS = {}

function TTS.cleanup(plugin_dir)
  Pronunciation.cleanup_audio(plugin_dir)
end

function TTS.create_request(text, context, plugin_dir)
  return {
    text = text,
    context = context,
    plugin_dir = plugin_dir or "AI_Dictionary.koplugin",
    status = "idle",
    audio_path = nil,
    err = nil,
    in_progress = false,
    play_when_ready = false,
    text_query_finished = false,
    generation = 0,
    cancel_synthesis = nil,
  }
end

function TTS.create_request_if_available(text, context, plugin_dir)
  if Device.isAndroid and Device:isAndroid() and Pronunciation.is_enabled() then
    return TTS.create_request(text, context, plugin_dir)
  end
  return nil
end

function TTS.start_request(tts_request, play_when_ready)
  if not tts_request then
    return
  end

  if play_when_ready then
    tts_request.play_when_ready = true
  end

  if tts_request.in_progress then
    return
  end

  tts_request.generation = tts_request.generation + 1
  local generation = tts_request.generation
  tts_request.status = "pending"
  tts_request.in_progress = true
  tts_request.err = nil
  local target_audio_path, path_err = Pronunciation.create_audio_path(
    tts_request.plugin_dir,
    "mp3"
  )
  if not target_audio_path then
    tts_request.status = "failed"
    tts_request.in_progress = false
    tts_request.err = path_err
    tts_request.play_when_ready = false
    return
  end
  tts_request.pending_audio_path = target_audio_path
  local completed_audio_path
  local synthesis_error
  local finished = false

  local function is_current()
    return tts_request.generation == generation
  end

  local function finish_failure(err)
    if finished or not is_current() then return end
    finished = true
    tts_request.in_progress = false
    tts_request.cancel_synthesis = nil
    tts_request.pending_audio_path = nil
    tts_request.status = "failed"
    tts_request.err = err
    tts_request.play_when_ready = false
    os.remove(target_audio_path)
    print("AI Dictionary TTS error: " .. tostring(err))
  end

  local function finish_success()
    if finished or not is_current() then return end
    if synthesis_error then
      finish_failure(synthesis_error)
      return
    end
    if not completed_audio_path then
      finish_failure("Voice TTS did not produce an audio file.")
      return
    end

    finished = true
    tts_request.in_progress = false
    tts_request.cancel_synthesis = nil
    tts_request.pending_audio_path = nil
    tts_request.status = "ready"
    tts_request.audio_path = completed_audio_path
    tts_request.err = nil
    if tts_request.play_when_ready then
      tts_request.play_when_ready = false
      AudioPlayer.play(tts_request.audio_path, tts_request.plugin_dir)
    end
  end

  if Device.isAndroid and Device:isAndroid() then
    local request, request_err = Pronunciation.build_request(
      tts_request.text,
      tts_request.context
    )
    if not request then
      finish_failure(request_err)
      return
    end
    tts_request.cancel_synthesis = AndroidHttpWorker.start({
      url = request.url,
      method = "POST",
      authorization = request.authorization,
      content_type = request.content_type,
      accept = request.accept,
      body = request.body,
      output_path = target_audio_path,
      timeout_seconds = REQUEST_TIMEOUT_SECONDS,
    }, {
      on_complete = function(code)
        if code ~= 200 then
          finish_failure("Voice TTS failed: HTTP " .. tostring(code))
          return
        end
        completed_audio_path = target_audio_path
        finish_success()
      end,
      on_error = finish_failure,
    })
    return
  end

  tts_request.cancel_synthesis = BackgroundWorker.start(function(emit)
    local data, response_format_or_err = Pronunciation.synthesize_data(
      tts_request.text,
      tts_request.context
    )
    if data then
      local audio_path, write_err = Pronunciation.write_audio_file(
        target_audio_path,
        data
      )
      if audio_path then
        emit("P" .. audio_path)
      else
        emit("E" .. tostring(write_err))
      end
    else
      emit("E" .. tostring(response_format_or_err))
    end
  end, {
    on_message = function(message)
      if not is_current() then return end
      local kind = message:sub(1, 1)
      if kind == "P" then
        completed_audio_path = message:sub(2)
      elseif kind == "E" then
        synthesis_error = message:sub(2)
      end
    end,
    on_complete = finish_success,
    on_error = finish_failure,
  })
end

function TTS.cancel(tts_request)
  if not tts_request then return end
  tts_request.generation = tts_request.generation + 1
  local cancel = tts_request.cancel_synthesis
  local pending_audio_path = tts_request.pending_audio_path
  tts_request.cancel_synthesis = nil
  tts_request.pending_audio_path = nil
  if cancel then cancel() end
  if pending_audio_path then os.remove(pending_audio_path) end
  tts_request.in_progress = false
  tts_request.play_when_ready = false
  if tts_request.status == "pending" then
    tts_request.status = "idle"
  end
end

function TTS.mark_text_query_finished(tts_request)
  if not tts_request then
    return
  end

  tts_request.text_query_finished = true
  TTS.start_request(tts_request, tts_request.play_when_ready)
end

function TTS.play(tts_request)
  if not tts_request then
    return
  end

  if tts_request.status == "ready" and tts_request.audio_path then
    AudioPlayer.play(tts_request.audio_path, tts_request.plugin_dir)
    return
  end

  if tts_request.in_progress or tts_request.status == "pending" then
    tts_request.play_when_ready = true
    return
  end

  TTS.start_request(tts_request, true)
end

return TTS
