local Device = require("device")

local AudioPlayer = require("audio_player")
local BackgroundWorker = require("background_worker")
local Pronunciation = require("pronunciation")

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
  local audio_data
  local response_format
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
    tts_request.status = "failed"
    tts_request.err = err
    tts_request.play_when_ready = false
    print("AI Dictionary TTS error: " .. tostring(err))
  end

  local function finish_success()
    if finished or not is_current() then return end
    if synthesis_error then
      finish_failure(synthesis_error)
      return
    end
    if not audio_data then
      finish_failure("Voice TTS returned no audio data.")
      return
    end

    local ok, audio_path, err = pcall(
      Pronunciation.save_audio,
      audio_data,
      tts_request.plugin_dir,
      response_format
    )
    if not ok then
      finish_failure(audio_path)
      return
    end
    if not audio_path then
      finish_failure(err)
      return
    end

    finished = true
    tts_request.in_progress = false
    tts_request.cancel_synthesis = nil
    tts_request.status = "ready"
    tts_request.audio_path = audio_path
    tts_request.err = nil
    if tts_request.play_when_ready then
      tts_request.play_when_ready = false
      AudioPlayer.play(audio_path, tts_request.plugin_dir)
    end
  end

  tts_request.cancel_synthesis = BackgroundWorker.start(function(emit)
    local data, response_format_or_err = Pronunciation.synthesize_data(
      tts_request.text,
      tts_request.context
    )
    if data then
      emit("A" .. tostring(response_format_or_err or "mp3") .. "\n" .. data)
    else
      emit("E" .. tostring(response_format_or_err))
    end
  end, {
    on_message = function(message)
      if not is_current() then return end
      local kind = message:sub(1, 1)
      if kind == "A" then
        local newline = message:find("\n", 2, true)
        if not newline then
          synthesis_error = "Voice TTS returned an invalid response."
          return
        end
        response_format = message:sub(2, newline - 1)
        audio_data = message:sub(newline + 1)
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
  tts_request.cancel_synthesis = nil
  if cancel then cancel() end
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
