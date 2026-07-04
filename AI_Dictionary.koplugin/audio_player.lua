local Device = require("device")

local AudioPlayer = {}

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
local android_player_cache = nil
local android_player_plugin_dir = nil

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

local function command_exists(cmd)
  local handle = io.popen("command -v " .. cmd .. " 2>/dev/null")
  if handle then
    local result = handle:read("*l")
    handle:close()
    return result and result ~= ""
  end
  return false
end

local function command_succeeds(cmd)
  local result = os.execute(cmd .. " >/dev/null 2>&1")
  return result == true or result == 0
end

local function find_ffmpeg(plugin_dir)
  local candidate_dirs = {}
  if plugin_dir and plugin_dir ~= "" then
    table.insert(candidate_dirs, plugin_dir)
  end

  for _, dir in ipairs(candidate_dirs) do
    local plugin_ffmpeg = dir .. "/bin/ffmpeg"
    if file_exists(plugin_ffmpeg) then
      return plugin_ffmpeg
    end

    local plugin_ffmpeg_bin = plugin_ffmpeg .. ".bin"
    if file_exists(plugin_ffmpeg_bin) then
      os.remove(plugin_ffmpeg)
      local ok, err = os.rename(plugin_ffmpeg_bin, plugin_ffmpeg)
      if ok then
        return plugin_ffmpeg
      end
      logger.warn("AI Dictionary audio: failed to rename ffmpeg.bin:", err)
      return plugin_ffmpeg_bin
    end
  end

  local handle = io.popen("command -v ffmpeg 2>/dev/null")
  if handle then
    local result = handle:read("*l")
    handle:close()
    if result and result ~= "" then
      return result
    end
  end
  return nil
end

local function has_kobo_mtk_sink()
  return Device.isKobo and Device:isKobo()
    and command_exists("gst-launch-1.0")
    and command_succeeds("gst-inspect-1.0 mtkbtmwrpcaudiosink")
end

local function find_kindle_gst_play(plugin_dir)
  local candidate_dirs = {}
  if plugin_dir and plugin_dir ~= "" then
    table.insert(candidate_dirs, plugin_dir)
  end

  for _, dir in ipairs(candidate_dirs) do
    local gst_play = dir .. "/kindle/gst-play"
    if file_exists(gst_play) then
      return gst_play
    end
  end

  return nil
end

local function start_detached(command, name)
  local escaped_command = command:gsub("'", "'\\''")
  local wrapper = string.format("sh -c 'exec %s' >/dev/null 2>&1 &", escaped_command)
  logger.warn("AI Dictionary audio: starting", name, command:sub(1, 200))
  return os.execute(wrapper)
end

local function release_android_player()
  if android_player_cache and android_player_cache.release then
    android_player_cache:release()
  end
  android_player_cache = nil
  android_player_plugin_dir = nil
end

local function get_android_player(AndroidAudioPlayer, plugin_dir)
  if not android_player_cache or android_player_plugin_dir ~= plugin_dir then
    release_android_player()
    android_player_cache = AndroidAudioPlayer:new { plugin_dir = plugin_dir }
    android_player_plugin_dir = plugin_dir
  end
  return android_player_cache
end

local function play_with_android(path, plugin_dir)
  local ok, AndroidAudioPlayer = pcall(require, "android_audio_player")
  if not ok then
    logger.err("AI Dictionary audio: cannot load Android audio player:", AndroidAudioPlayer)
    return false
  end

  local android_player = get_android_player(AndroidAudioPlayer, plugin_dir)
  if android_player:play(path) then
    return true
  end

  release_android_player()
  android_player = get_android_player(AndroidAudioPlayer, plugin_dir)
  if android_player:play(path) then
    return true
  end

  release_android_player()
  return false
end

