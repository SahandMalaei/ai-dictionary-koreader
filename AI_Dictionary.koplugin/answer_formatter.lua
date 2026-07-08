local AnswerFormatter = {}

local PTF_HEADER = "\u{FFF1}"
local PTF_BOLD_START = "\u{FFF2}"
local PTF_BOLD_END = "\u{FFF3}"

local DICTIONARY_SECTION_LABELS = { "Definition", "Example", "Synonyms", "Paraphrase", "Etymology" }

function AnswerFormatter.ptf_bold(s)
  return PTF_BOLD_START .. s .. PTF_BOLD_END
end

function AnswerFormatter.format_inline_markdown_emphasis(text)
  if type(text) ~= "string" then
    return text
  end

  -- Convert Markdown-style bold/emphasis (**x** or *x*) to KOReader PTF bold markers.
  text = text:gsub("%*%*([^*\r\n]+)%*%*", function(s)
    return AnswerFormatter.ptf_bold(s)
  end)
  text = text:gsub("%*([^*%s][^*\r\n]-)%*", function(s)
    return AnswerFormatter.ptf_bold(s)
  end)

  return text
end

function AnswerFormatter.format_dictionary_output(selection, answer)
  local output = AnswerFormatter.format_inline_markdown_emphasis(answer or "")
  local header = nil
  if selection and selection ~= "" then
    header = PTF_HEADER .. AnswerFormatter.ptf_bold(selection)
  end
  for _, label in ipairs(DICTIONARY_SECTION_LABELS) do
    output = output:gsub("(^%s*)" .. label .. "%s*:", function(prefix)
      return prefix .. AnswerFormatter.ptf_bold(label .. ":")
    end)
    output = output:gsub("([\r\n]%s*)" .. label .. "%s*:", function(prefix)
      return prefix .. AnswerFormatter.ptf_bold(label .. ":")
    end)
  end
  return header, PTF_HEADER .. output
end

function AnswerFormatter.trim_to_dictionary_limit(text, limit)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if #text < limit then
    return text
  end

  while #text >= limit do
    local trimmed = text:gsub("%s+%S+$", "")
    if trimmed == text or trimmed == "" then
      return text:sub(1, limit - 1):gsub("%s+$", "")
    end
    text = trimmed
  end

  return text
end

function AnswerFormatter.find_dictionary_section_boundary(text, after_index)
  local latest_start = nil

  for _, label in ipairs(DICTIONARY_SECTION_LABELS) do
    local search_from = math.max((after_index or 0) + 1, 1)
    while true do
      local start_index, end_index = text:find(label .. "%s*:", search_from)
      if not start_index then
        break
      end

      local line_start = text:sub(1, start_index - 1):match(".*[\r\n]()") or 1
      local before_label = text:sub(line_start, start_index - 1)
      if before_label:match("^%s*$") then
        if not latest_start or start_index > latest_start then
          latest_start = start_index
        end
      end

      search_from = end_index + 1
    end
  end

  return latest_start
end

function AnswerFormatter.append_debug_prompt(answer, prompt)
  if type(prompt) ~= "string" or prompt == "" then
    return answer
  end
  return tostring(answer or "") .. "\n\nDebug: prompt sent to AI\n\n" .. prompt
end

function AnswerFormatter.render_answer(chatgpt_viewer, is_dictionary, display_selection, preface_with_selection, answer, debug_prompt)
  local display_answer = AnswerFormatter.append_debug_prompt(answer, debug_prompt)
  if is_dictionary then
    local header_text, body_text = AnswerFormatter.format_dictionary_output(display_selection, display_answer)
    return chatgpt_viewer:update(body_text, header_text)
  elseif preface_with_selection then
    display_answer = AnswerFormatter.format_inline_markdown_emphasis(display_answer)
    return chatgpt_viewer:update(PTF_HEADER .. string.format("%s %s", display_selection, display_answer))
  else
    display_answer = AnswerFormatter.format_inline_markdown_emphasis(display_answer)
    return chatgpt_viewer:update(PTF_HEADER .. display_answer)
  end
end

return AnswerFormatter
