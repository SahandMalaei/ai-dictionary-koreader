local Device = require("device")
local FFIUtil = require("ffi/util")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local logger = require("logger")

local AndroidHttpWorker = {}

local POLL_INTERVAL_SECONDS = 0.05
local STATUS_RUNNING = 0
local STATUS_COMPLETE = 1
local STATUS_FAILED = 2
local STATUS_CANCELLED = 3

local class_ref
local loaded_plugin_dir
local methods = {}
local module_source = debug.getinfo(1, "S").source
local default_plugin_dir = module_source:match("^@(.+)[/\\]android_http_worker%.lua$")
    or "AI_Dictionary.koplugin"

local function check_exception(env)
  if env[0].ExceptionCheck(env) ~= 0 then
    env[0].ExceptionDescribe(env)
    env[0].ExceptionClear(env)
    return true
  end
  return false
end

local function absolute_path(path)
  return FFIUtil.realpath(path) or path
end

local function invoke(label, callback, ...)
  if not callback then return end
  local args = { n = select("#", ...), ... }
  local ok, err = xpcall(function()
    callback(unpack(args, 1, args.n))
  end, debug.traceback)
  if not ok then
    logger.err("AI Dictionary: " .. label .. " failed\n" .. tostring(err))
  end
end

local function get_cache_dir(android)
  return android.jni:context(android.app.activity.vm, function(jni)
    local cache_file = jni:callObjectMethod(
      android.app.activity.clazz,
      "getCacheDir",
      "()Ljava/io/File;"
    )
    if cache_file == nil then return nil end
    local path_string = jni:callObjectMethod(
      cache_file,
      "getAbsolutePath",
      "()Ljava/lang/String;"
    )
    jni.env[0].DeleteLocalRef(jni.env, cache_file)
    if path_string == nil then return nil end
    local path = jni:to_string(path_string)
    jni.env[0].DeleteLocalRef(jni.env, path_string)
    return path
  end)
end

local function release_class(android)
  if not class_ref then return end
  android.jni:context(android.app.activity.vm, function(jni)
    jni.env[0].DeleteGlobalRef(jni.env, class_ref)
  end)
  class_ref = nil
  loaded_plugin_dir = nil
  methods = {}
end

local function load_class(plugin_dir)
  if not (Device.isAndroid and Device:isAndroid()) then
    return nil, "Android HTTP worker is only available on Android."
  end

  local ok_android, android = pcall(require, "android")
  if not ok_android then return nil, tostring(android) end
  plugin_dir = absolute_path(plugin_dir)
  if class_ref and loaded_plugin_dir == plugin_dir then return android end
  if class_ref then release_class(android) end

  local dex_path = absolute_path(plugin_dir .. "/Resources/android/http_worker.dex")
  local dex_file = io.open(dex_path, "rb")
  if not dex_file then return nil, "Missing Android HTTP helper: " .. dex_path end
  dex_file:close()

  local cache_dir = get_cache_dir(android)
  if not cache_dir then return nil, "Could not determine Android cache directory." end

  local load_error
  android.jni:context(android.app.activity.vm, function(jni)
    local env = jni.env
    local activity_class = env[0].GetObjectClass(env, android.app.activity.clazz)
    if check_exception(env) or activity_class == nil then
      load_error = "Could not inspect Android activity."
      return
    end
    local get_loader = env[0].GetMethodID(
      env, activity_class, "getClassLoader", "()Ljava/lang/ClassLoader;"
    )
    env[0].DeleteLocalRef(env, activity_class)
    if check_exception(env) or get_loader == nil then
      load_error = "Could not find Android class loader."
      return
    end
    local parent_loader = env[0].CallObjectMethod(
      env, android.app.activity.clazz, get_loader
    )
    if check_exception(env) or parent_loader == nil then
      load_error = "Could not obtain Android class loader."
      return
    end

    local loader_class = env[0].FindClass(env, "dalvik/system/DexClassLoader")
    if check_exception(env) or loader_class == nil then
      env[0].DeleteLocalRef(env, parent_loader)
      load_error = "DexClassLoader is unavailable."
      return
    end
    local loader_init = env[0].GetMethodID(
      env,
      loader_class,
      "<init>",
      "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V"
    )
    local load_method = env[0].GetMethodID(
      env,
      loader_class,
      "loadClass",
      "(Ljava/lang/String;)Ljava/lang/Class;"
    )
    if check_exception(env) or loader_init == nil or load_method == nil then
      env[0].DeleteLocalRef(env, parent_loader)
      env[0].DeleteLocalRef(env, loader_class)
      load_error = "Could not initialize DexClassLoader."
      return
    end

    local j_dex_path = env[0].NewStringUTF(env, dex_path)
    local j_cache_dir = env[0].NewStringUTF(env, cache_dir)
    local loader = env[0].NewObject(
      env,
      loader_class,
      loader_init,
      j_dex_path,
      j_cache_dir,
      nil,
      parent_loader
    )
    env[0].DeleteLocalRef(env, j_dex_path)
    env[0].DeleteLocalRef(env, j_cache_dir)
    env[0].DeleteLocalRef(env, parent_loader)
    env[0].DeleteLocalRef(env, loader_class)
    if check_exception(env) or loader == nil then
      load_error = "Could not load Android HTTP helper DEX."
      return
    end

    local class_name = env[0].NewStringUTF(
      env, "org.koreader.plugin.aidictionary.AndroidHttpWorker"
    )
    local local_class = env[0].CallObjectMethod(
      env, loader, load_method, class_name
    )
    env[0].DeleteLocalRef(env, class_name)
    env[0].DeleteLocalRef(env, loader)
    if check_exception(env) or local_class == nil then
      load_error = "Android HTTP helper class was not found."
      return
    end

    local specs = {
      start = {
        "start",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;I)I",
      },
      get_status = { "getStatus", "(I)I" },
      get_response_code = { "getResponseCode", "(I)I" },
      get_text = { "getText", "(I)Ljava/lang/String;" },
      get_error = { "getError", "(I)Ljava/lang/String;" },
      cancel = { "cancel", "(I)V" },
      cleanup = { "cleanup", "(I)V" },
    }
    for key, spec in pairs(specs) do
      methods[key] = env[0].GetStaticMethodID(env, local_class, spec[1], spec[2])
      if check_exception(env) or methods[key] == nil then
        load_error = "Android HTTP helper method not found: " .. spec[1]
        methods = {}
        env[0].DeleteLocalRef(env, local_class)
        return
      end
    end
    class_ref = env[0].NewGlobalRef(env, local_class)
    env[0].DeleteLocalRef(env, local_class)
    if check_exception(env) or class_ref == nil then
      class_ref = nil
      methods = {}
      load_error = "Could not retain Android HTTP helper class."
    end
  end)

  if load_error then return nil, load_error end
  loaded_plugin_dir = plugin_dir
  return android
