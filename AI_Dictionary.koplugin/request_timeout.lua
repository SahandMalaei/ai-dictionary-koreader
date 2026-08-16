local RequestTimeout = {}

local SETTING_KEY = "ai_dictionary_request_timeout_seconds"
local DEFAULT_SECONDS = require("constants").network.request_timeout_seconds or 90
local MIN_SECONDS = 5
local MAX_SECONDS = 600
local HARD_MIN_SECONDS = 600
local HARD_MAX_SECONDS = 1800

local memory_seconds

RequestTimeout.MIN_SECONDS = MIN_SECONDS
RequestTimeout.MAX_SECONDS = MAX_SECONDS
RequestTimeout.DEFAULT_SECONDS = DEFAULT_SECONDS

local function clamp(seconds)
  seconds = tonumber(seconds)
  if not seconds then
    return DEFAULT_SECONDS
  end
  seconds = math.floor(seconds + 0.5)
  if seconds < MIN_SECONDS then
    return MIN_SECONDS
  end
  if seconds > MAX_SECONDS then
    return MAX_SECONDS
  end
  return seconds
end

local function read_saved_seconds()
  if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
    local ok, value = pcall(G_reader_settings.readSetting, G_reader_settings, SETTING_KEY)
    if ok and tonumber(value) then
      return clamp(value)
    end
  end
  if memory_seconds then
    return clamp(memory_seconds)
  end
  return nil
end

function RequestTimeout.get_seconds()
  return read_saved_seconds() or DEFAULT_SECONDS
end

function RequestTimeout.set_seconds(seconds)
  seconds = clamp(seconds)
  memory_seconds = seconds
  if G_reader_settings and type(G_reader_settings.saveSetting) == "function" then
    pcall(G_reader_settings.saveSetting, G_reader_settings, SETTING_KEY, seconds)
    if type(G_reader_settings.flush) == "function" then
      pcall(G_reader_settings.flush, G_reader_settings)
    end
  end
  return seconds
end

function RequestTimeout.hard_seconds()
  local user_seconds = RequestTimeout.get_seconds()
  local hard = user_seconds * 8
  if hard < HARD_MIN_SECONDS then
    hard = HARD_MIN_SECONDS
  end
  if hard > HARD_MAX_SECONDS then
    hard = HARD_MAX_SECONDS
  end
  return hard
end

function RequestTimeout.migrate(plugin)
  local Config = require("configuration_manager")
  local configuration = Config.load()
  if not read_saved_seconds() and tonumber(configuration.request_timeout_seconds) then
    RequestTimeout.set_seconds(configuration.request_timeout_seconds)
  end
  if configuration.request_timeout_seconds ~= nil then
    configuration.request_timeout_seconds = nil
    Config.save(plugin, configuration)
  end
end

return RequestTimeout
