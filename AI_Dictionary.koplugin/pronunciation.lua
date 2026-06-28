local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")

local api_key = nil
local success, result = pcall(function() return require("api_key") end)
if success then
  api_key = result.key
end

local Pronunciation = {}

local REQUEST_TIMEOUT_SECONDS = 45
local DEFAULT_OPENROUTER_VOICE = "Ara"
local DEFAULT_OPENAI_VOICE = "nova"
local DEFAULT_INSTRUCTIONS = "Speak clearly and loudly in natural American English with a female voice. Use precise dictionary-style pronunciation. Use the provided context only to choose the correct pronunciation, such as tense or part of speech. Speak only the selected text."
local DEFAULT_RESPONSE_FORMAT = "mp3"

https.TIMEOUT = REQUEST_TIMEOUT_SECONDS
http.TIMEOUT = REQUEST_TIMEOUT_SECONDS

local function get_logger()
  local ok, logger = pcall(require, "logger")
  if ok then
    return logger
  end
  return {
    warn = function() end,
    err = function() end,
    dbg = function() end,
  }
end

local logger = get_logger()

local function load_configuration()
  package.loaded["configuration"] = nil
  local ok, config = pcall(function() return require("configuration") end)
  if ok and type(config) == "table" then
    return config
  end
  return nil
end

local function path_join(...)
  local parts = { ... }
  local result = tostring(parts[1] or "")
  for i = 2, #parts do
    local part = tostring(parts[i] or "")
    result = result:gsub("/+$", "") .. "/" .. part:gsub("^/+", "")
  end
  return result
end

local function ensure_dir(path)
  if lfs.attributes(path, "mode") == "directory" then
    return true
  end
  return lfs.mkdir(path)
end

local request_counter = 0

local function next_audio_path(plugin_dir, extension)
  request_counter = request_counter + 1
  local audio_dir = path_join(plugin_dir, "Audio")
  local timestamp = os.date("%Y%m%d_%H%M%S")
  local filename = string.format("tts_%s_%03d.%s", timestamp, request_counter, extension)
  return audio_dir, path_join(audio_dir, filename)
end

local function write_binary_file(path, data)
  local file, err = io.open(path, "wb")
  if not file then
    return false, err
  end

  file:write(data)
  file:close()
  return true
end

function Pronunciation.cleanup_audio(plugin_dir)
  plugin_dir = plugin_dir or "AI_Dictionary.koplugin"
  local audio_dir = path_join(plugin_dir, "Audio")
  if lfs.attributes(audio_dir, "mode") ~= "directory" then
    return true
  end

  local ok, iter, dir_obj = pcall(lfs.dir, audio_dir)
  if not ok then
    logger.warn("AI Dictionary TTS: could not list Audio directory", audio_dir)
    return false
  end

  for name in iter, dir_obj do
    if name ~= "." and name ~= ".." and name:match("^tts_") then
      local audio_path = path_join(audio_dir, name)
      if lfs.attributes(audio_path, "mode") == "file" then
        local remove_ok, remove_err = os.remove(audio_path)
        if not remove_ok then
          logger.warn("AI Dictionary TTS: could not remove old audio file", audio_path, remove_err)
        end
      end
    end
  end

  return true
end

local function has_value(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

local function get_api_key(configuration)
  return configuration and configuration.api_key or api_key
end

local function is_openai_url(url)
  return type(url) == "string" and url:lower():find("api.openai.com", 1, true) ~= nil
end

local function get_voice_endpoint(configuration)
  if configuration and has_value(configuration.voice_endpoint) then
    return configuration.voice_endpoint
  end
  return nil
end

local function get_default_voice(provider)
  if is_openai_url(provider) then
    return DEFAULT_OPENAI_VOICE
  end
  return DEFAULT_OPENROUTER_VOICE
end

function Pronunciation.is_enabled()
  local configuration = load_configuration()
  return configuration
    and has_value(get_api_key(configuration))
    and has_value(configuration.voice_endpoint)
    and has_value(configuration.voice_model)
end

function Pronunciation.synthesize(text, plugin_dir, context)
  local configuration = load_configuration()
  local api_key_value = get_api_key(configuration)
  local voice_endpoint = get_voice_endpoint(configuration)
  if not (configuration
      and has_value(api_key_value)
      and has_value(voice_endpoint)
      and has_value(configuration.voice_model)) then
    return nil, "Voice TTS is disabled. Set api_key, voice_endpoint, and voice_model in configuration.lua."
  end

  if not text or text == "" then
    return nil, "No selected text to synthesize."
  end

  plugin_dir = plugin_dir or "AI_Dictionary.koplugin"

  local response_format = DEFAULT_RESPONSE_FORMAT
  local voice = has_value(configuration.voice_voice) and configuration.voice_voice or get_default_voice(voice_endpoint)
  local instructions = DEFAULT_INSTRUCTIONS
  if has_value(context) then
    instructions = instructions .. "\n\nContext where the selected text appears, for pronunciation disambiguation only:\n" .. context
  end
  local request_body = json.encode({
    input = text,
    model = configuration.voice_model,
    voice = voice,
    instructions = instructions,
    response_format = response_format,
    speed = (configuration and configuration.tts_speed) or 1,
  })

  local response_body = {}
  local ok, code = https.request {
    url = voice_endpoint,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#request_body),
      ["Accept"] = "audio/mpeg",
      ["Authorization"] = "Bearer " .. api_key_value,
    },
    source = ltn12.source.string(request_body),
    sink = ltn12.sink.table(response_body),
  }

  local body = table.concat(response_body)
  if tostring(code) ~= "200" then
    local err = "Voice TTS failed: " .. tostring(code) .. "\n" .. tostring(body)
    logger.err("AI Dictionary TTS:", err)
    return nil, err
  end

  local audio_dir, audio_path = next_audio_path(plugin_dir, response_format)
  if not ensure_dir(audio_dir) then
    return nil, "Could not create Audio directory: " .. tostring(audio_dir)
  end

  local write_ok, write_err = write_binary_file(audio_path, body)
  if not write_ok then
    return nil, "Could not write TTS audio file: " .. tostring(write_err)
  end

  logger.warn("AI Dictionary TTS: saved", audio_path, "bytes=", #body)
  return audio_path
end

return Pronunciation
