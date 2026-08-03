local PopupLookup = {}

local DEFAULT_CONTEXT_RADIUS = 180

local function trim(text)
  return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function char_count(charlist)
  if type(charlist) == "table" then
    return #charlist
  end
  local ok, count = pcall(function() return #charlist end)
  return ok and count or 0
end

local function char_text(charlist, start_index, end_index)
  if not charlist or start_index > end_index then return "" end
  if type(charlist.getText) == "function" then
    return charlist:getText(start_index, end_index)
  end
  return table.concat(charlist, "", start_index, end_index)
end

function PopupLookup.clean_selection(text)
  text = trim(text)
  -- TextBoxWidget deliberately includes separators at word edges. Remove
  -- punctuation surrounding a word/phrase while preserving punctuation inside it.
  text = text:gsub("^[%p%s]+", ""):gsub("[%p%s]+$", "")
  local unicode_edges = { "«", "»", "‘", "’", "“", "”", "–", "—" }
  local changed = true
  while changed and text ~= "" do
    changed = false
    for _, edge in ipairs(unicode_edges) do
      if text:sub(1, #edge) == edge then
        text = trim(text:sub(#edge + 1))
        changed = true
      end
      if text:sub(-#edge) == edge then
        text = trim(text:sub(1, -#edge - 1))
        changed = true
      end
    end
  end
  return trim(text)
end

function PopupLookup.context_from_charlist(charlist, start_index, end_index, radius)
  local count = char_count(charlist)
  if count == 0 or type(start_index) ~= "number" or type(end_index) ~= "number" then
    return ""
  end
  if start_index > end_index then
    start_index, end_index = end_index, start_index
  end
  start_index = math.max(1, math.min(count, start_index))
  end_index = math.max(start_index, math.min(count, end_index))
  radius = radius or DEFAULT_CONTEXT_RADIUS

  local context_start = math.max(1, start_index - radius)
  local context_end = math.min(count, end_index + radius)
  local before = char_text(charlist, context_start, start_index - 1)
  local selected = char_text(charlist, start_index, end_index)
  local after = char_text(charlist, end_index + 1, context_end)
  local context = (context_start > 1 and "…" or "") .. before ..
      "{{{ " .. selected .. " }}}" .. after .. (context_end < count and "…" or "")
  return trim(context:gsub("%s+", " "))
end

return PopupLookup
