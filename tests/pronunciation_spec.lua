-- Run from the repository root: luajit tests/pronunciation_spec.lua
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path
local WavAudio = require("wav_audio")
local pcm = string.rep("\0\0\1\0", 12000)
local wav = assert(WavAudio.from_pcm(pcm))
local function uint32(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end
assert(#wav == #pcm + 44 and wav:sub(1, 4) == "RIFF")
assert(wav:sub(9, 16) == "WAVEfmt " and wav:sub(37, 40) == "data")
assert(uint32(wav, 5) == #pcm + 36 and uint32(wav, 41) == #pcm)
assert(uint32(wav, 25) == 24000 and uint32(wav, 29) == 48000)
assert(wav:sub(21, 24) == "\1\0\1\0" and wav:sub(33, 36) == "\2\0\16\0")
assert(wav:sub(45) == pcm)
assert(not WavAudio.from_pcm("") and not WavAudio.from_pcm("x"))
local path = os.tmpname()
local file = assert(io.open(path, "wb")); assert(file:write(pcm)); assert(file:close())
assert(WavAudio.wrap_pcm_file(path) == path)
file = assert(io.open(path, "rb")); assert(file:read("*a") == wav); file:close()
os.remove(path)
assert(not WavAudio.wrap_pcm_file(path))

local configuration, encoded
package.preload.configuration = function() return configuration end
package.preload.api_key = function() return {} end
package.loaded["ssl.https"], package.loaded["socket.http"], package.loaded.ltn12 = {}, {}, {}
package.loaded.json = { encode = function(body) encoded = body; return "encoded" end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "directory" end }
package.loaded.constants = { network = { request_timeout_seconds = 60 } }
package.loaded.logger = { warn = function() end }
local Pronunciation = require("pronunciation")
for _, model in ipairs({ "google/gemini-3.8-flash-lite-tts", "google/gemini-3.8-flash-tts",
    "google/gemini-2.5-flash-preview-tts", "x-ai/grok-voice-tts-1.0", "elevenlabs/eleven-v4-turbo" }) do
  configuration = { api_key = "test", voice_endpoint = "https://openrouter.ai/api/v1/audio/speech",
    voice_model = model, voice_voice = "Zubenelgenubi" }
  local request = assert(Pronunciation.build_request("word", "context"))
  local format = model:match("^google/") and "pcm" or "mp3"
  assert(request.response_format == format and encoded.response_format == format)
  assert(request.accept == (format == "pcm" and "audio/pcm" or "audio/mpeg"))
  assert(encoded.voice == "Zubenelgenubi" and encoded.input == "word")
  assert(encoded.instructions:find("context", 1, true))
  local audio_path = assert(Pronunciation.create_audio_path("plugin", format))
  assert(audio_path:match(format == "pcm" and "%.wav$" or "%.mp3$"))
end
assert(Pronunciation.write_audio_file(path, pcm, "pcm") == path)
file = assert(io.open(path, "rb")); assert(file:read("*a") == wav); file:close()
os.remove(path)
assert(Pronunciation.write_audio_file(path, "mp3 bytes", "mp3") == path)
file = assert(io.open(path, "rb")); assert(file:read("*a") == "mp3 bytes"); file:close()
os.remove(path)
assert(not Pronunciation.write_audio_file(path, "x", "pcm"))
print("pronunciation_spec: passed")