end

local function call_int(android, method, request_id)
  return android.jni:context(android.app.activity.vm, function(jni)
    local result = jni.env[0].CallStaticIntMethod(
      jni.env, class_ref, method, ffi.new("int", request_id)
    )
    if check_exception(jni.env) then return -1 end
    return tonumber(result)
  end)
end

local function call_string(android, method, request_id)
  return android.jni:context(android.app.activity.vm, function(jni)
    local result = jni.env[0].CallStaticObjectMethod(
      jni.env, class_ref, method, ffi.new("int", request_id)
    )
    if check_exception(jni.env) or result == nil then return "" end
    local value = jni:to_string(result)
    jni.env[0].DeleteLocalRef(jni.env, result)
    return value or ""
  end)
end

local function call_void(android, method, request_id)
  android.jni:context(android.app.activity.vm, function(jni)
    jni.env[0].CallStaticVoidMethod(
      jni.env, class_ref, method, ffi.new("int", request_id)
    )
    check_exception(jni.env)
  end)
end

local function start_java_request(android, options)
  return android.jni:context(android.app.activity.vm, function(jni)
    local env = jni.env
    local values = {
      options.url or "",
      options.method or "GET",
      options.authorization or "",
      options.content_type or "",
      options.accept or "",
      options.user_agent or "AI-Dictionary-KOReader",
      options.body or "",
      options.output_path or "",
    }
    local strings = {}
    for index, value in ipairs(values) do
      strings[index] = env[0].NewStringUTF(env, tostring(value))
    end
    if check_exception(env) then
      for _, value in ipairs(strings) do
        if value then env[0].DeleteLocalRef(env, value) end
      end
      return -1
    end
    local request_id = env[0].CallStaticIntMethod(
      env,
      class_ref,
      methods.start,
      strings[1],
      strings[2],
      strings[3],
      strings[4],
      strings[5],
      strings[6],
      strings[7],
      strings[8],
      ffi.new("int", math.floor((options.timeout_seconds or 30) * 1000))
    )
    for _, value in ipairs(strings) do env[0].DeleteLocalRef(env, value) end
    if check_exception(env) then return -1 end
    return tonumber(request_id)
  end)
end

function AndroidHttpWorker.start(options, callbacks)
  options = options or {}
  callbacks = callbacks or {}
  local android, load_error = load_class(options.plugin_dir or default_plugin_dir)
  if not android then
    UIManager:scheduleIn(0, function()
      invoke("Android HTTP error callback", callbacks.on_error, load_error)
    end)
    return function() end
  end

  local request_id = start_java_request(android, options)
  if not request_id or request_id < 1 then
    UIManager:scheduleIn(0, function()
      invoke("Android HTTP error callback", callbacks.on_error,
        "Could not start Android HTTP request.")
    end)
    return function() end
  end

  local active = true
  local last_text = ""
  UIManager:preventStandby()

  local function finish()
    if not active then return end
    active = false
    UIManager:allowStandby()
    call_void(android, methods.cleanup, request_id)
  end

  local poll
  poll = function()
    if not active then return end
    local text = call_string(android, methods.get_text, request_id)
    if text ~= last_text then
      last_text = text
      invoke("Android HTTP progress callback", callbacks.on_progress, text)
    end

    local status = call_int(android, methods.get_status, request_id)
    if status == STATUS_RUNNING then
      UIManager:scheduleIn(POLL_INTERVAL_SECONDS, poll)
      return
    end
    if status == STATUS_COMPLETE then
      local code = call_int(android, methods.get_response_code, request_id)
      invoke("Android HTTP completion callback", callbacks.on_complete, code, text)
    elseif status == STATUS_FAILED then
      local err = call_string(android, methods.get_error, request_id)
      invoke("Android HTTP error callback", callbacks.on_error, err)
    elseif status ~= STATUS_CANCELLED then
      invoke("Android HTTP error callback", callbacks.on_error,
        "Android HTTP worker returned an invalid status.")
    end
    finish()
  end
  UIManager:scheduleIn(POLL_INTERVAL_SECONDS, poll)

  return function()
    if not active then return end
    active = false
    UIManager:unschedule(poll)
    call_void(android, methods.cancel, request_id)
    call_void(android, methods.cleanup, request_id)
    UIManager:allowStandby()
  end
end

return AndroidHttpWorker
