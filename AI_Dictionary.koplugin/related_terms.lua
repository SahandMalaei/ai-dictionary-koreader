local RelatedTerms = {}

local METADATA_OPEN = "<aidictionary-related>"
local METADATA_CLOSE = "</aidictionary-related>"
local MAX_TERMS = 3
local MAX_TERM_BYTES = 80

RelatedTerms.prompt_suffix = [[

Before the user-visible answer, output one machine-readable metadata line in exactly this form:
<aidictionary-related>term 1 | term 2 | term 3</aidictionary-related>
If Wikipedia metadata was also requested, put this line immediately after the Wikipedia metadata line. Otherwise put it first.
Suggest between 0 and 3 concise words, names, or search terms that are directly relevant next steps for understanding the current subject, its role in the book, or an important closely related concept. Prefer specific, meaningful concepts that genuinely reward a deeper explanation. Do not suggest generic, merely associated, repetitive, tangential, spoiler-revealing, or random terms. Do not repeat any item already present in the deep-dive path. If no strong next step exists, output None inside the tags. Use plain text only; separate multiple terms with " | ". Do not mention these suggestions in the user-visible answer.]]

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parse_terms(value)
  value = trim(value)
  if value == "" or value:lower() == "none" then
    return {}
  end

  local terms = {}
  local seen = {}
  for term in (value .. "|"):gmatch("(.-)|") do
    term = trim(term)
    local normalized = term:lower()
    if term ~= ""
        and #term <= MAX_TERM_BYTES
        and not term:find("[\r\n<>]")
        and not seen[normalized] then
      terms[#terms + 1] = term
      seen[normalized] = true
      if #terms >= MAX_TERMS then break end
    end
  end
  return terms
end

function RelatedTerms.parse_response(response)
  if type(response) ~= "string" then
    return nil, "", false
  end
  local start_at = response:find(METADATA_OPEN, 1, true)
  if not start_at then
    return nil, "", false
  end
  local value_start = start_at + #METADATA_OPEN
  local close_at = response:find(METADATA_CLOSE, value_start, true)
  if not close_at then
    return nil, "", false
  end

  local terms = parse_terms(response:sub(value_start, close_at - 1))
  local visible = response:sub(1, start_at - 1) .. response:sub(close_at + #METADATA_CLOSE)
  visible = visible:gsub("^[\r\n%s]+", "")
  return terms, visible, true
end

function RelatedTerms.strip_metadata_fallback(response)
  response = tostring(response or "")
  local start_at = response:find(METADATA_OPEN, 1, true)
  if not start_at then return response end
  local close_at = response:find(METADATA_CLOSE, start_at + #METADATA_OPEN, true)
  if close_at then
    return (response:sub(1, start_at - 1) ..
        response:sub(close_at + #METADATA_CLOSE)):gsub("^[\r\n%s]+", "")
  end
  local line_end = response:find("\n", start_at, true)
  if line_end then
    return (response:sub(1, start_at - 1) .. response:sub(line_end + 1)):gsub("^[\r\n%s]+", "")
  end
  return response:sub(1, start_at - 1):gsub("%s+$", "")
end

return RelatedTerms
