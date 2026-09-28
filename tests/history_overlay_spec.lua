-- Run from the repository root: luajit tests/history_overlay_spec.lua
-- Exercise the real viewer layout with lightweight KOReader widget geometry.
-- Font rasterization and touch delivery still require device QA.
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path

local Widget = {}
function Widget:extend(fields) return setmetatable(fields or {}, { __index = self }) end
function Widget:new(fields)
  local obj = setmetatable(fields or {}, { __index = self })
  obj.key_events = {}
  if obj.init then obj:init() end
  return obj
end
function Widget:getSize()
  return self.dimen or (self[1] and self[1]:getSize()) or { w = self.width or 0, h = self.height or 0 }
end
function Widget:paintTo(_, x, y)
  local size = self:getSize()
  self.dimen = { x = x, y = y, w = size.w, h = size.h }
end
function Widget:propagateEvent(event)
  for _, child in ipairs(self) do if child:handleEvent(event) then return true end end
  return false
end
function Widget:handleEvent(event) return self:propagateEvent(event) end
function Widget:free() end

local Frame = Widget:extend { padding = 5, margin = 0, bordersize = 0 }
function Frame:getSize()
  local size = self[1]:getSize()
  local edges = 2 * (self.margin + self.bordersize)
  return {
    w = size.w + edges + (self.padding_left or self.padding) + (self.padding_right or self.padding),
    h = size.h + edges + (self.padding_top or self.padding) + (self.padding_bottom or self.padding),
  }
end
function Frame:paintTo(bb, x, y)
  Widget.paintTo(self, bb, x, y)
  self[1]:paintTo(bb, x + self.margin + self.bordersize + (self.padding_left or self.padding),
    y + self.margin + self.bordersize + (self.padding_top or self.padding))
end
local Center = Widget:extend()
function Center:paintTo(bb, x, y)
  local size, child = self:getSize(), self[1]:getSize()
  Widget.paintTo(self, bb, x, y)
  self[1]:paintTo(bb, x + math.floor((size.w - child.w) / 2), y + math.floor((size.h - child.h) / 2))
end
local Vertical = Widget:extend()
function Vertical:getSize()
  local size = { w = 0, h = 0 }
  for _, child in ipairs(self) do
    local cs = child:getSize()
    size.w, size.h = math.max(size.w, cs.w), size.h + cs.h
  end
  return size
end
function Vertical:paintTo(bb, x, y)
  for _, child in ipairs(self) do
    child:paintTo(bb, x, y)
    y = y + child:getSize().h
  end
end
local Button = Widget:extend()
function Button:init()
  self.padding_v = self.padding or 0
  self.frame, self.label_widget = {}, {}
end
function Button:getSize()
  return { w = self.width, h = self.height + 2 * (self.padding_v + self.bordersize) }
end
function Button:enable() self.enabled = true end
function Button:disable() self.enabled = false end
function Button:paintTo(bb, x, y)
  Widget.paintTo(self, bb, x, y)
  self.paints = (self.paints or 0) + 1
end
function Button:handleEvent(event)
  if event.handler == "onCloseWidget" then self.closed = true end
  local d = self.dimen
  if event.handler == "onGesture" and d and event.x >= d.x and event.x < d.x + d.w
      and event.y >= d.y and event.y < d.y + d.h then
    -- Native disabled buttons can still consume taps. The overlay must skip them.
    if self.enabled then self.callback() end
    return true
  end
  return false
end
local ButtonTable = Widget:extend()
function ButtonTable:getSize() return { w = self.width, h = 34 } end
function ButtonTable:getButtonById() end
local Text = Widget:extend()
function Text:init()
  self.height = self.height or 24
  self.line_height_px = 24
end
local Scroll = Widget:extend()
function Scroll:handleEvent(event)
  if event.handler == "onGesture" then
    self.taps = (self.taps or 0) + 1
    return true
  end
  return false
end
local screen = { w = 600, h = 800 }
function screen:getWidth() return self.w end
function screen:getHeight() return self.h end
function screen:scaleBySize(value) return value end
local dirty = 0
package.loaded["ui/uimanager"] = { setDirty = function() dirty = dirty + 1 end }
package.loaded.device = { screen = screen, hasKeys = function() return false end, isTouchDevice = function() return false end }
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 255, COLOR_GRAY = 128, Color8 = function(n) return n end }
package.loaded["ui/font"] = { sizemap = { xx_smallinfofont = 17 }, getFace = function(_, font, size) return { orig_font = font, orig_size = size } end }
package.loaded["ui/size"] = {
  padding = { small = 3, large = 12, default = 5, buttontable = 5 },
  margin = { small = 2 }, line = { thin = 1, medium = 2, thick = 2 }, span = { vertical_default = 4 },
}
package.loaded["ui/geometry"] = Widget
package.loaded["ui/bidi"] = {}
package.loaded["ffi/util"] = { template = function(text) return text end }
package.loaded.util = {}
package.loaded.gettext = function(text) return text end
package.loaded.logger = { err = function(message) error(message) end }
for _, name in ipairs({ "container/widgetcontainer", "container/inputcontainer", "container/movablecontainer",
    "checkbutton", "inputdialog", "linewidget", "notification", "verticalspan", "titlebar" }) do
  package.loaded["ui/widget/" .. name] = Widget
