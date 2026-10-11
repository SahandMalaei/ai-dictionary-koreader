-- Verify model-selected text against native positions. Never guess beyond five
-- characters from either endpoint, or accept an ambiguous nearby occurrence.
local Anchor = {}
local TOLERANCE = 5

local function normalize(text)
  if type(text) ~= "string" then return end
  return (text:gsub("\194\160", " "):gsub("\194\173", ""):gsub("%s+", " "))
end

local function character_count(text)
  local _, count = text:gsub("[^\128-\191]", "")
  return count
end

local function nearby(source, pos)
  local positions, seen = { pos }, { [0] = true }
  for _, direction in ipairs({ -1, 1 }) do
    local move = direction < 0 and source.doc.getPrevVisibleChar or source.doc.getNextVisibleChar
    if type(move) == "function" then
      local cursor = pos
      -- Crossing inline nodes may advance the XPointer without consuming a
      -- character. Measure the extracted text, and deduplicate those boundaries.
      -- Keep a separate step cap for pathological chains of empty DOM nodes.
      for _ = 1, (TOLERANCE + 1) * 8 do
        local next_pos = move(source.doc, cursor)
        if not next_pos or next_pos == "" then break end
        if source:compare(cursor, next_pos) ~= -direction then
          error("Character navigation did not advance")
        end
        local a, b = pos, next_pos
        if direction < 0 then a, b = next_pos, pos end
        local distance = character_count(source.doc:getTextFromXPointers(a, b))
        if distance > TOLERANCE then break end
        local offset = direction * distance
        if not seen[offset] then
          positions[#positions + 1], seen[offset] = next_pos, true
        end
        cursor = next_pos
      end
    end
  end
  return positions
end

local function reflowable(source, first, last, target)
  local function matches(a, b)
    return source:compare(a, b) < 0 and normalize(source.doc:getTextFromXPointers(a, b)) == target
  end
  if matches(first.pos0, last.pos1) then return { pos0 = first.pos0, pos1 = last.pos1 } end
  local starts, endings = nearby(source, first.pos0), nearby(source, last.pos1)
  local found
  for _, a in ipairs(starts) do
    for _, b in ipairs(endings) do
      if matches(a, b) then
        if found then return end
        found = { pos0 = a, pos1 = b }
      end
    end
  end
  return found
end

local function slice(words, first, last)
  local result = {}
  for i = first, last do result[#result + 1] = words[i] end
  return result
end

local function fixed_entry(words)
  local positions = {}
  for i, word in ipairs(words) do positions[i] = word.pos0 end
  return { pos0 = words[1].pos0, pos1 = words[#words].pos1, positions = positions }
end

local function fixed(source, words, first, last, target)
  local selected = slice(words, first, last)
  if normalize(source:text(selected)) == target then return fixed_entry(selected) end
  -- Fixed text layers expose whole-word boxes, so only whole-word endpoints
  -- can be rendered faithfully. Measure movement in raw Unicode characters.
  local window, start_index, end_index = selected, 1, #selected
  for _ = 1, TOLERANCE do
    local previous = source:previous(window[1])
    if not previous then break end
    table.insert(window, 1, previous)
    start_index, end_index = start_index + 1, end_index + 1
    local prefix = source:text(slice(window, 1, start_index))
    if character_count(prefix) - character_count(words[first].text) > TOLERANCE then break end
  end
  for _ = 1, TOLERANCE do
    local following = source:next(window[#window])
    if not following then break end
    window[#window + 1] = following
    local suffix = source:text(slice(window, end_index, #window))
    if character_count(suffix) - character_count(words[last].text) > TOLERANCE then break end
  end
  local starts, endings = {}, {}
  for i = 1, #window do
    local a, b = math.min(i, start_index), math.max(i, start_index)
    local distance = character_count(source:text(slice(window, a, b))) - character_count(window[b].text)
    if distance <= TOLERANCE then starts[#starts + 1] = i end
    a, b = math.min(i, end_index), math.max(i, end_index)
    distance = character_count(source:text(slice(window, a, b))) - character_count(window[a].text)
    if distance <= TOLERANCE then endings[#endings + 1] = i end
  end
  local found
  for _, a in ipairs(starts) do
    for _, b in ipairs(endings) do
      if a <= b then
        local candidate = slice(window, a, b)
        if normalize(source:text(candidate)) == target then
          if found then return end
          found = fixed_entry(candidate)
        end
      end
    end
  end
  return found
end

function Anchor.resolve(source, words, first, last, text)
  if not source or type(text) ~= "string" or #text > 4096
      or text:find("[%z\1-\8\11\12\14-\31]") then return end
  local target = normalize(text):match("^%s*(.-)%s*$")
  if target == "" then return end
  local ok, entry = pcall(function()
    if type(words[first].pos0) == "string" then
      return reflowable(source, words[first], words[last], target)
    end
    return fixed(source, words, first, last, target)
  end)
  if ok then return entry end -- A bad document range suppresses only this entry.
end

function Anchor.overlaps(source, a, b)
  local left = source:compare(a.pos0, b.pos1)
  local right = source:compare(b.pos0, a.pos1)
  if type(a.pos0) == "table" then return left <= 0 and right <= 0 end
  return left < 0 and right < 0
end

return Anchor
