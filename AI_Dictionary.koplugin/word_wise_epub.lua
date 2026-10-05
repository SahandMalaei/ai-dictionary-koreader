local Page = require("word_wise_page")
local EPUB = {}
EPUB.__index = EPUB

function EPUB.supported(ui)
  return Page.supported(ui) and type(ui.document.getPrevVisibleWordEnd) == "function"
    and type(ui.document.compareXPointers) == "function"
    and type(ui.document.getPageFromXPointer) == "function"
end

function EPUB.new(ui)
  return setmetatable({ ui = ui, doc = ui.document }, EPUB)
end

function EPUB:compare(a, b)
  local order = self.doc:compareXPointers(a, b)
  if order == nil then error("Invalid Word Wise document position") end
  return -order -- KOReader uses +1 for a position BEFORE another position.
end

function EPUB:key(pos) return pos end
function EPUB:page(pos) return self.doc:getPageFromXPointer(pos) end
function EPUB:current_page() return self.doc:getCurrentPage() end

function EPUB:word(ending)
  if not ending or ending == "" then return end
  local start = self.doc:getPrevVisibleWordStart(ending)
  if not start or start == ending then return end
  local text = self.doc:getTextFromXPointers(start, ending)
  if type(text) == "string" and text:find("%S") then
    return { text = text, pos0 = start, pos1 = ending }
  end
end

function EPUB:next(word)
  local cursor = word.pos1
  for _ = 1, 256 do
    local ending = self.doc:getNextVisibleWordEnd(cursor)
    if not ending then return end
    if self:compare(cursor, ending) >= 0 then error("Word navigation did not advance") end
    local next_word = self:word(ending)
    if next_word then return next_word end
    cursor = ending
  end
  error("Too many empty text fragments")
end

function EPUB:after(pos) return self:next({ pos1 = pos }) end

function EPUB:previous(word)
  local cursor = word.pos0
  for _ = 1, 256 do
    local ending = self.doc:getPrevVisibleWordEnd(cursor)
    if not ending then return end
    if self:compare(ending, cursor) >= 0 then error("Word navigation did not advance") end
    local previous = self:word(ending)
    if previous then return previous end
    cursor = ending
  end
  error("Too many empty text fragments")
end

function EPUB:boundary(a, b)
  -- crengine inserts newlines at block/paragraph boundaries, including <br>,
  -- but preserves inline formatting. Include both words, so an empty endpoint
  -- cannot hide a boundary from the engine's range text collector.
  local text = self.doc:getTextFromXPointers(a.pos0, b.pos1)
  if type(text) ~= "string" then error("Could not read paragraph boundary") end
  return text:find("\n", 1, true) ~= nil
end

function EPUB:text(words)
  if #words == 0 then return "" end
  local text = self.doc:getTextFromXPointers(words[1].pos0, words[#words].pos1)
  if type(text) ~= "string" then error("Could not read paragraph text") end
  return text
end

function EPUB:viewport() return Page.new(self.ui) end
function EPUB:step_viewport(page) return Page.step(self.doc, page) end
function EPUB:signature(w, h) return Page.signature(self.ui, w, h) end

function EPUB:boxes(entries, w, h)
  local visible = {}
  for _, entry in ipairs(entries) do
    local ok, intersects = pcall(function()
      if self.ui.view.view_mode ~= "scroll" then
        local first, last = self:page(entry.pos0), self:page(entry.pos1)
        local count = self.doc.getVisiblePageNumberCount and self.doc:getVisiblePageNumberCount() or 1
        local current = self:current_page()
        return first <= current + count - 1 and last >= current
      end
      if type(self.doc.getPosFromXPointer) == "function" then
        local first = self.doc:getPosFromXPointer(entry.pos0)
        local last = self.doc:getPosFromXPointer(entry.pos1)
        local top = self.doc:getCurrentPos()
        return first <= top + h and last >= top
      end
      return self.doc:isXPointerInCurrentPage(entry.pos0) or self.doc:isXPointerInCurrentPage(entry.pos1)
    end)
    if ok and intersects then
      visible[#visible + 1] = entry
    end
  end
  return Page.boxes(self.doc, visible, w, h)
end

return EPUB
