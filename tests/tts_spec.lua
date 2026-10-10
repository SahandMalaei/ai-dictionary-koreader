-- Run from the repository root: luajit tests/tts_spec.lua
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path
local callbacks, options, played, removed, logged_error, cancelled
local path_error, request_error, response_format, wrap_error, wrapped
package.loaded.device = { isAndroid = function() return true end }
package.loaded.logger = {
  err = function(...) logged_error = table.concat({ ... }, " ") end,
  warn = function() end,
  dbg = function() end,
}
package.loaded.constants = { network = { request_timeout_seconds = 60 } }
package.loaded.audio_player = { play = function(path) played = path end }
package.loaded.background_worker = {}
package.loaded.wav_audio = { wrap_pcm_file = function(path)
  wrapped = path
  return not wrap_error and path or nil, wrap_error
end }
package.loaded.pronunciation = {
  is_enabled = function() return true end,
  create_audio_path = function() return not path_error and "test.mp3" or nil, path_error end,
  build_request = function()
    if request_error then return nil, request_error end
    return { url = "https://example.test/speech", authorization = "Bearer test",
      content_type = "application/json", accept = "audio/mpeg", body = "request",
      response_format = response_format or "mp3" }
  end,
}
package.loaded.android_http_worker = { start = function(opts, handlers)
  options, callbacks = opts, handlers
  return function() cancelled = true end
end }
local original_remove = os.remove
os.remove = function(path) removed = path; return true end
local TTS = require("tts")
local request = TTS.create_request_if_available("word", "context", "plugin")
assert(request and request.status == "idle")
TTS.play(request)
assert(request.status == "pending" and request.play_when_ready)
assert(options.accept == "audio/mpeg" and options.output_path == "test.mp3")
callbacks.on_error("HTTP 400: provider rejected request")
assert(request.status == "failed" and not request.in_progress)
assert(request.err == "HTTP 400: provider rejected request")
assert(logged_error:find(request.err, 1, true) and removed == "test.mp3")
assert(not played and not request.play_when_ready and not request.cancel_synthesis)

-- A failed request can be retried and the completed file is played.
TTS.play(request)
callbacks.on_complete(200)
assert(request.status == "ready" and played == "test.mp3" and not request.err)

-- Cancelling a pending request suppresses its late completion callback.
played = nil
local pending = TTS.create_request("other", "context", "plugin")
TTS.play(pending)
local late_callbacks = callbacks
TTS.cancel(pending)
assert(cancelled and pending.status == "idle" and not pending.in_progress)
late_callbacks.on_complete(200)
assert(not played and not pending.audio_path)

-- Errors before starting HTTP are also logged and leave no pending state.
logged_error, options = nil, nil
path_error = "Could not create Audio directory"
local no_path = TTS.create_request("word", "context", "plugin")
TTS.play(no_path)
assert(no_path.status == "failed" and not no_path.in_progress and not options)
assert(logged_error:find(path_error, 1, true))
path_error, request_error = nil, "Voice TTS is disabled"
local invalid = TTS.create_request("word", "context", "plugin")
TTS.play(invalid)
assert(invalid.status == "failed" and not invalid.in_progress and not options)
assert(logged_error:find(request_error, 1, true))
request_error, response_format = nil, "pcm"
local pcm = TTS.create_request("word", "context", "plugin")
TTS.play(pcm)
callbacks.on_complete(200)
assert(wrapped == "test.mp3" and pcm.status == "ready")
played, wrap_error = nil, "Voice TTS returned empty PCM audio"
TTS.play(TTS.create_request("word", "context", "plugin"))
callbacks.on_complete(200)
assert(not played and logged_error:find(wrap_error, 1, true))
wrapped = nil
local cancelled_pcm = TTS.create_request("word", "context", "plugin")
TTS.play(cancelled_pcm)
local cancelled_callbacks = callbacks
TTS.cancel(cancelled_pcm)
cancelled_callbacks.on_complete(200)
assert(not wrapped)
os.remove = original_remove
print("tts_spec: passed")
