--[[--
Displays some text in a scrollable view.

@usage
    local ai_viewer = AIViewer:new{
        title = _("I can scroll!"),
        text = _("I'll need to be longer than this example to scroll."),
    }
    UIManager:show(ai_viewer)
]]
local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckButton = require("ui/widget/checkbutton")
local Device = require("device")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local SheetContainer = WidgetContainer:extend{}

function SheetContainer:paintTo(bb, x, y)
  local content_size = self[1]:getSize()
  local content_x = x + math.floor((self.dimen.w - content_size.w) / 2)
  local edge_padding_vertical = self.edge_padding_vertical or 0
  local content_y = y + edge_padding_vertical
  if self.anchor ~= "top" then
    content_y = y + (self.dimen.h - content_size.h) - edge_padding_vertical
  end
  self[1]:paintTo(bb, content_x, content_y)
end

function SheetContainer:contentRange()
  local content_size = self[1]:getSize()
  local edge_padding_vertical = self.edge_padding_vertical or 0
  local content_y = (self.dimen.y or 0) + edge_padding_vertical
  if self.anchor ~= "top" then
    content_y = (self.dimen.y or 0) + self.dimen.h - content_size.h - edge_padding_vertical
  end
  return Geom:new {
    x = (self.dimen.x or 0) + math.floor((self.dimen.w - content_size.w) / 2),
    y = content_y,
    w = content_size.w,
    h = content_size.h,
  }
end

-- Change this value to adjust how many body text lines the bottom sheet reserves.
local DEFAULT_BOTTOM_SHEET_BODY_LINES = 11

-- Change this value to adjust the bottom panel's top button row height later.
-- 0.75 means 75% of the normal KOReader ButtonTable text/content height.
local DEFAULT_BOTTOM_SHEET_BUTTON_HEIGHT_SCALE = 0.95
local DEFAULT_BOTTOM_SHEET_EDGE_PADDING = Screen:scaleBySize(12)
local DEFAULT_ROUNDEDNESS_SIZE = Screen:scaleBySize(15)
local DEFAULT_BUTTON_ROUNDEDNESS_SIZE = 0

local function scale_size(value, scale, minimum)
  return math.max(minimum or 0, math.floor(value * scale + 0.5))
end

local function measure_text_line_height(args)
  local probe = TextBoxWidget:new {
    text = "",
    face = args.face,
    fgcolor = args.fgcolor,
    width = args.width,
    height = 1,
    dialog = args.dialog,
    alignment = args.alignment,
    justified = args.justified,
    lang = args.lang,
    para_direction_rtl = args.para_direction_rtl,
    auto_para_direction = args.auto_para_direction,
    alignment_strict = args.alignment_strict,
  }
  local line_height = probe.line_height_px or probe:getSize().h
  if probe.free then
    probe:free(true)
  end
  return line_height
end

local function set_button_table_radius(button_table, radius)
  if not button_table or not button_table.buttons_layout then
    return
  end
  for _, row in ipairs(button_table.buttons_layout) do
    for _, button in ipairs(row) do
      if button.frame then
        button.frame.radius = radius
      elseif button[1] then
        button[1].radius = radius
      end
    end
  end
end

