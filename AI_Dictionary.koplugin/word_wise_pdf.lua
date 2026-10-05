-- Native PDF word positions stay valid when zoom, crop, rotation or reflow changes.
local Geom = require("ui/geometry")
local PDF = {}
PDF.__index = PDF
local PAGE_BUFFER_SIZE = 6

function PDF.supported(ui)
  local doc, view = ui and ui.document, ui and ui.view
  return doc and type(doc.file) == "string" and doc.file:lower():match("%.pdf$")
    and type(doc.getPageTextBoxes) == "function"
    and type(doc.nativeToPageRectTransform) == "function"
    and view and type(view.pageToScreenTransform) == "function"
    and type(view.registerViewModule) == "function"
end

function PDF.new(ui)
  return setmetatable({ ui = ui, doc = ui.document, pages = {}, order = {} }, PDF)
end

function PDF:page_count()
  return self.doc.info and self.doc.info.number_of_pages or self.doc:getPageCount()
end

function PDF:compare(a, b)
  if a.page ~= b.page then return a.page < b.page and -1 or 1 end
  if a.index ~= b.index then return a.index < b.index and -1 or 1 end
  return 0
end

function PDF:key(pos) return pos.page .. ":" .. pos.index end
function PDF:page(pos) return pos.page end
function PDF:current_page() return self.ui.view.state.page end

local function rect(box)
  if type(box) ~= "table" then return end
  for _, key in ipairs({ "x0", "y0", "x1", "y1" }) do
    if type(box[key]) ~= "number" or box[key] ~= box[key] or math.abs(box[key]) == math.huge then return end
  end
  if box.x1 <= box.x0 or box.y1 <= box.y0 then return end
  return { x = box.x0, y = box.y0, w = box.x1 - box.x0, h = box.y1 - box.y0 }
end

local function paragraph_break(previous, line)
  if not previous then return true end
  local height = math.max(previous.h, line.h)
  return line.y < previous.y - height * 0.5 -- column/block transition
    or line.y - previous.y - previous.h > height * 0.55
    or math.abs(line.x - previous.x) > height * 1.5
end

