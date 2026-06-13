local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local util = require("util")

local REQUEST_TIMEOUT_SECONDS = 10
local REPO_OWNER = "SahandMalaei"
local REPO_NAME = "ai-dictionary-koreader"
local LATEST_RELEASE_URL = "https://api.github.com/repos/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/releases/latest"
local PLUGIN_DIR_NAME = "AI_Dictionary.koplugin"

https.TIMEOUT = REQUEST_TIMEOUT_SECONDS
http.TIMEOUT = REQUEST_TIMEOUT_SECONDS

local Updater = {}

local function show_message(text, timeout)
  UIManager:show(InfoMessage:new {
    text = text,
    timeout = timeout or 3,
  })
end

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

local function normalize_version(version)
  version = tostring(version or ""):gsub("^v", "")
  local parts = {}
  for part in version:gmatch("%d+") do
    table.insert(parts, tonumber(part) or 0)
  end
  return parts
end

local function compare_versions(left, right)
  local left_parts = normalize_version(left)
  local right_parts = normalize_version(right)
  local length = math.max(#left_parts, #right_parts)
  for i = 1, length do
    local left_part = left_parts[i] or 0
    local right_part = right_parts[i] or 0
    if left_part < right_part then
      return -1
    elseif left_part > right_part then
      return 1
    end
  end
  return 0
end

local function get_current_version(plugin_dir)
  local meta_path = path_join(plugin_dir, "_meta.lua")
  local file = io.open(meta_path, "r")
  if file then
    local contents = file:read("*all")
    file:close()

    local quoted_version = contents:match("version%s*=%s*[\"']([^\"']+)[\"']")
    if quoted_version then
      return quoted_version
    end

    local numeric_version = contents:match("version%s*=%s*([%d%.]+)")
    if numeric_version then
      return numeric_version
    end
  end

  package.loaded["_meta"] = nil
  local ok, meta = pcall(function() return require("_meta") end)
  if ok and meta and meta.version then
    return tostring(meta.version)
  end
  return "0"
end

local function http_get(url)
  local response = {}
  local ok, code = https.request {
    url = url,
    method = "GET",
    headers = {
      ["Accept"] = "application/vnd.github+json",
      ["User-Agent"] = "AI-Dictionary-KOReader",
    },
    sink = ltn12.sink.table(response),
  }

  if tostring(code) ~= "200" then
    return nil, "HTTP " .. tostring(code) .. " from " .. url
  end

  return table.concat(response)
end

local function download_file(url, destination)
  local file, err = io.open(destination, "wb")
  if not file then
    return nil, err
  end

  local ok, code = https.request {
    url = url,
    method = "GET",
    headers = {
      ["Accept"] = "application/zip",
      ["User-Agent"] = "AI-Dictionary-KOReader",
    },
    sink = ltn12.sink.file(file),
  }

  if tostring(code) ~= "200" then
    os.remove(destination)
    return nil, "HTTP " .. tostring(code) .. " while downloading update"
  end

  return true
end

local function shell_escape(path)
  if util.shell_escape then
    return util.shell_escape({ path })
  end
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

local function run_command(command)
  local result = os.execute(command)
  if result == true or result == 0 then
    return true
  end
  return nil, "Command failed: " .. command
end

local function remove_tree(path)
  if not path or path == "" or path == "/" then
    return nil, "Refusing to remove unsafe path"
  end
  return run_command("rm -rf " .. shell_escape(path))
end

local function copy_file(source, destination)
  local input, input_err = io.open(source, "rb")
  if not input then
    return nil, input_err
  end

  local output, output_err = io.open(destination, "wb")
  if not output then
    input:close()
    return nil, output_err
  end

  while true do
    local chunk = input:read(8192)
    if not chunk then
      break
    end
    output:write(chunk)
  end

  input:close()
  output:close()
  return true
end

local function relative_path(base, path)
  return path:sub(#base + 2)
end

local function is_preserved_config(relative)
  return relative == "configuration.lua"
      or relative:match("/configuration%.lua$") ~= nil
end

local function is_updater_temp(relative)
  return relative:match("^%.update%-") ~= nil
end

local function find_extracted_plugin_dir(root)
  local found
  util.findFiles(root, function(path)
    if path:match("/" .. PLUGIN_DIR_NAME .. "/_meta%.lua$") then
      found = path:match("^(.*)/_meta%.lua$")
    end
  end, true)
  return found
end

local function ensure_parent_dir(path)
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then
    return util.makePath(parent)
  end
  return true
end

local function collect_files(root)
  local files = {}
  util.findFiles(root, function(path)
    files[relative_path(root, path)] = path
  end, true)
  return files
end

local function prune_empty_dirs(root)
  local dirs = {}
  local function scan(dir)
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then
      return
    end
    for name in iter, dir_obj do
      if name ~= "." and name ~= ".." then
        local path = path_join(dir, name)
        if lfs.attributes(path, "mode") == "directory" then
          scan(path)
          table.insert(dirs, path)
        end
      end
    end
  end

  scan(root)
  table.sort(dirs, function(a, b) return #a > #b end)
  for _, dir in ipairs(dirs) do
    pcall(function()
      if util.isEmptyDir(dir) then
        lfs.rmdir(dir)
      end
    end)
  end
end

local function apply_update(plugin_dir, extracted_plugin_dir)
  local new_files = collect_files(extracted_plugin_dir)
  local old_files = collect_files(plugin_dir)

  for relative, old_path in pairs(old_files) do
    if not new_files[relative] and not is_preserved_config(relative) and not is_updater_temp(relative) then
      os.remove(old_path)
    end
  end

  for relative, source_path in pairs(new_files) do
    if not is_preserved_config(relative) then
      local destination = path_join(plugin_dir, relative)
      local ok, err = ensure_parent_dir(destination)
      if not ok then
        return nil, err
      end

      ok, err = copy_file(source_path, destination)
      if not ok then
        return nil, err
      end
    end
  end

  prune_empty_dirs(plugin_dir)
  return true
end

local function get_latest_release()
  local body, err = http_get(LATEST_RELEASE_URL)
  if not body then
    return nil, err
  end

  local ok, release = pcall(function() return json.decode(body) end)
  if not ok or type(release) ~= "table" then
    return nil, "Could not parse latest release response"
  end

  if not release.tag_name then
    return nil, "Latest release has no tag_name"
  end

  return release
end

function Updater:new(plugin)
  return setmetatable({
    plugin = plugin,
    checked = false,
  }, { __index = self })
end

function Updater:getPluginDir()
  if self.plugin and self.plugin.path and self.plugin.path ~= "" then
    return self.plugin.path
  end
  return PLUGIN_DIR_NAME
end

function Updater:checkOnStartup()
  if self.checked then
    return
  end
  self.checked = true

  if not NetworkMgr:isOnline() then
    return
  end

  UIManager:scheduleIn(2, function()
    local release, err = get_latest_release()
    if not release then
      return
    end

    local current_version = get_current_version(self:getPluginDir())
    local latest_version = tostring(release.tag_name):gsub("^v", "")
    if compare_versions(current_version, latest_version) >= 0 then
      return
    end

    self:promptForUpdate(current_version, latest_version, release.tag_name)
  end)
end

function Updater:promptForUpdate(current_version, latest_version, tag_name)
  UIManager:show(ConfirmBox:new {
    text = "AI Dictionary " .. latest_version .. " is available.\n\nInstalled version: "
        .. tostring(current_version) .. "\n\nUpdate now?",
    ok_text = "Update",
    ok_callback = function()
      show_message("Updating AI Dictionary...", 2)
      UIManager:scheduleIn(0.1, function()
        local ok, err = self:updateToTag(tag_name)
        if ok then
          self:showRestartDialog()
        else
          show_message("AI Dictionary update failed:\n" .. tostring(err), 8)
        end
      end)
    end,
  })
end

function Updater:updateToTag(tag_name)
  local plugin_dir = self:getPluginDir()
  local tmp_root = path_join(plugin_dir, ".update-" .. tostring(os.time()))
  local extract_dir = path_join(tmp_root, "extract")
  local zip_path = path_join(tmp_root, "release.zip")
  local zip_url = "https://codeload.github.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/zip/refs/tags/" .. tostring(tag_name)

  local ok, err = util.makePath(extract_dir)
  if not ok then
    return nil, err
  end

  ok, err = download_file(zip_url, zip_path)
  if not ok then
    remove_tree(tmp_root)
    return nil, err
  end

  ok, err = run_command("unzip -q " .. shell_escape(zip_path) .. " -d " .. shell_escape(extract_dir))
  if not ok then
    remove_tree(tmp_root)
    return nil, err .. "\nThe device may not have the unzip command."
  end

  local extracted_plugin_dir = find_extracted_plugin_dir(extract_dir)
  if not extracted_plugin_dir then
    remove_tree(tmp_root)
    return nil, "Could not find " .. PLUGIN_DIR_NAME .. " in release archive"
  end

  ok, err = apply_update(plugin_dir, extracted_plugin_dir)
  remove_tree(tmp_root)
  if not ok then
    return nil, err
  end

  return true
end

function Updater:showRestartDialog()
  UIManager:show(ButtonDialog:new {
    title = "AI Dictionary was updated.\n\nPlease quit and restart KOReader to load the new version.",
    dismissable = false,
    buttons = {
      {
        {
          text = "Quit",
          callback = function()
            UIManager:quit()
          end,
        },
      },
    },
  })
end

return Updater