local AIViewer = InputContainer:extend {
  title = nil,
  text = nil,
  width = nil,
  height = nil,
  buttons_table = nil,
  -- See TextBoxWidget for details about these options
  -- We default to justified and auto_para_direction to adapt
  -- to any kind of text we are given (book descriptions,
  -- bookmarks' text, translation results...).
  -- When used to display more technical text (HTML, CSS,
  -- application logs...), it's best to reset them to false.
  alignment = "left",
  justified = true,
  lang = nil,
  para_direction_rtl = nil,
  auto_para_direction = true,
  alignment_strict = false,

  title_face = nil,               -- use default from TitleBar
  title_multilines = nil,         -- see TitleBar for details
  title_shrink_font_to_fit = nil, -- see TitleBar for details
  text_face = Font:getFace("xx_smallinfofont", 17),
  header_text = nil,
  header_face = nil,
  header_spacing = Size.padding.small,
  fgcolor = Blitbuffer.COLOR_BLACK,
  text_padding = Size.padding.large,
  text_margin = Size.margin.small,
  button_padding = Size.padding.default,
  default_button_fgcolor = Blitbuffer.Color8(0x22),
  -- Bottom row with Close, Find buttons. Also added when no caller's buttons defined.
  add_default_buttons = nil,
  default_hold_callback = nil,   -- on each default button
  find_centered_lines_count = 5, -- line with find results to be not far from the center

  onAskQuestion = nil,
  onPronunciation = nil,

  benedict = nil,
  stream_cancel = nil,
  user_scroll_enabled = true,

  bottom_sheet = nil,
  bottom_sheet_position = "bottom",
  bottom_sheet_body_lines = DEFAULT_BOTTOM_SHEET_BODY_LINES,
  bottom_sheet_button_height_scale = DEFAULT_BOTTOM_SHEET_BUTTON_HEIGHT_SCALE,
  bottom_sheet_edge_padding_horizontal = DEFAULT_BOTTOM_SHEET_EDGE_PADDING,
  bottom_sheet_edge_padding_vertical = DEFAULT_BOTTOM_SHEET_EDGE_PADDING,
}

function AIViewer:init()
  -- calculate window dimension
  self.align = "center"
  local screen_width = Screen:getWidth()
  local screen_height = Screen:getHeight()
  local bottom_sheet_padding_h = self.bottom_sheet and (self.bottom_sheet_edge_padding_horizontal or 0) or 0
  local bottom_sheet_padding_v = self.bottom_sheet and (self.bottom_sheet_edge_padding_vertical or 0) or 0
  local bottom_sheet_max_height = math.max(1, screen_height - 2 * bottom_sheet_padding_v)
  if self.bottom_sheet_position ~= "top" then
    self.bottom_sheet_position = "bottom"
  end
  self.region = Geom:new {
    x = 0, y = 0,
    w = screen_width,
    h = screen_height,
  }
  if self.bottom_sheet then
    self.width = math.max(1, screen_width - 2 * bottom_sheet_padding_h)
  else
    local standardWidth = math.min(screen_width, screen_height) - Screen:scaleBySize(30)
    self.width = standardWidth
    self.height = standardWidth
  end

  self._find_next = false
  self._find_next_button = false
  self._old_virtual_line_num = 1

  if Device:hasKeys() then
    self.key_events.Close = { { Device.input.group.Back } }
  end

  local top_separator_height = 0
  local button_separator = nil
  local button_separator_height = 0
  if self.bottom_sheet then
    button_separator_height = (Size.line and Size.line.thin) or 1
    button_separator = LineWidget:new {
      dimen = Geom:new { w = self.width, h = button_separator_height },
      background = Blitbuffer.COLOR_GRAY,
    }
  end

  local titlebar = nil
  local titlebar_height = 0
  if not self.bottom_sheet then
    titlebar = TitleBar:new {
      width = self.width,
      align = "left",
      with_bottom_line = true,
      title = self.title,
      title_face = self.title_face,
      title_multilines = self.title_multilines,
      title_shrink_font_to_fit = self.title_shrink_font_to_fit,
      close_callback = function() self:onClose() end,
      show_parent = self,
    }
    titlebar_height = titlebar:getHeight()
  end

  -- Callback to enable/disable buttons, for at-top/at-bottom feedback
  local prev_at_top = false -- Buttons were created enabled
  local prev_at_bottom = false
  local function button_update(id, enable)
    local button = self.button_table:getButtonById(id)
    if button then
      if enable then
        button:enable()
      else
        button:disable()
      end
      button:refresh()
    end
  end
  self._buttons_scroll_callback = function(low, high)
    if prev_at_top and low > 0 then
      button_update("top", true)
      prev_at_top = false
    elseif not prev_at_top and low <= 0 then
      button_update("top", false)
      prev_at_top = true
    end
    if prev_at_bottom and high < 1 then
      button_update("bottom", true)
      prev_at_bottom = false
    elseif not prev_at_bottom and high >= 1 then
      button_update("bottom", false)
      prev_at_bottom = true
    end
  end

  -- buttons
  local default_buttons =
  {
    {
      text = _("↻"),
      callback = function()
        self:Regenerate()
      end,
      hold_callback = self.default_hold_callback,
    },
  }
  if self.onPronunciation then
    table.insert(default_buttons, {
      text = _("🔉"),
      callback = function()
        self.onPronunciation()
      end,
      hold_callback = self.default_hold_callback,
    })
  end
  table.insert(default_buttons, {
    text = _("✕"),
    callback = function()
      self:onClose()
    end,
    hold_callback = self.default_hold_callback,
  })
  if self.bottom_sheet then
    local button_height_scale = self.bottom_sheet_button_height_scale or DEFAULT_BOTTOM_SHEET_BUTTON_HEIGHT_SCALE
    local button_font_size = scale_size(20, button_height_scale, 1)
    local button_content_height = Screen:scaleBySize(button_font_size)
    for _, button in ipairs(default_buttons) do
      button.font_size = button.font_size or button_font_size
      button.height = button.height or button_content_height
    end
  end
  local buttons = self.buttons_table or {}
  local default_buttons_row_index = nil
  if self.add_default_buttons or not self.buttons_table then
    default_buttons_row_index = #buttons + 1
    table.insert(buttons, default_buttons)
  end
  local button_table_width = self.width - 2 * self.button_padding
  local button_table_sep_width = nil
  local button_table_zero_sep = not self.bottom_sheet
  local function make_button_table()
    return ButtonTable:new {
      width = button_table_width,
      buttons = buttons,
      sep_width = button_table_sep_width,
      zero_sep = button_table_zero_sep,
      show_parent = self,
    }
  end
  if self.bottom_sheet then
    local button_height_scale = self.bottom_sheet_button_height_scale or DEFAULT_BOTTOM_SHEET_BUTTON_HEIGHT_SCALE
    local original_buttontable_padding = Size.padding.buttontable
    local original_vertical_span = Size.span.vertical_default
    Size.padding.buttontable = scale_size(original_buttontable_padding, button_height_scale)
    Size.span.vertical_default = scale_size(original_vertical_span, button_height_scale)
    button_table_sep_width = scale_size(Size.line.medium, button_height_scale, 1)
    local ok, button_table = pcall(make_button_table)
    Size.padding.buttontable = original_buttontable_padding
    Size.span.vertical_default = original_vertical_span
    if not ok then
      error(button_table)
    end
    self.button_table = button_table
  else
    self.button_table = make_button_table()
  end
  set_button_table_radius(self.button_table, DEFAULT_BUTTON_ROUNDEDNESS_SIZE)
  if default_buttons_row_index and self.default_button_fgcolor then
    local default_buttons_row = self.button_table.buttons_layout and self.button_table.buttons_layout[default_buttons_row_index]
    if default_buttons_row then
      for _, button in ipairs(default_buttons_row) do
        if button.text and button.label_widget then
          button.label_widget.fgcolor = self.default_button_fgcolor
          if button.label_widget.update then
            button.label_widget:update()
          end
        end
      end
    end
  end

  local text_padding_h = self.text_padding
  local text_padding_v = self.text_padding
  if self.bottom_sheet then
    text_padding_h = math.floor(self.text_padding * 2 + 0.5)
  end
  local inner_width = self.width - 2 * text_padding_h - 2 * self.text_margin
  local inner_height = 1
  local header_widget = nil
  local header_height = 0
  if self.header_text and self.header_text ~= "" then
    local base_font = self.text_face and self.text_face.orig_font or "xx_smallinfofont"
    local base_size = self.text_face and self.text_face.orig_size or Font.sizemap.xx_smallinfofont
    local header_face = self.header_face or Font:getFace(base_font, math.floor(base_size * 1.3 + 0.5))
    header_widget = TextBoxWidget:new {
      text = self.header_text,
      face = header_face,
      fgcolor = self.fgcolor,
      width = inner_width,
      dialog = self,
      alignment = self.alignment,
      justified = false,
      lang = self.lang,
      para_direction_rtl = self.para_direction_rtl,
      auto_para_direction = self.auto_para_direction,
      alignment_strict = self.alignment_strict,
    }
    header_height = header_widget:getSize().h
  end

  local body_line_height = measure_text_line_height {
    face = self.text_face,
    fgcolor = self.fgcolor,
    width = inner_width,
    dialog = self,
    alignment = self.alignment,
    justified = self.justified,
    lang = self.lang,
    para_direction_rtl = self.para_direction_rtl,
    auto_para_direction = self.auto_para_direction,
    alignment_strict = self.alignment_strict,
  }

  local textw_height
  if self.bottom_sheet then
    local body_lines = math.max(1, self.bottom_sheet_body_lines or DEFAULT_BOTTOM_SHEET_BODY_LINES)
    local requested_body_height = body_line_height * body_lines
    textw_height = requested_body_height + 2 * text_padding_v + 2 * self.text_margin
    if header_widget then
      textw_height = textw_height + header_height + self.header_spacing
    end
    self.height = textw_height + top_separator_height + button_separator_height + titlebar_height + self.button_table:getSize().h
    if self.height > bottom_sheet_max_height then
      self.height = bottom_sheet_max_height
      textw_height = self.height - top_separator_height - button_separator_height - titlebar_height - self.button_table:getSize().h
    end
  else
    textw_height = self.height - top_separator_height - button_separator_height - titlebar_height - self.button_table:getSize().h
  end
  if textw_height < 1 then
    textw_height = 1
  end

  inner_height = textw_height - 2 * text_padding_v - 2 * self.text_margin
  if inner_height < 1 then
    inner_height = 1
  end

  local body_height = inner_height
  if header_widget then
    body_height = inner_height - header_height - self.header_spacing
    if body_height < 1 then
      body_height = 1
    end
  end

  if Device:isTouchDevice() then
    local range = self.region
    self.ges_events = {
      TapClose = {
        GestureRange:new {
          ges = "tap",
          range = range,
        },
      },
      Swipe = {
        GestureRange:new {
          ges = "swipe",
          range = range,
        },
      },
      MultiSwipe = {
        GestureRange:new {
          ges = "multiswipe",
          range = range,
        },
      },
      -- Allow selection of one or more words (see textboxwidget.lua):
      HoldStartText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldPanText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldReleaseText = {
        GestureRange:new {
          ges = "hold_release",
          range = range,
        },
        -- callback function when HoldReleaseText is handled as args
        args = function(text, hold_duration, start_idx, end_idx, to_source_index_func)
          self:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
        end
      },
      -- These will be forwarded to MovableContainer after some checks
      ForwardingTouch = { GestureRange:new { ges = "touch", range = range, }, },
      ForwardingPan = { GestureRange:new { ges = "pan", range = range, }, },
      ForwardingPanRelease = { GestureRange:new { ges = "pan_release", range = range, }, },
    }
  end

  self.scroll_text_w = ScrollTextWidget:new {
    text = self.text,
    face = self.text_face,
    fgcolor = self.fgcolor,
    width = inner_width,
    height = body_height,
    dialog = self,
    alignment = self.alignment,
    justified = self.justified,
    lang = self.lang,
    para_direction_rtl = self.para_direction_rtl,
    auto_para_direction = self.auto_para_direction,
    alignment_strict = self.alignment_strict,
    scroll_callback = self._buttons_scroll_callback,
  }

  local text_group = nil
  if header_widget then
    text_group = VerticalGroup:new {
      header_widget,
      VerticalSpan:new { height = self.header_spacing },
      self.scroll_text_w,
    }
  else
    text_group = self.scroll_text_w
  end

  self.textw = FrameContainer:new {
    padding_left = text_padding_h,
    padding_right = text_padding_h,
    padding_top = text_padding_v,
    padding_bottom = text_padding_v,
    margin = self.text_margin,
    bordersize = 0,
    text_group,
  }

  local frame_widgets = {}
  if self.bottom_sheet then
    local button_row = CenterContainer:new {
      dimen = Geom:new {
        w = self.width,
        h = self.button_table:getSize().h,
      },
      self.button_table,
    }
    if self.bottom_sheet_position == "top" then
      table.insert(frame_widgets, CenterContainer:new {
        dimen = Geom:new {
          w = self.width,
          h = textw_height,
        },
        self.textw,
      })
      table.insert(frame_widgets, button_separator)
      table.insert(frame_widgets, button_row)
    else
      table.insert(frame_widgets, button_row)
      table.insert(frame_widgets, button_separator)
    end
  else
    table.insert(frame_widgets, titlebar)
  end
  if not (self.bottom_sheet and self.bottom_sheet_position == "top") then
    table.insert(frame_widgets, CenterContainer:new {
      dimen = Geom:new {
        w = self.width,
        h = self.bottom_sheet and textw_height or self.textw:getSize().h,
      },
      self.textw,
    })
  end
  if not self.bottom_sheet then
    table.insert(frame_widgets, CenterContainer:new {
      dimen = Geom:new {
        w = self.width,
        h = self.button_table:getSize().h,
      },
      self.button_table,
    })
  end

  self.frame = FrameContainer:new {
    radius = DEFAULT_ROUNDEDNESS_SIZE,
    bordersize = self.bottom_sheet and Size.line.thick or nil,
    padding = 0,
    margin = 0,
    background = Blitbuffer.COLOR_WHITE,
    color = self.bottom_sheet and Blitbuffer.COLOR_BLACK or nil,
    VerticalGroup:new(frame_widgets)
  }
  if self.bottom_sheet then
    self[1] = SheetContainer:new {
      anchor = self.bottom_sheet_position,
      edge_padding_vertical = bottom_sheet_padding_v,
      dimen = self.region,
      self.frame,
    }
  else
    self.movable = MovableContainer:new {
      -- We'll handle these events ourselves, and call appropriate
      -- MovableContainer's methods when we didn't process the event
      ignore_events = {
        -- These have effects over the text widget, and may
        -- or may not be processed by it
        "swipe", "hold", "hold_release", "hold_pan",
        -- These do not have direct effect over the text widget,
        -- but may happen while selecting text: we need to check
        -- a few things before forwarding them
        "touch", "pan", "pan_release",
      },
      self.frame,
    }
    self[1] = WidgetContainer:new {
      align = self.align,
      dimen = self.region,
      self.movable,
    }
  end
end

function AIViewer:askAnotherQuestion()
  local input_dialog
  input_dialog = InputDialog:new {
    title = _("Ask another question"),
    input = "",
    input_type = "text",
    description = _("Enter your question for ChatGPT."),
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(input_dialog)
          end,
        },
        {
          text = _("Ask"),
          is_enter_default = true,
          callback = function()
            local input_text = input_dialog:getInputText()
            if input_text and input_text ~= "" then
              self:onAskQuestion(input_text)
            end
            UIManager:close(input_dialog)
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

function AIViewer:onCloseWidget()
  if self.bottom_sheet then
    UIManager:setDirty(nil, "ui")
    return
  end
  UIManager:setDirty(nil, function()
    return "partial", self.frame.dimen
  end)
end

function AIViewer:onShow()
  if self.bottom_sheet then
    UIManager:setDirty(self, "ui")
    return true
  end
  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)
  return true
end

function AIViewer:onTapClose(arg, ges_ev)
  local frame_dimen = self.frame.dimen
  if self.bottom_sheet and self[1] and self[1].contentRange then
    frame_dimen = self[1]:contentRange()
  end
  if frame_dimen and ges_ev.pos:notIntersectWith(frame_dimen) then
    self:onClose()
  end
  return true
end

function AIViewer:onMultiSwipe(arg, ges_ev)
  -- For consistency with other fullscreen widgets where swipe south can't be
  -- used to close and where we then allow any multiswipe to close, allow any
  -- multiswipe to close this widget too.
  self:onClose()
  return true
end

function AIViewer:onClose()
  if self.stream_cancel then
    self.stream_cancel()
    self.stream_cancel = nil
  end
  UIManager:close(self)
  if self.close_callback then
    self.close_callback()
  end
  return true
end

function AIViewer:Regenerate()
  self.benedict:Regenerate(self)
end

function AIViewer:onSwipe(arg, ges)
  if ges.pos:intersectWith(self.textw.dimen) then
    if not self.user_scroll_enabled then
      return true
    end
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" then
      self.scroll_text_w:scrollText(1)
      return true
    elseif direction == "east" then
      self.scroll_text_w:scrollText(-1)
      return true
    else
      -- trigger a full-screen HQ flashing refresh
      UIManager:setDirty(nil, "full")
      -- a long diagonal swipe may also be used for taking a screenshot,
      -- so let it propagate
      return false
    end
  end
  -- Let our MovableContainer handle swipe outside of text
  if self.movable then
    return self.movable:onMovableSwipe(arg, ges)
  end
  return false
end

-- The following handlers are similar to the ones in DictQuickLookup:
-- we just forward to our MoveableContainer the events that our
-- TextBoxWidget has not handled with text selection.
function AIViewer:onHoldStartText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  if self.movable then
    return self.movable:onMovableHold(_, ges)
  end
  return false
end

function AIViewer:onHoldPanText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  -- We only forward it if we did forward the Touch
  if self.movable and self.movable._touch_pre_pan_was_inside then
    return self.movable:onMovableHoldPan(arg, ges)
  end
end

function AIViewer:onHoldReleaseText(_, ges)
  -- Forward Hold events not processed by TextBoxWidget event handler
  -- to our MovableContainer
  if self.movable then
    return self.movable:onMovableHoldRelease(_, ges)
  end
  return false
end

-- These 3 event processors are just used to forward these events
-- to our MovableContainer, under certain conditions, to avoid
-- unwanted moves of the window while we are selecting text in
-- the definition widget.
function AIViewer:onForwardingTouch(arg, ges)
  if not self.movable then
    return false
  end
  -- This Touch may be used as the Hold we don't get (for example,
  -- when we start our Hold on the bottom buttons)
  if not ges.pos:intersectWith(self.textw.dimen) then
    return self.movable:onMovableTouch(arg, ges)
  else
    -- Ensure this is unset, so we can use it to not forward HoldPan
    self.movable._touch_pre_pan_was_inside = false
  end
