local lfs = require("libs/libkoreader-lfs")

local LOOKUPS_DIR_NAME = "Lookups"
local LOOKUPS_FILE_NAME = "Lookups.txt"

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

local function ensure_dir(path)
  if lfs.attributes(path, "mode") == "directory" then
    return true
  end
  return lfs.mkdir(path)
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    return ""
  end
  local contents = file:read("*all") or ""
  file:close()
  return contents
end

local function first_logged_lookup(contents)
  return contents:match("^%s*%-?%s*Time:[^\r\n]*[\r\n]+%-?%s*Lookup:%s*([^\r\n]*)")
end

local function escape_lua_pattern(value)
  return tostring(value or ""):gsub("(%W)", "%%%1")
end

local function format_context(context, lookup)
  context = tostring(context or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  lookup = tostring(lookup or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if context == "" then
    return ""
  end

  if lookup ~= "" then
    context = context:gsub(escape_lua_pattern(lookup), "***" .. lookup .. "***", 1)
  end

  return context
end

local function save_lookup_entry(plugin_path, lookup, context)
  lookup = tostring(lookup or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if lookup == "" then
    return
  end

  local lookups_dir = path_join(get_plugin_path(plugin_path), LOOKUPS_DIR_NAME)
  local ok, err = ensure_dir(lookups_dir)
  if not ok then
    print("Could not create lookup log directory: " .. tostring(err))
    return
  end

  local lookups_file = path_join(lookups_dir, LOOKUPS_FILE_NAME)
  local old_contents = read_file(lookups_file)
  if first_logged_lookup(old_contents) == lookup then
    return
  end

  local entry = "Time: " .. os.date("%Y-%m-%d") .. "\n"
      .. "Lookup: " .. lookup .. "\n"
      .. "Context: " .. format_context(context, lookup) .. "\n"

  if old_contents ~= "" then
    entry = entry .. "\n" .. old_contents
  end

  local file, write_err = io.open(lookups_file, "w")
  if not file then
    print("Could not write lookup log: " .. tostring(write_err))
    return
  end

  file:write(entry)
  file:close()
end

return save_lookup_entry
