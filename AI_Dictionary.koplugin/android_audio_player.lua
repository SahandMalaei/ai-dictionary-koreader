local Device = require("device")
local FFIUtil = require("ffi/util")

local AndroidAudioPlayer = {}

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

local function file_exists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

local function normalize_dir(path)
  return (path or "."):gsub("//+", "/"):gsub("/+$", "")
end

local function absolute_path(path)
  if type(path) ~= "string" or path == "" then return path end
  return FFIUtil.realpath(path) or path
end

local function check_exception(env)
  if env[0].ExceptionCheck(env) ~= 0 then
    env[0].ExceptionDescribe(env)
    env[0].ExceptionClear(env)
    return true
  end
  return false
end

function AndroidAudioPlayer:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self

  o.plugin_dir = normalize_dir(absolute_path(o.plugin_dir))
  o._android = nil
  o._media_class_ref = nil
  o._player_ref = nil
  o._method = {}
  o._initialized = false

  return o
end

function AndroidAudioPlayer:init()
  if self._initialized then
    return true
  end

  if not (Device.isAndroid and Device:isAndroid()) then
    return false
  end

  local ok, android = pcall(require, "android")
  if not ok then
    logger.err("AI Dictionary Android audio: cannot load android module:", android)
    return false
  end
  self._android = android

  local load_ok = false
  android.jni:context(android.app.activity.vm, function(jni)
    local env = jni.env
    local media_class = env[0].FindClass(env, "android/media/MediaPlayer")
    if check_exception(env) or media_class == nil then
      logger.err("AI Dictionary Android audio: MediaPlayer class not found")
      return
    end

    local method_specs = {
      constructor = { "<init>", "()V" },
      set_data_source = { "setDataSource", "(Ljava/lang/String;)V" },
      prepare = { "prepare", "()V" },
      start = { "start", "()V" },
      get_duration = { "getDuration", "()I" },
      release = { "release", "()V" },
    }
    for key, spec in pairs(method_specs) do
      self._method[key] = env[0].GetMethodID(env, media_class, spec[1], spec[2])
      if check_exception(env) or self._method[key] == nil then
        logger.err("AI Dictionary Android audio: MediaPlayer method not found:", spec[1])
        env[0].DeleteLocalRef(env, media_class)
        self._method = {}
        return
      end
    end

    self._media_class_ref = env[0].NewGlobalRef(env, media_class)
    env[0].DeleteLocalRef(env, media_class)
    if check_exception(env) or self._media_class_ref == nil then
      logger.err("AI Dictionary Android audio: could not retain MediaPlayer class")
      self._method = {}
      return
    end
    load_ok = true
  end)

  self._initialized = load_ok
  return load_ok
end

function AndroidAudioPlayer:_release_player()
  if not (self._android and self._player_ref) then return end
  local player_ref = self._player_ref
  self._player_ref = nil
  self._android.jni:context(self._android.app.activity.vm, function(jni)
    local env = jni.env
    if self._method.release then
      env[0].CallVoidMethod(env, player_ref, self._method.release)
      check_exception(env)
    end
    env[0].DeleteGlobalRef(env, player_ref)
  end)
end

function AndroidAudioPlayer:play(path)
  if not (path and file_exists(path) and self:init() and self._media_class_ref) then
    return false
  end

  path = absolute_path(path)
  self:_release_player()
  local android = self._android
  local duration_ms = android.jni:context(android.app.activity.vm, function(jni)
    local env = jni.env
    local player = env[0].NewObject(env, self._media_class_ref, self._method.constructor)
    if check_exception(env) or player == nil then
      logger.err("AI Dictionary Android audio: MediaPlayer creation failed")
      return -1
    end

    local function release_local_player()
      env[0].CallVoidMethod(env, player, self._method.release)
      check_exception(env)
      env[0].DeleteLocalRef(env, player)
    end

    local j_path = env[0].NewStringUTF(env, path)
    if check_exception(env) or j_path == nil then
      logger.err("AI Dictionary Android audio: could not create audio path string")
      release_local_player()
      return -1
    end
    env[0].CallVoidMethod(env, player, self._method.set_data_source, j_path)
    env[0].DeleteLocalRef(env, j_path)
    if check_exception(env) then
      logger.err("AI Dictionary Android audio: MediaPlayer rejected audio path:", path)
      release_local_player()
      return -1
    end

    env[0].CallVoidMethod(env, player, self._method.prepare)
    if check_exception(env) then
      logger.err("AI Dictionary Android audio: MediaPlayer could not prepare audio:", path)
      release_local_player()
      return -1
    end

    local duration = env[0].CallIntMethod(env, player, self._method.get_duration)
    if check_exception(env) then duration = -1 end

    local player_ref = env[0].NewGlobalRef(env, player)
    if check_exception(env) or player_ref == nil then
      logger.err("AI Dictionary Android audio: could not retain active MediaPlayer")
      release_local_player()
      return -1
    end
    self._player_ref = player_ref

    env[0].CallVoidMethod(env, player, self._method.start)
    if check_exception(env) then
      logger.err("AI Dictionary Android audio: MediaPlayer could not start playback")
      env[0].DeleteGlobalRef(env, self._player_ref)
      self._player_ref = nil
      release_local_player()
      return -1
    end

    env[0].DeleteLocalRef(env, player)
    return duration
  end)

  if duration_ms and duration_ms >= 0 then
    logger.warn("AI Dictionary Android audio: playback started, duration_ms=", duration_ms)
    return true
  end

  logger.err("AI Dictionary Android audio: playback failed for", path)
  return false
end

function AndroidAudioPlayer:release()
  local android = self._android
  if android then
    pcall(function()
      self:_release_player()
      android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        if self._media_class_ref then
          env[0].DeleteGlobalRef(env, self._media_class_ref)
          self._media_class_ref = nil
        end
      end)
    end)
  end

  self._method = {}
  self._initialized = false
  self._android = nil
end

return AndroidAudioPlayer
