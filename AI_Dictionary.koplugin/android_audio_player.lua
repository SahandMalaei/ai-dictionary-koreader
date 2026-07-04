local Device = require("device")

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

  o.plugin_dir = normalize_dir(o.plugin_dir)
  o._android = nil
  o._helper_ref = nil
  o._helper_class_ref = nil
  o._method = {}
  o._initialized = false

  return o
end

function AndroidAudioPlayer:_getCacheDir()
  local android = self._android
  if not android then
    return nil
  end

  return android.jni:context(android.app.activity.vm, function(jni)
    local cache_file = jni:callObjectMethod(
      android.app.activity.clazz,
      "getCacheDir",
      "()Ljava/io/File;"
    )
    if cache_file == nil then
      return nil
    end

    local abs_path = jni:callObjectMethod(
      cache_file,
      "getAbsolutePath",
      "()Ljava/lang/String;"
    )
    jni.env[0].DeleteLocalRef(jni.env, cache_file)
    if abs_path == nil then
      return nil
    end

    local result = jni:to_string(abs_path)
    jni.env[0].DeleteLocalRef(jni.env, abs_path)
    return result
  end)
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

  local dex_path = self.plugin_dir .. "/Resources/android/tts_helper.dex"
  if not file_exists(dex_path) then
    logger.err("AI Dictionary Android audio: missing helper dex:", dex_path)
    return false
  end

  local cache_dir = self:_getCacheDir()
  if not cache_dir then
    logger.err("AI Dictionary Android audio: cannot determine cache directory")
    return false
  end
  os.execute('mkdir -p "' .. cache_dir .. '/aidictionary"')

  local load_ok = false
  android.jni:context(android.app.activity.vm, function(jni)
    local env = jni.env

    local ctx_class = env[0].GetObjectClass(env, android.app.activity.clazz)
    if check_exception(env) or ctx_class == nil then
      logger.err("AI Dictionary Android audio: activity class lookup failed")
      return
    end

    local get_class_loader_id = env[0].GetMethodID(
      env,
      ctx_class,
      "getClassLoader",
      "()Ljava/lang/ClassLoader;"
    )
    env[0].DeleteLocalRef(env, ctx_class)
    if check_exception(env) or get_class_loader_id == nil then
      logger.err("AI Dictionary Android audio: getClassLoader method not found")
      return
    end

    local parent_class_loader = env[0].CallObjectMethod(
      env,
      android.app.activity.clazz,
      get_class_loader_id
    )
    if check_exception(env) or parent_class_loader == nil then
      logger.err("AI Dictionary Android audio: parent class loader unavailable")
      return
    end

    local dex_class_loader_class = env[0].FindClass(env, "dalvik/system/DexClassLoader")
    if check_exception(env) or dex_class_loader_class == nil then
      logger.err("AI Dictionary Android audio: DexClassLoader class not found")
      env[0].DeleteLocalRef(env, parent_class_loader)
      return
    end

    local dex_class_loader_init = env[0].GetMethodID(
      env,
      dex_class_loader_class,
      "<init>",
      "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V"
    )
    if check_exception(env) or dex_class_loader_init == nil then
      logger.err("AI Dictionary Android audio: DexClassLoader constructor not found")
      env[0].DeleteLocalRef(env, parent_class_loader)
      env[0].DeleteLocalRef(env, dex_class_loader_class)
      return
    end

    local j_dex_path = env[0].NewStringUTF(env, dex_path)
    local j_opt_dir = env[0].NewStringUTF(env, cache_dir)
    local dex_class_loader = env[0].NewObject(
      env,
      dex_class_loader_class,
      dex_class_loader_init,
      j_dex_path,
      j_opt_dir,
      nil,
      parent_class_loader
    )
    env[0].DeleteLocalRef(env, j_dex_path)
    env[0].DeleteLocalRef(env, j_opt_dir)
    env[0].DeleteLocalRef(env, parent_class_loader)
    if check_exception(env) or dex_class_loader == nil then
      logger.err("AI Dictionary Android audio: DexClassLoader creation failed")
      env[0].DeleteLocalRef(env, dex_class_loader_class)
      return
    end

    local load_class_id = env[0].GetMethodID(
      env,
      dex_class_loader_class,
      "loadClass",
      "(Ljava/lang/String;)Ljava/lang/Class;"
    )
    env[0].DeleteLocalRef(env, dex_class_loader_class)
    if check_exception(env) or load_class_id == nil then
      logger.err("AI Dictionary Android audio: loadClass method not found")
      env[0].DeleteLocalRef(env, dex_class_loader)
      return
    end

    local j_class_name = env[0].NewStringUTF(
      env,
      "org.koreader.plugin.audiobook.TtsHelper"
    )
    local helper_class = env[0].CallObjectMethod(
      env,
      dex_class_loader,
      load_class_id,
      j_class_name
    )
    env[0].DeleteLocalRef(env, j_class_name)
    env[0].DeleteLocalRef(env, dex_class_loader)
    if check_exception(env) or helper_class == nil then
      logger.err("AI Dictionary Android audio: helper class not found")
      return
    end

    local helper_init = env[0].GetMethodID(
      env,
      helper_class,
      "<init>",
      "(Landroid/content/Context;)V"
    )
    if check_exception(env) or helper_init == nil then
      logger.err("AI Dictionary Android audio: helper constructor not found")
      env[0].DeleteLocalRef(env, helper_class)
      return
    end

    local helper = env[0].NewObject(
      env,
      helper_class,
      helper_init,
      android.app.activity.clazz
    )
    if check_exception(env) or helper == nil then
      logger.err("AI Dictionary Android audio: helper creation failed")
      env[0].DeleteLocalRef(env, helper_class)
      return
    end

    self._method.playFile = env[0].GetMethodID(
      env,
      helper_class,
      "playFile",
      "(Ljava/lang/String;)I"
    )
    self._method.stopPlayback = env[0].GetMethodID(
      env,
      helper_class,
      "stopPlayback",
      "()V"
    )
    if check_exception(env) or self._method.playFile == nil then
      logger.err("AI Dictionary Android audio: playFile method not found")
      env[0].DeleteLocalRef(env, helper)
      env[0].DeleteLocalRef(env, helper_class)
      return
    end

    self._helper_ref = env[0].NewGlobalRef(env, helper)
    self._helper_class_ref = env[0].NewGlobalRef(env, helper_class)
    env[0].DeleteLocalRef(env, helper)
    env[0].DeleteLocalRef(env, helper_class)
    load_ok = true
  end)

  self._initialized = load_ok
  return load_ok
end

function AndroidAudioPlayer:play(path)
  if not (self:init() and self._helper_ref and self._method.playFile) then
    return false
  end

  local android = self._android
  local duration_ms = android.jni:context(android.app.activity.vm, function(jni)
    local env = jni.env
    local j_path = env[0].NewStringUTF(env, path)
    local result = env[0].CallIntMethod(env, self._helper_ref, self._method.playFile, j_path)
    env[0].DeleteLocalRef(env, j_path)
    if check_exception(env) then
      logger.err("AI Dictionary Android audio: playFile threw an exception")
      return -1
    end
    return result
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
      android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        if self._helper_ref and self._method.stopPlayback then
          env[0].CallVoidMethod(env, self._helper_ref, self._method.stopPlayback)
          check_exception(env)
        end
        if self._helper_ref then
          env[0].DeleteGlobalRef(env, self._helper_ref)
          self._helper_ref = nil
        end
        if self._helper_class_ref then
          env[0].DeleteGlobalRef(env, self._helper_class_ref)
          self._helper_class_ref = nil
        end
      end)
    end)
  end

  self._method = {}
  self._initialized = false
  self._android = nil
end

return AndroidAudioPlayer
