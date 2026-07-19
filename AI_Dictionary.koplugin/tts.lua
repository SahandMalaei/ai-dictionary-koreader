local Device = require("device")
local UIManager = require("ui/uimanager")

local AudioPlayer = require("audio_player")
local ErrorBoundary = require("error_boundary")
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

  if not tts_request.text_query_finished then
    return
  end

  if tts_request.in_progress then
    return
  end

  tts_request.status = "pending"
  tts_request.in_progress = true

  UIManager:scheduleIn(0.01, ErrorBoundary.wrap("TTS synthesis", function()
    local audio_path, err = Pronunciation.synthesize(tts_request.text, tts_request.plugin_dir, tts_request.context)
    tts_request.in_progress = false
    if audio_path then
      tts_request.status = "ready"
      tts_request.audio_path = audio_path
      tts_request.err = nil
      if tts_request.play_when_ready then
        tts_request.play_when_ready = false
        AudioPlayer.play(audio_path, tts_request.plugin_dir)
      end
    else
      tts_request.status = "failed"
      tts_request.err = err
      tts_request.play_when_ready = false
      print("AI Dictionary TTS error: " .. tostring(err))
    end
  end))
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

  if not tts_request.text_query_finished then
    tts_request.play_when_ready = true
    return
  end

  TTS.start_request(tts_request, true)
end

return TTS
