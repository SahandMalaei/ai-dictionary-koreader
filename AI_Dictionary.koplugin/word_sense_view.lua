local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Screen = require("device").screen
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")

local View = {}
View.__index = View
-- Minimum gap between the popup and screen edges, scaled for the device.
local POPUP_SCREEN_PADDING = 8

local function scaled(value)
  return math.max(1, math.floor(Screen:scaleBySize(value)))
end

local function inside(box, pos)
  return pos.x >= box.x and pos.x < box.x + box.w
    and pos.y >= box.y and pos.y < box.y + box.h
end

function View.new()
  return setmetatable({ boxes = {} }, View)
end

function View:close_popup()
  local popup = self.popup
  self.popup = nil
  if popup then popup.frame:free() end
  return popup ~= nil
end

function View:clear()
  self.boxes = {}
  self:close_popup()
end

function View:show_popup(entry, box)
  self:close_popup()
  local sw, sh = Screen:getWidth(), Screen:getHeight()
  local screen_padding = math.max(0, math.floor(Screen:scaleBySize(POPUP_SCREEN_PADDING)))
  local padding, border, margin, tail = scaled(9), scaled(2), scaled(8), scaled(8)
  local face = Font:getFace("infofont", 20)
  local measure = TextWidget:new { text = entry.meaning, face = face }
  local max_width = math.max(1,
    math.min(math.floor(sw * 0.8), sw - 2 * screen_padding) - 2 * (padding + border))
  local width = math.min(max_width, math.max(scaled(80), measure:getSize().w))
  measure:free()
  local frame = FrameContainer:new {
    padding = padding, margin = 0, bordersize = border, radius = scaled(8),
    background = Blitbuffer.COLOR_WHITE, color = Blitbuffer.COLOR_BLACK,
    TextBoxWidget:new { text = entry.meaning, face = face, width = width, alignment = "center" },
  }
  local size = frame:getSize()
  local center = box.x + box.w / 2
  local x = math.max(screen_padding,
    math.min(sw - screen_padding - size.w, math.floor(center - size.w / 2)))
  local below = box.y + box.h + tail + margin + size.h <= sh - screen_padding
  local y = below and (box.y + box.h + tail) or (box.y - tail - size.h)
  -- Include the pointer tail in the screen-edge clearance.
  y = math.max(screen_padding + (below and tail or 0),
    math.min(sh - screen_padding - size.h - (below and 0 or tail), y))
  local tip_x = math.max(x + scaled(16), math.min(x + size.w - scaled(16), center))
  self.popup = {
    frame = frame, x = x, y = y, w = size.w, h = size.h,
    tip_x = math.floor(tip_x), tail = tail, below = below, border = border,
  }
end

function View:tap(pos)
  if self.popup and inside(self.popup, pos) then
    self:close_popup()
    return true
  end
  for _, item in ipairs(self.boxes) do
    if inside(item.box, pos) then
      self:show_popup(item.entry, item.box)
      return true
    end
  end
  -- Consume the dismissal tap so it cannot also turn a page or open a menu.
  -- With no bubble open, ordinary reader taps continue through unchanged.
  return self:close_popup()
end

function View:paint(bb, x, y)
  x, y = x or 0, y or 0
  local step, thickness = scaled(2), scaled(1)
  local wave = { 0, 1, 2, 1 }
  for _, item in ipairs(self.boxes) do
    local box = item.box
    if box.h >= thickness + 2 then
      local base_y = box.y + box.h - thickness - 2
      for offset = 0, box.w - 1, step do
        local rise = wave[(math.floor(offset / step) % 4) + 1]
        bb:paintRect(x + box.x + offset, y + base_y + rise,
          math.min(step, box.w - offset), thickness, Blitbuffer.COLOR_GRAY)
      end
    end
  end
  local popup = self.popup
  if not popup then return end
  popup.frame:paintTo(bb, x + popup.x, y + popup.y)
  local tail_y = popup.below and (popup.y - popup.tail + popup.border)
    or (popup.y + popup.h - popup.border)
  -- The triangle's open base merges into the card border.
  for row = 0, popup.tail - 1 do
    local half = popup.below and row or (popup.tail - row - 1)
    bb:paintRect(x + popup.tip_x - half, y + tail_y + row,
      2 * half + 1, 1, Blitbuffer.COLOR_BLACK)
    local inner = half - popup.border
    if inner >= 0 then
      bb:paintRect(x + popup.tip_x - inner, y + tail_y + row,
        2 * inner + 1, 1, Blitbuffer.COLOR_WHITE)
    end
  end
end

return View