function PDF:read_page(number)
  if self.pages[number] then return self.pages[number] end
  if number < 1 or number > self:page_count() then return {} end
  -- Read only the embedded text layer. getTextBoxes() can invoke KOReader's
  -- image recognition fallback, so it must never be used for extraction here.
  local lines = self.doc:getPageTextBoxes(number)
  if lines == nil then lines = {} end
  if type(lines) ~= "table" then error("Could not extract PDF text boxes") end
  local words, previous_line, paragraph = {}, nil, 0
  for line_number, line in ipairs(lines) do
    local line_rect = rect(line)
    if line_rect and paragraph_break(previous_line, line_rect) then paragraph = paragraph + 1 end
    for _, box in ipairs(line) do
      if type(box) == "table" and type(box.word) == "string" and box.word:find("%S") then
        local r = rect(box)
        if not r then error("PDF text has no usable word coordinates") end
        local pos = { page = number, index = #words + 1, box = r }
        words[#words + 1] = { text = box.word,
          pos0 = pos, pos1 = pos, paragraph = paragraph, line = line_number,
          line_rect = line_rect or r }
      end
    end
    previous_line = line_rect or previous_line
  end
  self.pages[number] = words
  self.order[#self.order + 1] = number
  if #self.order > PAGE_BUFFER_SIZE then self.pages[table.remove(self.order, 1)] = nil end
  return words
end

function PDF:word(number, index)
  return self:read_page(number)[index]
end

function PDF:next(word)
  local number, index = word.pos0.page, word.pos0.index + 1
  for _ = 1, 32 do
    if number > self:page_count() then return end
    local next_word = self:word(number, index)
    if next_word then return next_word end
    number, index = number + 1, 1
  end
  error("Too many empty PDF pages in a row")
end

function PDF:after(pos) return self:next({ pos0 = pos }) end

function PDF:previous(word)
  local number, index = word.pos0.page, word.pos0.index - 1
  for _ = 1, 32 do
    if number < 1 then return end
    if index > 0 then return self:word(number, index) end
    number = number - 1
    if number < 1 then return end
    index = #self:read_page(number)
  end
  error("Too many empty PDF pages in a row")
end

function PDF:boundary(a, b)
  if a.pos0.page == b.pos0.page then return a.paragraph ~= b.paragraph end
  if b.pos0.page ~= a.pos0.page + 1 then return true end
  -- Across physical pages, join only a plausible unfinished continuation.
  -- PDF has no reliable semantic paragraphs; ambiguous boundaries stay separate.
  local ar, br = a.line_rect, b.line_rect
  local ending = a.text:gsub('["\'%)%]]+$', ""):gsub("”$", ""):gsub("’$", "")
  return ending:find("[%.%!%?%:%;]$") ~= nil
    or math.abs(ar.h - br.h) > math.max(ar.h, br.h) * 0.4
    or math.abs(ar.x - br.x) > math.max(ar.h, br.h) * 1.5
end

function PDF:text(words)
  local parts = {}
  for i, word in ipairs(words) do
    if i > 1 then
      local previous = words[i - 1]
      local boundary = self:boundary(previous, word)
      local new_line = previous.line ~= word.line or previous.pos0.page ~= word.pos0.page
      if new_line and not boundary and previous.text:sub(-1) == "-" then
        parts[#parts] = parts[#parts]:sub(1, -2)
      else
        parts[#parts + 1] = boundary and "\n\n" or (new_line and "\n" or " ")
      end
    end
    parts[#parts + 1] = word.text
  end
  return table.concat(parts)
end

function PDF:visible_pages()
  local view, numbers, seen = self.ui.view, {}, {}
  if view.page_scroll then
    for _, state in ipairs(view.page_states or {}) do
      if state.page and not seen[state.page] then
        numbers[#numbers + 1], seen[state.page] = state.page, true
      end
    end
  end
  if #numbers == 0 then numbers[1] = view.state.page end
  return numbers
end

function PDF:viewport()
  return { words = {}, pages = self:visible_pages(), page_index = 1, index = 1 }
end

function PDF:step_viewport(viewport)
  for _ = 1, 24 do
    local number = viewport.pages[viewport.page_index]
    if not number then return true end
    local word = self:word(number, viewport.index)
    if not word then
      viewport.page_index, viewport.index = viewport.page_index + 1, 1
    else
      viewport.words[#viewport.words + 1] = word
      viewport.index = viewport.index + 1
    end
  end
  return false
end

function PDF:signature(w, h)
  local view = self.ui.view
  local parts = { w, h, tostring(view.page_scroll) }
  local function add(state, area)
    for _, value in ipairs({ state.page or 0, state.zoom or 1, state.rotation or 0,
      area and area.x or 0, area and area.y or 0, area and area.w or 0, area and area.h or 0,
      state.offset and state.offset.x or 0, state.offset and state.offset.y or 0 }) do
      parts[#parts + 1] = tostring(value)
    end
  end
  if view.page_scroll then
    for _, state in ipairs(view.page_states or {}) do add(state, state.visible_area) end
  else
    add(view.state, view.visible_area)
  end
  local config = self.doc.configurable or {}
  for _, key in ipairs({ "text_wrap", "font_size", "line_spacing", "word_spacing" }) do
    parts[#parts + 1] = tostring(config[key])
  end
  return table.concat(parts, ":")
end

function PDF:boxes(entries, w, h)
  local result, visible = {}, {}
  for _, number in ipairs(self:visible_pages()) do visible[number] = true end
  for _, entry in ipairs(entries) do
    -- Transform each native word separately: expressions may cross lines/pages,
    -- and a bounding rectangle of a wrapped phrase would underline unrelated text.
    for _, pos in ipairs(entry.positions or { entry.pos0 }) do
      if visible[pos.page] then
        local ok, box = pcall(function()
          local page_box = self.doc:nativeToPageRectTransform(pos.page, Geom:new(pos.box))
          if page_box then return self.ui.view:pageToScreenTransform(pos.page, page_box) end
        end)
        if ok and box and type(box.x) == "number" and type(box.y) == "number"
            and type(box.w) == "number" and type(box.h) == "number" then
          local x, y = math.max(0, box.x), math.max(0, box.y)
          local right, bottom = math.min(w, box.x + box.w), math.min(h, box.y + box.h)
          if right > x and bottom > y then
            result[#result + 1] = { box = { x = x, y = y, w = right - x, h = bottom - y }, entry = entry }
          end
        end
      end
    end
  end
  return result
end

return PDF