local function play_with_kindle_lipc(path)
  os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
  os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'audiobook' 2>/dev/null")

  local quoted_path = shell_quote(path)
  local quoted_uri = shell_quote("file://" .. path)
  local commands = {
    "lipc-set-prop com.lab126.playermgr Open " .. quoted_uri .. " && lipc-set-prop com.lab126.playermgr Play ''",
    "lipc-set-prop com.lab126.playermgr Open " .. quoted_path .. " && lipc-set-prop com.lab126.playermgr Play ''",
    "lipc-set-prop com.lab126.playermgr Play " .. quoted_uri,
    "lipc-set-prop com.lab126.playermgr Play " .. quoted_path,
  }

  for _, command in ipairs(commands) do
    os.execute(command .. " >/dev/null 2>&1")
    local handle = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
    local in_playback = handle and handle:read("*l") or nil
    if handle then handle:close() end
    if in_playback and in_playback:match("^%s*1") then
      logger.warn("AI Dictionary audio: started Kindle LIPC playback")
      return true
    end
  end

  return false
end

function AudioPlayer.play(path, plugin_dir)
  if not (path and file_exists(path)) then
    logger.err("AI Dictionary audio: missing audio file:", path)
    return false
  end

  if Device.isAndroid and Device:isAndroid() then
    if play_with_android(path, plugin_dir) then
      return true
    end
  end

  local quoted_path = shell_quote(path)

  if command_exists("mpv") then
    return start_detached("mpv --no-video --really-quiet --force-window=no " .. quoted_path, "mpv")
  end

  if command_exists("mplayer") then
    return start_detached("mplayer -really-quiet " .. quoted_path, "mplayer")
  end

  if command_exists("ffplay") then
    return start_detached("ffplay -nodisp -autoexit -loglevel quiet " .. quoted_path, "ffplay")
  end

  if command_exists("cvlc") then
    return start_detached("cvlc --play-and-exit --intf dummy " .. quoted_path, "cvlc")
  end

  if command_exists("lipc-set-prop") and play_with_kindle_lipc(path) then
    return true
  end

  local ffmpeg = find_ffmpeg(plugin_dir)
  if ffmpeg then
    local quoted_ffmpeg = shell_quote(ffmpeg)
    if command_exists("gst-launch-0.10") then
      os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'audiobook' 2>/dev/null")
      local command = quoted_ffmpeg .. " -loglevel error -i " .. quoted_path
        .. " -f s16le -ar 22050 -ac 1 -af apad=pad_dur=1 - 2>/dev/null"
        .. " | gst-launch-0.10 fdsrc"
        .. " ! 'audio/x-raw-int,rate=22050,channels=1,width=16,depth=16,signed=true,endianness=1234'"
        .. " ! mixersink stream-type=Music sync=true"
      return start_detached(command, "kindle-ffmpeg-gst")
    end

    if has_kobo_mtk_sink() then
      local player_cmd = "gst-launch-1.0 fdsrc fd=0 ! audio/x-raw,format=S16LE,rate=44100,channels=2 ! audioconvert ! audioresample ! mtkbtmwrpcaudiosink"
      local command = quoted_ffmpeg .. " -i " .. quoted_path .. " -ar 44100 -ac 2 -f s16le - 2>/dev/null | " .. player_cmd
      return start_detached(command, "ffmpeg-gst")
    end

    if command_exists("aplay") then
      local command = quoted_ffmpeg .. " -i " .. quoted_path .. " -ar 44100 -ac 2 -f s16le - 2>/dev/null | aplay -q -f S16_LE -r 44100 -c 2"
      return start_detached(command, "ffmpeg-aplay")
    end
  end

  if command_exists("gst-play-1.0") then
    local sink_arg = has_kobo_mtk_sink() and " --audiosink=mtkbtmwrpcaudiosink" or ""
    return start_detached("gst-play-1.0 --quiet" .. sink_arg .. " " .. quoted_path, "gst-play")
  end

  if command_exists("gst-launch-1.0") then
    local sink = has_kobo_mtk_sink() and "mtkbtmwrpcaudiosink" or "autoaudiosink"
    local command = "gst-launch-1.0 filesrc location=" .. quoted_path .. " ! decodebin ! audioconvert ! audioresample ! " .. sink
    return start_detached(command, "gst-launch")
  end

  local kindle_gst_play = find_kindle_gst_play(plugin_dir)
  if kindle_gst_play then
    return start_detached(shell_quote(kindle_gst_play) .. " " .. quoted_path, "kindle-gst-play")
  end

  logger.err("AI Dictionary audio: no supported audio backend found")
  return false
end

return AudioPlayer
