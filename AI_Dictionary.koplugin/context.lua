local AnswerFormatter = require("answer_formatter")
local Device = require("device")
local clean_up_string = require("string_cleanup")

local Context = {}
local Screen = Device.screen

local MAX_HL = 2000
local MAX_TITLE = 100

local function clean_context_part(value)
  if value == nil then
    return ""
  end
  return tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
end

local function build_selection_context(before, selection, after)
  selection = clean_context_part(selection)
  if selection == "" then
    return ""
  end

  before = clean_context_part(before)
  after = clean_context_part(after)

  local parts = {}
  if before ~= "" then
    parts[#parts + 1] = before
  end
  parts[#parts + 1] = "{{{ " .. selection .. " }}}"
  if after ~= "" then
    parts[#parts + 1] = after
  end

  return table.concat(parts, " ")
end

function Context.get_selection_in_context(reader_highlight_instance, selection, window)
  window = window or 10

  if not reader_highlight_instance
      or type(reader_highlight_instance.getSelectedWordContext) ~= "function" then
    return build_selection_context(nil, selection, nil)
  end

  local ok, before, after = pcall(function()
    return reader_highlight_instance:getSelectedWordContext(window)
  end)

  if not ok then
    return build_selection_context(nil, selection, nil)
  end

  return build_selection_context(before, selection, after)
end

function Context.get_current_chapter_name(plugin)
  local ui = plugin.ui
  local doc = ui and ui.document
  if not (doc and doc.getToc) then return nil end

  local toc = doc:getToc() or {}
  if #toc == 0 then return nil end

  local chapter
  local has_pos = doc.getPos and doc.comparePositions
  if has_pos then
    local pos = doc:getPos()
    for i = 1, #toc do
      local e = toc[i]
      if e.pos and doc:comparePositions(e.pos, pos) <= 0 then
        chapter = e
      else
        break
      end
    end
  elseif doc.getCurrentPage then
    local page = doc:getCurrentPage()
    for i = 1, #toc do
      local e = toc[i]
      if e.page and e.page <= page then
        chapter = e
      else
        break
      end
    end
  end

  return chapter and chapter.title or nil
end

local function update_bounds(bounds, box)
  if type(box) ~= "table" then
    return bounds
  end

  local y = box.y or box[2]
  if not y then
    return bounds
  end

  local h = box.h or box.height or box[4] or 0
  local bottom = y + h
  bounds = bounds or { top = y, bottom = bottom }
  if y < bounds.top then
    bounds.top = y
  end
  if bottom > bounds.bottom then
    bounds.bottom = bottom
  end
  return bounds
end

local function page_box_to_screen(reader_highlight_instance, page, box)
  local view = reader_highlight_instance and reader_highlight_instance.view
  if view and page and type(view.pageToScreenTransform) == "function" then
    local ok, screen_box = pcall(function()
      return view:pageToScreenTransform(page, box)
    end)
    if ok and screen_box then
      return screen_box
    end
  end
  return box
end

local function selected_text_screen_bounds(reader_highlight_instance)
  local selected_text = reader_highlight_instance and reader_highlight_instance.selected_text
  if type(selected_text) ~= "table" then
    return nil
  end

  local page = selected_text.pos0 and selected_text.pos0.page
      or reader_highlight_instance.hold_pos and reader_highlight_instance.hold_pos.page
  local bounds = nil

  if type(selected_text.sboxes) == "table" then
    for _, box in ipairs(selected_text.sboxes) do
      bounds = update_bounds(bounds, page_box_to_screen(reader_highlight_instance, page, box))
    end
  end

  if not bounds and type(selected_text.pboxes) == "table" then
    for _, box in ipairs(selected_text.pboxes) do
      bounds = update_bounds(bounds, page_box_to_screen(reader_highlight_instance, page, box))
    end
  end

  if not bounds then
    for _, pos_key in ipairs({ "pos0", "pos1" }) do
      local pos = selected_text[pos_key]
      if type(pos) == "table" and pos.y then
        local pos_page = pos.page or page
        bounds = update_bounds(bounds, page_box_to_screen(reader_highlight_instance, pos_page, {
          x = pos.x or 0,
          y = pos.y,
          w = 1,
          h = 1,
        }))
      end
    end
  end

  return bounds
end

function Context.get_viewer_position(reader_highlight_instance, bounds)
  bounds = bounds or selected_text_screen_bounds(reader_highlight_instance)
  if bounds then
    local selection_midpoint = bounds.top + ((bounds.bottom - bounds.top) / 2)
    if selection_midpoint >= Screen:getHeight() / 2 then
      return "top"
    end
  end
  return "bottom"
end

function Context.build_query_context(plugin, reader_highlight_instance, dialog_title)
  local ui = plugin.ui
  local title, author =
    ui.document:getProps().title or "Unknown Title",
    ui.document:getProps().authors
  if type(author) == "table" then
    author = table.concat(author, ", ")
  end
  author = (author and author ~= "" and author) or "Unknown Author"

  local highlighted_text = tostring(reader_highlight_instance.selected_text.text) or "Nothing highlighted"

  local chapter_clause = ""
  local chapter_name = Context.get_current_chapter_name(plugin)
  if chapter_name then
    chapter_clause = ", chapter/part '" .. chapter_name .. "'"
  end

  local safe_highlighted_text = clean_up_string(highlighted_text, MAX_HL)
  local selection_in_context = Context.get_selection_in_context(reader_highlight_instance, highlighted_text, 15)
  local safe_selection_in_context = clean_up_string(selection_in_context, MAX_HL)
  local selection_bounds = selected_text_screen_bounds(reader_highlight_instance)

  local display_selection = safe_highlighted_text
  if dialog_title == "AI Dictionary" then
    safe_highlighted_text = AnswerFormatter.trim_to_dictionary_limit(safe_highlighted_text, 64)
    display_selection = safe_highlighted_text
  end

  return {
    replacements = {
      ["{title}"] = clean_up_string(title, MAX_TITLE),
      ["{author}"] = clean_up_string(author, MAX_TITLE),
      ["{chapter}"] = clean_up_string(chapter_clause, MAX_TITLE),
      ["{selection}"] = safe_highlighted_text,
      ["{context}"] = safe_selection_in_context,
    },
    display_selection = display_selection,
    selection_bounds = selection_bounds,
    viewer_position = Context.get_viewer_position(reader_highlight_instance, selection_bounds),
    selected_text = safe_highlighted_text,
    selection_context = safe_selection_in_context,
  }
end

return Context
