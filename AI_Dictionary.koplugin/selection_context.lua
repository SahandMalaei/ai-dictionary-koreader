local Device = require("device")
local Screen = Device.screen

local function selection_to_text(sel)
  if type(sel) == "string" then return sel end
  if type(sel) ~= "table" then return tostring(sel) end

  -- Some backends give { text="...", ... }
  if sel.text then return sel.text end

  local out = {}

  local function collect(t)
    for _, v in ipairs(t) do
      if type(v) == "string" then
        table.insert(out, v)
      elseif type(v) == "table" then
        -- common field names you’ll see
        if v.text then table.insert(out, v.text) end
        if v.t    then table.insert(out, v.t)    end
        if v.s    then table.insert(out, v.s)    end
        if v.str  then table.insert(out, v.str)  end
        if v.value then table.insert(out, v.value) end
        -- nested containers
        if v.spans    then collect(v.spans)    end
        if v.segments then collect(v.segments) end
        if v.lines    then collect(v.lines)    end
      end
    end
  end

  collect(sel)
  return table.concat(out, "")
end

local function get_page_text(document)
  return selection_to_text(document:getTextFromPositions({x = 0, y = 0},
    {x = Screen:getWidth(), y = Screen:getHeight()}, true))
end

function get_selection_in_context2(document, selection, window)
    window = window or 5 -- number of words before/after
    local page_text = get_page_text(document)
    if not page_text or not selection or selection == "" then
        return ""
    end

    -- escape any magic characters from selection for pattern search
    local safe_selection = selection:gsub("([^%w%s])", "%%%1")

    -- find the selection inside the page text
    local start_pos, end_pos = page_text:find(safe_selection)
    if not start_pos then
        return '"' .. selection .. '"' -- fallback if not found
    end

    -- split text into words
    local words = {}
    for w in page_text:gmatch("%S+") do
        table.insert(words, w)
    end

    -- find the index of the selected text among words
    local selection_index
    for i, w in ipairs(words) do
        if w:find(safe_selection, 1, true) then
            selection_index = i
            break
        end
    end

    if not selection_index then
        return '"' .. selection .. '"'
    end

    -- get before and after words
    local start_idx = math.max(1, selection_index - window)
    local end_idx = math.min(#words, selection_index + window)

    local before = table.concat(words, " ", start_idx, selection_index - 1)
    local after = table.concat(words, " ", selection_index + 1, end_idx)

    local context = string.format("%s {%s} %s", before, selection, after)
    return context
end

function get_selection_in_context(document, selection, window)
    window = window or 10
    local page_text = get_page_text(document)
    if not page_text or not selection or selection == "" then
        return ""
    end

    -- Escape Lua pattern chars in selection
    local function escape_lua_pattern(s)
        return (s:gsub("([%%%^%$%(%)%[%]%.%*%+%-%?])", "%%%1"))
    end

    local safe = escape_lua_pattern(selection)

    -- Find the exact selection (first occurrence)
    local s_pos, e_pos = page_text:find(safe)
    if not s_pos then
        -- Fallback if not found
        return '"' .. selection .. '"'
    end

    local before_text = page_text:sub(1, s_pos - 1)
    local after_text  = page_text:sub(e_pos + 1)

    -- Collect up to N tokens from the end of before_text
    local before_tokens = {}
    for tok in before_text:gmatch("%S+") do
        before_tokens[#before_tokens + 1] = tok
    end
    local before_start = math.max(1, #before_tokens - window + 1)
    local before = table.concat(before_tokens, " ", before_start, #before_tokens)

    -- Collect up to N tokens from the start of after_text
    local after_tokens, count = {}, 0
    for tok in after_text:gmatch("%S+") do
        after_tokens[#after_tokens + 1] = tok
        count = count + 1
        if count >= window then break end
    end
    local after = table.concat(after_tokens, " ")

    -- Build output with no extra spaces if before/after are empty
    local left  = (before ~= "" and (before .. "") or "")
    local right = (after  ~= "" and ("" .. after)  or "")

    return left .. ' {{{ ' .. selection .. ' }}} ' .. right
end

return get_selection_in_context