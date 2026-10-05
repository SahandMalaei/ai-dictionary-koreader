-- Layout-independent queries: finish paragraphs until strictly over 300 words.
local Chunk = {}
local WORD_THRESHOLD = 300
-- Fail closed on corrupt or extraordinarily large input; never query a partial
-- paragraph or silently cache truncated coverage.
local MAX_STEPS = 50000
local MAX_BYTES = 2 * 1024 * 1024

function Chunk.new(source, word)
  return { source = source, cursor = word, phase = "back", words = {},
    paragraph = {}, count = 0, steps = 0, bytes = 0 }
end

local function finish_paragraph(chunk)
  if #chunk.paragraph == 0 then return end
  local text = chunk.source:text(chunk.paragraph):gsub("\194\160", " ")
  for word in text:gmatch("%S+") do
    if word:find("[%w\128-\255]") then chunk.count = chunk.count + 1 end
  end
  chunk.paragraph = {}
end

local function finish(chunk)
  finish_paragraph(chunk)
  local words = chunk.words
  if #words > 0 then
    chunk.pos0, chunk.pos1 = words[1].pos0, words[#words].pos1
    chunk.id = chunk.source:key(chunk.pos0)
    chunk.context = chunk.source:text(words)
  end
  return true
end

function Chunk.step(chunk, batch_size)
  local source = chunk.source
  for _ = 1, batch_size or 24 do
    chunk.steps = chunk.steps + 1
    if chunk.steps > MAX_STEPS or chunk.bytes > MAX_BYTES then
      return true, "Paragraph exceeds the safe extraction limit."
    end
    if chunk.phase == "back" then
      local previous = source:previous(chunk.cursor)
      if not previous or source:boundary(previous, chunk.cursor) then
        chunk.phase = "forward"
      else
        chunk.cursor = previous
      end
    else
      local word = chunk.cursor
      if not word then return finish(chunk) end
      local previous = chunk.words[#chunk.words]
      if previous and source:boundary(previous, word) then
        finish_paragraph(chunk)
        if chunk.count > WORD_THRESHOLD then return finish(chunk) end
      end
      chunk.words[#chunk.words + 1] = word
      chunk.paragraph[#chunk.paragraph + 1] = word
      chunk.bytes = chunk.bytes + #word.text
      chunk.cursor = source:next(word)
    end
  end
  return false
end

return Chunk