end
package.loaded["ui/gesturerange"] = Widget
package.loaded["ui/widget/container/framecontainer"] = Frame
package.loaded["ui/widget/container/centercontainer"] = Center
package.loaded["ui/widget/verticalgroup"] = Vertical
package.loaded["ui/widget/button"] = Button
package.loaded["ui/widget/buttontable"] = ButtonTable
package.loaded["ui/widget/textboxwidget"] = Text
package.loaded["ui/widget/scrolltextwidget"] = Scroll

local Viewer = require("ai_viewer")
local HistoryOverlay = require("history_overlay")
local function find_overlay(widget)
  if getmetatable(widget).__index == HistoryOverlay then return widget end
  for _, child in ipairs(widget) do
    local result = find_overlay(child)
    if result then return result end
  end
end
local function make_viewer(bounds, header, minimum_height, history, navigated)
  return Viewer:new {
    text = "An answer", header_text = header, bottom_sheet = true,
    bottom_sheet_selection_bounds = bounds, bottom_sheet_min_body_height = minimum_height,
    lookup_history = history, onHistoryNavigate = navigated,
  }
end

-- Compare the production layout with and without navigation across unclamped,
-- selection-constrained and screen-constrained layouts, and image-sized bodies.
local cases = {
  {},
  { bounds = { top = 90, bottom = 110 } },
  { bounds = { top = 690, bottom = 710 } },
  { bounds = { top = 350, bottom = 580 } },
  { bounds = { top = 180, bottom = 700 } },
  { height = 320 },
  { minimum = 500 },
}
local checks = 0
for _, case in ipairs(cases) do
  screen.h = case.height or 800
  for _, header in ipairs({ false, "beaver" }) do
    local baseline = make_viewer(case.bounds, header or nil, case.minimum)
    for _, state in ipairs({ {}, { back = true }, { forward = true }, { back = true, forward = true } }) do
      local history = { can_move = function(_, offset) return (offset == -1 and state.back or offset == 1 and state.forward) == true end }
      local navigated
      local viewer = make_viewer(case.bounds, header or nil, case.minimum, history, function(offset) navigated = offset end)
      assert(viewer.width == baseline.width and viewer.height == baseline.height, "popup size changed")
      assert(viewer.scroll_text_w.width == baseline.scroll_text_w.width
        and viewer.scroll_text_w.height == baseline.scroll_text_w.height, "text viewport changed")
      assert(viewer.bottom_sheet_position == baseline.bottom_sheet_position, "popup anchor changed")
      assert(viewer[1].content_y == baseline[1].content_y, "popup position changed")
      assert(viewer.frame:getSize().h == baseline.frame:getSize().h, "frame grew")
      local overlay = assert(find_overlay(viewer[1]))
      assert(overlay:getSize().h == viewer.textw:getSize().h, "overlay reserves space")
      viewer[1]:paintTo({}, 0, 0)
      local back, forward = viewer.history_back_button, viewer.history_forward_button
      assert((back.paints ~= nil) == (state.back == true), "hidden Back was painted")
      assert((forward.paints ~= nil) == (state.forward == true), "hidden Forward was painted")
      local button = state.back and back or state.forward and forward
      if button then
        local d, area = button.dimen, overlay.dimen
        assert(d.y >= area.y and d.y + d.h <= area.y + area.h, "button extends below content")
        local tap = { handler = "onGesture", x = d.x + d.w / 2, y = d.y + d.h / 2 }
        assert(overlay:handleEvent(tap))
        assert(navigated == (state.back and -1 or 1) and not viewer.scroll_text_w.taps,
          "overlay tap reached text first")
        viewer.pending_text_lookup = { completed = false }
        local before = dirty
        viewer:refreshHistoryButtons()
        assert(dirty > before, "hiding overlay must repaint underlying content")
        assert(not back.enabled and not forward.enabled)
        overlay:handleEvent(tap)
        assert(viewer.scroll_text_w.taps == 1, "hidden overlay swallowed text tap")
      end
      overlay:handleEvent({ handler = "onCloseWidget" })
      assert(back.closed and forward.closed, "hidden button missed cleanup")
      checks = checks + 1
    end
  end
end
print("history overlay: " .. checks .. " layout and interaction cases passed")
