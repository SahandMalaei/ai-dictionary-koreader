local function clean_context_part(value)
  if value == nil then
    return ""
  end
  return tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
end

local function build_context(before, selection, after)
  selection = clean_context_part(selection)
  if selection == "" then
    return ""
  end

  before = clean_context_part(before)
  after = clean_context_part(after)

  local parts = {}
  if before ~= "" then
    parts[#parts + 1] = before
  end
  parts[#parts + 1] = "{{{ " .. selection .. " }}}"
  if after ~= "" then
    parts[#parts + 1] = after
  end

  return table.concat(parts, " ")
end

local function get_selection_in_context(reader_highlight_instance, selection, window)
  window = window or 10

  if not reader_highlight_instance
      or type(reader_highlight_instance.getSelectedWordContext) ~= "function" then
    return build_context(nil, selection, nil)
  end

  local ok, before, after = pcall(function()
    return reader_highlight_instance:getSelectedWordContext(window)
  end)

  if not ok then
    return build_context(nil, selection, nil)
  end

  return build_context(before, selection, after)
end

return get_selection_in_context
