local TIMEFRAMES = {
  { label = "Today", days = 1 },
  { label = "3 Days", days = 3 },
  { label = "7 Days", days = 7 },
  { label = "1 Month", days = 31 },
  { label = "3 Months", days = 92 },
  { label = "1 Year", days = 366 },
  { label = "All Time", days = nil },
}

local function path_join(...)
  local parts = { ... }
  local result = tostring(parts[1] or "")
  for i = 2, #parts do
    local part = tostring(parts[i] or "")
    if result:sub(-1) == "/" then
      result = result .. part:gsub("^/+", "")
    else
      result = result .. "/" .. part:gsub("^/+", "")
    end
  end
  return result
end

local function get_plugin_path(plugin_path)
  if plugin_path and plugin_path ~= "" then
    return plugin_path
  end
  return "AI_Dictionary.koplugin"
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local contents = file:read("*all") or ""
  file:close()
  return contents
end

local function date_to_time(date)
  local year, month, day = tostring(date or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not year then
    return nil
  end

  return os.time {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = 0,
    min = 0,
    sec = 0,
  }
end

local function today_start()
  local now = os.date("*t")
  return os.time {
    year = now.year,
    month = now.month,
    day = now.day,
    hour = 0,
    min = 0,
    sec = 0,
  }
end

local function cutoff_for_timeframe(timeframe)
  if not timeframe or not timeframe.days then
    return nil
  end

  return today_start() - ((timeframe.days - 1) * 86400)
end

local function parse_entries(contents)
  local entries = {}
  local current = nil
  contents = tostring(contents or ""):gsub("\r\n", "\n"):gsub("\r", "\n")

  for line in (contents .. "\n"):gmatch("(.-)\n") do
    if line == "" then
      if current then
        table.insert(entries, current)
        current = nil
      end
    else
      local date = line:match("^%-?%s*Time:%s*(.-)%s*$")
      if date then
        if current then
          table.insert(entries, current)
        end
        current = { date = date }
      elseif current then
        local lookup = line:match("^%-?%s*Lookup:%s*(.-)%s*$")
        local context = line:match("^%-?%s*Context:%s*(.-)%s*$")
        if lookup then
          current.lookup = lookup
        elseif context then
          current.context = context
        end
      end
    end
  end

  if current then
    table.insert(entries, current)
  end

  return entries
end

local function filter_entries(entries, timeframe)
  local cutoff = cutoff_for_timeframe(timeframe)
  if not cutoff then
    return entries
  end

  local filtered = {}
  for _, entry in ipairs(entries) do
    local entry_time = date_to_time(entry.date)
    if entry.lookup and entry.lookup ~= "" and entry_time and entry_time >= cutoff then
      table.insert(filtered, entry)
    end
  end
  return filtered
end

local function format_entries_for_prompt(entries)
  local lines = {}
  for _, entry in ipairs(entries) do
    if entry.lookup and entry.lookup ~= "" then
      table.insert(lines, "Lookup: " .. entry.lookup)
      if entry.context and entry.context ~= "" then
        table.insert(lines, "Context: " .. entry.context)
      end
      table.insert(lines, "")
    end
  end

  return table.concat(lines, "\n"):gsub("%s+$", "")
end

local function build_prompt(entries, timeframe)
  return "Analyze these AI Dictionary lookups from the timeframe '" .. timeframe.label .. "'. " ..
      "Use only the attached lookup data. Generate a concise language learning report in exactly this format:\n\n" ..
      "Number of lookups: x\n\n" ..
      "Main pattern:\n" ..
      "[Find a pattern in the lookups, something that has learning value]\n\n" ..
      "Practice:\n" ..
      "[Up to 10 fill-in-the-blank questions (as long as there are enough lookups) with the most useful lookups]\n" ..
      "Answers: [the answers to the questions, separated by commas and each preceded by a number (e.g. 1. x, 2. y, etc.). make sure the answers are adapted to the context of the questions.]\n\n" ..
      "Attached lookups, without dates:\n\n" ..
      format_entries_for_prompt(entries)
end

local function load_entries(plugin_path, timeframe)
  local lookups_file = path_join(get_plugin_path(plugin_path), "Lookups", "Lookups.txt")
  local contents = read_file(lookups_file)
  if not contents or contents == "" then
    return {}
  end
  local entries = parse_entries(contents)
  if not timeframe or not timeframe.days then
    local valid_entries = {}
    for _, entry in ipairs(entries) do
      if entry.lookup and entry.lookup ~= "" then
        table.insert(valid_entries, entry)
      end
    end
    return valid_entries
  end
  return filter_entries(entries, timeframe)
end

return {
  TIMEFRAMES = TIMEFRAMES,
  load_entries = load_entries,
  build_prompt = build_prompt,
}
