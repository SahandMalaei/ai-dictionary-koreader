local Geom = require("ui/geometry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

-- Children: the original content, Back, Forward. Only the content contributes
-- to layout; buttons are painted over its lower corners and receive taps first.
local HistoryOverlay = WidgetContainer:extend {
  edge_padding = 0,
  bottom_padding = 0,
}

function HistoryOverlay:getSize()
  return self[1]:getSize()
end

function HistoryOverlay:paintTo(bb, x, y)
  local size = self:getSize()
  self.dimen = Geom:new { x = x, y = y, w = size.w, h = size.h }
  self[1]:paintTo(bb, x, y)
  for i = 2, 3 do
    local button = self[i]
    if button.enabled then
      local button_size = button:getSize()
      local max_x = math.max(0, size.w - button_size.w)
      local offset_x = i == 2 and self.edge_padding or max_x - self.edge_padding
      button:paintTo(bb,
        x + math.max(0, math.min(max_x, offset_x)),
        y + math.max(0, size.h - button_size.h - self.bottom_padding))
    end
  end
end

function HistoryOverlay:propagateEvent(event)
  for i = 2, 3 do
    local button = self[i]
    -- Hidden controls must not intercept selection/scrolling underneath them.
    -- Still deliver lifecycle events to all children for resource cleanup.
    if (event.handler ~= "onGesture" or button.enabled) and button:handleEvent(event) then
      return true
    end
  end
  return self[1]:handleEvent(event)
end

return HistoryOverlay