end

function AIViewer:onForwardingPan(arg, ges)
  if not self.movable then
    return false
  end
  -- We only forward it if we did forward the Touch or are currently moving
  if self.movable._touch_pre_pan_was_inside or self.movable._moving then
    return self.movable:onMovablePan(arg, ges)
  end
end

function AIViewer:onForwardingPanRelease(arg, ges)
  if not self.movable then
    return false
  end
  -- We can forward onMovablePanRelease() does enough checks
  return self.movable:onMovablePanRelease(arg, ges)
end

function AIViewer:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
  if self.text_selection_callback then
    self.text_selection_callback(text, hold_duration, start_idx, end_idx, to_source_index_func)
    return
  end
  if Device:hasClipboard() then
    Device.input.setClipboardText(text)
    UIManager:show(Notification:new {
      text = start_idx == end_idx and _("Word copied to clipboard.")
          or _("Selection copied to clipboard."),
    })
  end
end

function AIViewer:update(new_text, new_header_text, options)
  options = options or {}
  UIManager:close(self)
  local updated_viewer = AIViewer:new {
    title = self.title,
    text = new_text,
    header_text = new_header_text or self.header_text,
    width = self.width,
    height = self.height,
    buttons_table = self.buttons_table,
    onAskQuestion = self.onAskQuestion,
    onPronunciation = self.onPronunciation,
    benedict = self.benedict,
    user_scroll_enabled = options.user_scroll_enabled ~= nil and options.user_scroll_enabled or self.user_scroll_enabled,
    close_callback = self.close_callback,
    stream_cancel = self.stream_cancel,
    header_face = self.header_face,
    header_spacing = self.header_spacing,
    bottom_sheet = self.bottom_sheet,
    bottom_sheet_position = self.bottom_sheet_position,
    bottom_sheet_body_lines = self.bottom_sheet_body_lines,
    bottom_sheet_button_height_scale = self.bottom_sheet_button_height_scale,
    bottom_sheet_edge_padding_horizontal = self.bottom_sheet_edge_padding_horizontal,
    bottom_sheet_edge_padding_vertical = self.bottom_sheet_edge_padding_vertical,
  }
  if options.scroll_to_bottom == true then
    updated_viewer.scroll_text_w:scrollToBottom()
  end
  UIManager:show(updated_viewer)
  return updated_viewer
end

return AIViewer
