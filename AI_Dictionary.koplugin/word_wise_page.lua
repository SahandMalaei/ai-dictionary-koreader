-- Read EPUB text without navigating the document, in small batches. Keeping
-- xpointers for each token avoids ambiguous string searches for repeated words.
local Page = {}
local MAX_WORDS = 50000
local MAX_TEXT_BYTES = 2 * 1024 * 1024

function Page.supported(ui)
  local doc = ui and ui.document
  if not doc or type(doc.file) ~= "string" or not doc.file:lower():match("%.epub$") then
    return false
  end
  for _, method in ipairs({
    "getCurrentPage", "getCurrentPos", "getPageXPointer", "getXPointer",
    "getNextVisibleWordEnd", "getPrevVisibleWordStart", "isXPointerInCurrentPage",
    "getTextFromXPointers", "getScreenBoxesFromPositions",
  }) do
    if type(doc[method]) ~= "function" then return false end
  end
  return ui.view and type(ui.view.registerViewModule) == "function"
end

function Page.signature(ui, width, height)
  local doc = ui.document
  return table.concat({
    doc:getCurrentPage(), doc:getCurrentPos(), Page.layout_signature(ui, width, height),
  }, ":")
end

function Page.layout_signature(ui, width, height)
  local doc = ui.document
  return table.concat({
    ui.view.view_mode or "page",
    doc.getDocumentRenderingHash and doc:getDocumentRenderingHash() or 0,
    doc.getVisiblePageNumberCount and doc:getVisiblePageNumberCount() or 1,
    width, height,
  }, ":")
end

function Page.target(ui, number)
  local doc = ui.document
  local current = number == nil
  number = number or doc:getCurrentPage()
  local paged = ui.view.view_mode ~= "scroll"
    and type(doc.getPageFromXPointer) == "function"
    and type(doc.getPageCount) == "function"
  if not current and (not paged or number < 1 or number > doc:getPageCount()) then return end
  local count = doc.getVisiblePageNumberCount and doc:getVisiblePageNumberCount() or 1
  return {
    number = number,
    last = paged and math.min(number + count - 1, doc:getPageCount()) or nil,
    -- Scroll view keeps its existing viewport extraction and position-specific cache.
    id = paged and tostring(number) or (number .. ":" .. doc:getCurrentPos()),
  }
end

function Page.following(ui, target)
  if not target.last then return end
  local doc = ui.document
  local number = doc.getNextPage and doc:getNextPage(target.last) or target.last + 1
  if number <= target.last then return end
  return Page.target(ui, number)
end

function Page.new(ui, target)
  local doc = ui.document
  target = target or Page.target(ui)
  local start = ui.view.view_mode == "scroll" and doc:getXPointer()
    or doc:getPageXPointer(target.number)
  return { cursor = start, words = {}, bytes = 0, steps = 0, target = target }
end

function Page.step(doc, page, batch_size)
  for _ = 1, batch_size or 24 do
    if not page.cursor or page.cursor == "" then return true end
    if page.steps >= MAX_WORDS or page.bytes >= MAX_TEXT_BYTES then
      return true, "Visible text exceeds the safe extraction limit."
    end
    local ending = doc:getNextVisibleWordEnd(page.cursor)
    if not ending or ending == page.cursor then return true end
    local start = doc:getPrevVisibleWordStart(ending)
    if not start then return true end
    local target = page.target
    -- Page numbers work off screen too, without moving the reader or its history.
    -- Include a word straddling the edge, but never walk into the following page.
    if target.last then
      local first_page, last_page = doc:getPageFromXPointer(start), doc:getPageFromXPointer(ending)
      if first_page > target.last and last_page > target.last then return true end
    elseif not doc:isXPointerInCurrentPage(start) and not doc:isXPointerInCurrentPage(ending) then
      return true
    end
    page.cursor = ending
    page.steps = page.steps + 1
    local text = doc:getTextFromXPointers(start, ending)
    if type(text) == "string" and text:find("%S") then
      page.words[#page.words + 1] = { text = text, pos0 = start, pos1 = ending }
      page.bytes = page.bytes + #text
    end
  end
  return false
end

function Page.context(doc, page)
  local words = page.words
  if #words == 0 then return "" end
  -- Retain punctuation and paragraph boundaries for contextual meanings.
  return doc:getTextFromXPointers(words[1].pos0, words[#words].pos1) or ""
end

function Page.boxes(doc, entries, width, height)
  local result = {}
  for _, entry in ipairs(entries) do
    local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, entry.pos0, entry.pos1, true)
    if ok and type(boxes) == "table" then
      for _, box in ipairs(boxes) do
        if type(box.x) == "number" and type(box.y) == "number"
            and type(box.w) == "number" and type(box.h) == "number" then
          local x, y = math.max(0, box.x), math.max(0, box.y)
          local right, bottom = math.min(width, box.x + box.w), math.min(height, box.y + box.h)
          if right > x and bottom > y then
            result[#result + 1] = {
              box = { x = x, y = y, w = right - x, h = bottom - y }, entry = entry,
            }
          end
        end
      end
    end
  end
  return result
end

return Page
