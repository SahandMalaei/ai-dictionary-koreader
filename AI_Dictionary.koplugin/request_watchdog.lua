local UIManager = require("ui/uimanager")
local RequestTimeout = require("request_timeout")
local TimeoutPrompt = require("timeout_prompt")
local ErrorBoundary = require("error_boundary")

local RequestWatchdog = {}

function RequestWatchdog.start(opts)
  opts = opts or {}
  local seconds = RequestTimeout.get_seconds()
  local finished = false
  local prompt_close
  local watchdog
  local cancel_http = opts.cancel_http

  local function stop_prompt()
    if prompt_close then
      prompt_close()
      prompt_close = nil
    end
  end

  local function unschedule_watchdog()
    if watchdog then
      UIManager:unschedule(watchdog)
      watchdog = nil
    end
  end

  local function stop_all()
    unschedule_watchdog()
    stop_prompt()
  end

  local function notify_finished()
    if finished then
      return false
    end
    finished = true
    stop_all()
    return true
  end

  local function invoke_http_cancel()
    if type(cancel_http) == "function" then
      pcall(cancel_http)
    end
  end

  local arm_watchdog

  local function on_prompt_cancel()
    if not notify_finished() then
      return
    end
    invoke_http_cancel()
    if opts.on_timeout_cancel then
      opts.on_timeout_cancel(seconds)
    end
  end

  local function on_wait_more()
    prompt_close = nil
    if finished then
      return
    end
    arm_watchdog()
  end

  arm_watchdog = function()
    unschedule_watchdog()
    watchdog = ErrorBoundary.wrap("show request timeout prompt", function()
      watchdog = nil
      if finished then
        return
      end
      prompt_close = TimeoutPrompt.show({
        timeout_seconds = seconds,
        on_wait_more = on_wait_more,
        on_cancel = on_prompt_cancel,
      })
    end)
    UIManager:scheduleIn(seconds, watchdog)
  end

  arm_watchdog()

  return {
    notify_finished = notify_finished,
    note_progress = function()
      if finished then
        return
      end
      stop_all()
    end,
    set_cancel_http = function(fn)
      cancel_http = fn
    end,
    cancel = function()
      notify_finished()
      invoke_http_cancel()
    end,
  }
end

return RequestWatchdog
