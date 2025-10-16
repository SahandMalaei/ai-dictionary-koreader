local lfs = require("lfs")
local DataStorage = require("datastorage")

local logger = require("logger")

local function dirname(path)
  return path:match("^(.*)[/\\][^/\\]+$") or "."
end

local function joinpath(a, b)
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
  return a .. "/" .. b
end

local function ensure_dir(path)
  local attr = lfs.attributes(path)
  if not attr then lfs.mkdir(path) end
end

local function prepend_file(path, new_text)
  local old = ""
  local f = io.open(path, "rb")
  if f then
    old = f:read("*a") or ""
    f:close()
  end

  local body = new_text
  if old ~= "" then
    if not body:match("\n$") then body = body .. "\n" end
    body = body .. "\n" .. old
  end

  local tmp = path .. ".tmp"
  local tf, error = io.open(tmp, "wb")
  if not tf and error then
    logger.err("AI Lookups file open failed:" .. path .. error)
  end
  if not tf then return end
  tf:write(body)
  tf:close()

  os.remove(path)
  os.rename(tmp, path)
end

local function save_lookup_entry(doc_path, doc_title, lookup_type, selection)
  local book_dir   = dirname(doc_path)
  local lookups_dir = joinpath(book_dir, "AI Lookups")
  ensure_dir(lookups_dir)

  local log_filename = string.format("%s - AI Lookups.txt", doc_title)
  local log_path = joinpath(lookups_dir, log_filename)

  local ts = os.date("%Y-%m-%d %H:%M")
  local header = string.format("%s\n%s", ts, lookup_type)

  local selection_line = selection and (("\n'%s'\n"):format(selection)) or "\n"
  local entry = string.format(
    "%s%s\n",
    header,
    selection_line
  )

  prepend_file(log_path, entry)
end

return save_lookup_entry