-- Gemini speech PCM: signed 16-bit little-endian, mono, 24 kHz.
local WavAudio = {}

local function uint32(value)
  return string.char(value % 256, math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

function WavAudio.from_pcm(data)
  if type(data) ~= "string" or #data == 0 or #data % 2 ~= 0 then
    return nil, "Voice TTS returned empty or incomplete 16-bit PCM audio."
  end
  if #data > 4294967259 then return nil, "Voice TTS audio is too large for WAV." end
  return "RIFF" .. uint32(36 + #data) .. "WAVEfmt " .. uint32(16)
    .. "\1\0\1\0" .. uint32(24000) .. uint32(48000) .. "\2\0\16\0"
    .. "data" .. uint32(#data) .. data
end

function WavAudio.wrap_pcm_file(path)
  local input, err = io.open(path, "rb")
  if not input then return nil, "Could not read TTS audio: " .. tostring(err) end
  local data, read_err = input:read("*a")
  input:close()
  if not data then return nil, "Could not read TTS audio: " .. tostring(read_err) end
  local wav, wav_err = WavAudio.from_pcm(data)
  if not wav then return nil, wav_err end
  local output, output_err = io.open(path, "wb")
  if not output then return nil, "Could not write WAV audio: " .. tostring(output_err) end
  local written, write_err = output:write(wav)
  local closed, close_err = output:close()
  if not written or not closed then
    return nil, "Could not write WAV audio: " .. tostring(write_err or close_err)
  end
  return path
end

return WavAudio
