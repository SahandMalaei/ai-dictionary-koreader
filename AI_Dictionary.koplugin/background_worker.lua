local ffi = require("ffi")
local FFIUtil = require("ffi/util")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local BackgroundWorker = {}

local POLL_INTERVAL_SECONDS = 0.05
local REAP_INTERVAL_SECONDS = 0.5
local READ_CHUNK_SIZE = 8192
local unpack_values = unpack or table.unpack

local function invoke(label, callback, ...)
  if not callback then return end
  local args = { n = select("#", ...), ... }
  local ok, err = xpcall(function()
    callback(unpack_values(args, 1, args.n))
  end, debug.traceback)
  if not ok then
    logger.err("AI Dictionary: " .. label .. " failed\n" .. tostring(err))
  end
end

local function close_fd(fd)
  if fd then ffi.C.close(fd) end
end

local function reap_later(pid)
  local function reap()
    if not FFIUtil.isSubProcessDone(pid) then
      UIManager:scheduleIn(REAP_INTERVAL_SECONDS, reap)
    end
  end
  UIManager:scheduleIn(REAP_INTERVAL_SECONDS, reap)
end

local function write_all(fd, data)
  local offset = 0
  while offset < #data do
    local written = tonumber(ffi.C.write(fd, data:sub(offset + 1), #data - offset))
    if not written or written <= 0 then return false end
    offset = offset + written
  end
  return true
end

local function read_available(fd)
  local available = FFIUtil.getNonBlockingReadSize(fd)
  if not available or available <= 0 then return "" end
  local chunks = {}
  while available > 0 do
    local size = math.min(available, READ_CHUNK_SIZE)
    local buffer = ffi.new("char[?]", size)
    local read = tonumber(ffi.C.read(fd, buffer, size))
    if not read or read <= 0 then break end
    chunks[#chunks + 1] = ffi.string(buffer, read)
    available = available - read
  end
  return table.concat(chunks)
end

function BackgroundWorker.start(task, callbacks)
  callbacks = callbacks or {}
  local pid, read_fd = FFIUtil.runInSubProcess(function(_, write_fd)
    local function write_frame(kind, payload)
      payload = kind .. (payload or "")
      local header = string.format("%08x", #payload)
      return write_all(write_fd, header .. payload)
    end
    local function emit(payload)
      return write_frame("D", tostring(payload or ""))
    end
    local ok, err = xpcall(function() task(emit) end, debug.traceback)
    if ok then
      write_frame("S")
    else
      write_frame("E", tostring(err))
    end
    ffi.C.close(write_fd)
  end, true)

  if not pid then
    if callbacks.on_error then
      UIManager:scheduleIn(0, function()
        invoke("background worker error callback", callbacks.on_error,
          "Unable to start background network worker.")
      end)
    end
    return function() end
  end

  local active = true
  local buffer = ""
  local completed = false
  UIManager:preventStandby()

  local function finish()
    if not active then return end
    active = false
    close_fd(read_fd)
    read_fd = nil
    UIManager:allowStandby()
    if not FFIUtil.isSubProcessDone(pid) then reap_later(pid) end
    if not completed and callbacks.on_error then
      invoke("background worker error callback", callbacks.on_error,
        "Background network worker stopped unexpectedly.")
    end
  end

  local poll
  local function process_frames()
    while #buffer >= 8 do
      local frame_size = tonumber(buffer:sub(1, 8), 16)
      if not frame_size or frame_size < 1 then
        invoke("background worker error callback", callbacks.on_error,
          "Invalid background worker response.")
        completed = true
        FFIUtil.terminateSubProcess(pid)
        finish()
        return false
      end
      if #buffer < 8 + frame_size then return true end
      local frame = buffer:sub(9, 8 + frame_size)
      buffer = buffer:sub(9 + frame_size)
      local kind = frame:sub(1, 1)
      local payload = frame:sub(2)
      if kind == "D" then
        invoke("background worker message callback", callbacks.on_message, payload)
      elseif kind == "S" then
        completed = true
        invoke("background worker completion callback", callbacks.on_complete)
      elseif kind == "E" then
        completed = true
        invoke("background worker error callback", callbacks.on_error, payload)
      end
      if not active then return false end
    end
    return true
  end

  poll = function()
    if not active then return end
    buffer = buffer .. read_available(read_fd)
    if not process_frames() then return end

    local subprocess_done = FFIUtil.isSubProcessDone(pid)
    if subprocess_done then
      -- The child may have written more data after the FIONREAD snapshot
      -- above but before waitpid observed its exit. Once it has exited, drain
      -- the pipe completely before closing it so large final frames cannot be
      -- truncated.
      while true do
        local trailing = read_available(read_fd)
        if trailing == "" then break end
        buffer = buffer .. trailing
      end
      if not process_frames() then return end
      finish()
    else
      UIManager:scheduleIn(POLL_INTERVAL_SECONDS, poll)
    end
  end
  UIManager:scheduleIn(POLL_INTERVAL_SECONDS, poll)

  return function()
    if not active then return end
    active = false
    UIManager:unschedule(poll)
    FFIUtil.terminateSubProcess(pid)
    close_fd(read_fd)
    read_fd = nil
    UIManager:allowStandby()
    reap_later(pid)
  end
end

return BackgroundWorker
