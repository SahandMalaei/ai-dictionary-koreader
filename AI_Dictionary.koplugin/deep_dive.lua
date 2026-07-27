local DeepDive = {}

local function trim(text)
  return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function DeepDive.term_at(charlist, bold_chars, char_index, current_focus)
  if charlist == nil or type(bold_chars) ~= "table"
      or type(char_index) ~= "number" then
    return nil
  end

  if not bold_chars[char_index] and bold_chars[char_index - 1] then
    char_index = char_index - 1
  end
  if not bold_chars[char_index] then
    return nil
  end

  local start_index = char_index
  local end_index = char_index
  while bold_chars[start_index - 1] do
    start_index = start_index - 1
  end
  while bold_chars[end_index + 1] do
    end_index = end_index + 1
  end

  local term
  if type(charlist.getText) == "function" then
    term = charlist:getText(start_index, end_index)
  else
    term = table.concat(charlist, "", start_index, end_index)
  end
  term = trim(term)
  if term == "" or term == trim(current_focus) then
    return nil
  end
  return term
end

function DeepDive.build_prompt(path)
  if type(path) ~= "table" or #path == 0 then
    return nil
  end

  local focus = tostring(path[#path] or "")
  return "Deep dive journey: " .. table.concat(path, " -> ") .. ".\n" ..
      "Continue the AI Explain journey by explaining the current focus, '" .. focus .. "', " ..
      "in relation to the original highlighted text, its book context, and the previous steps. " ..
      "No spoilers if it's fiction. Use Markdown emphasis (*x*) when it helps understanding. " ..
      "Keep your explanation brief (under 90 words, ONLY ONE PARAGRAPH), and ask no questions at the end."
end

return DeepDive
