local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local ErrorBoundary = require("error_boundary")
local _ = require("plugin_i18n")
local T = _.template

local TimeoutPrompt = {}

local AUTO_CANCEL_SECONDS = 3

function TimeoutPrompt.show(opts)
  opts = opts or {}
  local timeout_seconds = tonumber(opts.timeout_seconds) or 90
  local remaining = AUTO_CANCEL_SECONDS
  local closed = false
  local dialog
  local tick
  local ignore_dismiss = false

  local function close()
    if closed then
      return
    end
    closed = true
    if tick then
      UIManager:unschedule(tick)
      tick = nil
    end
    if dialog then
      ignore_dismiss = true
      UIManager:close(dialog)
      ignore_dismiss = false
      dialog = nil
    end
  end

  local function message()
    return T(_("Maximum predefined request timeout reached (%1 seconds).\nAutomatic cancellation in %2..."),
      timeout_seconds, remaining)
  end

  local function on_wait_more()
    if closed then
      return
    end
    close()
    if opts.on_wait_more then
      opts.on_wait_more()
    end
  end

  local function on_cancel()
    if ignore_dismiss or closed then
      return
    end
    close()
    if opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function show_dialog()
    local previous = dialog
    dialog = ConfirmBox:new {
      text = message(),
      ok_text = T(_("Wait another %1 seconds"), timeout_seconds),
      cancel_text = _("Cancel"),
      dismissable = false,
      ok_callback = ErrorBoundary.wrap("wait more after request timeout", on_wait_more),
      cancel_callback = ErrorBoundary.wrap("cancel after request timeout", on_cancel),
    }
    UIManager:show(dialog)
    if previous then
      ignore_dismiss = true
      UIManager:close(previous)
      ignore_dismiss = false
    end
  end

  tick = ErrorBoundary.wrap("request timeout countdown", function()
    if closed then
      return
    end
    remaining = remaining - 1
    if remaining <= 0 then
      on_cancel()
      return
    end
    show_dialog()
    UIManager:scheduleIn(1, tick)
  end)

  show_dialog()
  UIManager:scheduleIn(1, tick)
  return close
end

return TimeoutPrompt
