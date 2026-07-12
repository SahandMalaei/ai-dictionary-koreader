local ConfigurationManager = {}

ConfigurationManager.CORE_CONFIGURATION_KEYS = {
  "api_key",
  "text_endpoint",
  "text_model",
  "voice_endpoint",
  "voice_model",
  "voice_voice",
  "images",
  "update_check",
  "debug_mode",
}

ConfigurationManager.CORE_CONFIGURATION_KEY_SET = {
  api_key = true,
  text_endpoint = true,
  text_model = true,
  voice_endpoint = true,
  voice_model = true,
  voice_voice = true,
  images = true,
  debug_mode = true,
  update_check = true,
}

ConfigurationManager.BOOLEAN_CONFIGURATION_KEYS = {
  debug_mode = true,
  images = true,
  update_check = true,
}

ConfigurationManager.DEPRECATED_CONFIGURATION_KEYS = {
  provider = true,
  model = true,
  voice_api_key = true,
  voice_provider = true,
}

ConfigurationManager.CONFIGURATION_LABELS = {
  api_key = "API key",
  text_endpoint = "Text endpoint URL",
  text_model = "Text model",
  additional_parameters = "Additional parameters",
  voice_endpoint = "Voice endpoint URL",
  voice_model = "Voice model",
  voice_voice = "Voice",
  tts_speed = "Voice speed",
  images = "Show images",
  debug_mode = "Debug mode",
  update_check = "Check for updates",
}

function ConfigurationManager.get_configuration_path(plugin)
  local base_path = plugin and plugin.path
  if base_path and base_path ~= "" then
    return base_path .. "/configuration.lua"
  end
  return "AI_Dictionary.koplugin/configuration.lua"
end

function ConfigurationManager.normalize(configuration)
  if configuration.text_endpoint == nil then
    configuration.text_endpoint = configuration.provider
  end
  if configuration.text_model == nil then
    configuration.text_model = configuration.model
  end
  if configuration.update_check == nil then
    configuration.update_check = true
  end
  if configuration.images == nil then
    configuration.images = true
  end
  return configuration
end

function ConfigurationManager.load()
  package.loaded["configuration"] = nil
  local ok, config = pcall(function() return require("configuration") end)
  if ok and type(config) == "table" then
    return ConfigurationManager.normalize(config)
  end
  return ConfigurationManager.normalize({
    api_key = "",
    text_endpoint = "https://api.openai.com/v1/chat/completions",
    text_model = "gpt-5-nano",
    images = true,
    update_check = true,
  })
end

function ConfigurationManager.is_debug_mode_enabled()
  local configuration = ConfigurationManager.load()
  return configuration and configuration.debug_mode == true
end

function ConfigurationManager.is_update_check_enabled()
  local configuration = ConfigurationManager.load()
  return not configuration or configuration.update_check ~= false
end

function ConfigurationManager.is_images_enabled()
  local configuration = ConfigurationManager.load()
  return not configuration or configuration.images ~= false
end

local function is_array(value)
  if type(value) ~= "table" then
    return false
  end

  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
  end
  return count == #value
end

function ConfigurationManager.is_lua_identifier(value)
  return type(value) == "string" and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

function ConfigurationManager.serialize_lua_value(value, indent)
  indent = indent or ""
  local value_type = type(value)

  if value_type == "string" then
    return string.format("%q", value)
  elseif value_type == "number" or value_type == "boolean" then
    return tostring(value)
  elseif value_type == "table" then
    local next_indent = indent .. "    "
    local lines = { "{" }

    if is_array(value) then
      for _, item in ipairs(value) do
        table.insert(lines, next_indent .. ConfigurationManager.serialize_lua_value(item, next_indent) .. ",")
      end
    else
      local keys = {}
      for key, _ in pairs(value) do
        table.insert(keys, key)
      end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

      for _, key in ipairs(keys) do
        local key_text
        if ConfigurationManager.is_lua_identifier(key) then
          key_text = key
        else
          key_text = "[" .. ConfigurationManager.serialize_lua_value(key, next_indent) .. "]"
        end
        table.insert(lines, next_indent .. key_text .. " = " .. ConfigurationManager.serialize_lua_value(value[key], next_indent) .. ",")
      end
    end

    table.insert(lines, indent .. "}")
    return table.concat(lines, "\n")
  elseif value == nil then
    return "nil"
  end

  return "nil"
end

function ConfigurationManager.serialize_configuration(configuration)
  local lines = { "local CONFIGURATION = {" }
  local written = {}

  local function write_key(key)
    if configuration[key] ~= nil then
      local key_text
      if ConfigurationManager.is_lua_identifier(key) then
        key_text = key
      else
        key_text = "[" .. ConfigurationManager.serialize_lua_value(key, "    ") .. "]"
      end
      table.insert(lines, "    " .. key_text .. " = " .. ConfigurationManager.serialize_lua_value(configuration[key], "    ") .. ",")
      written[key] = true
    end
  end

  for _, key in ipairs(ConfigurationManager.CORE_CONFIGURATION_KEYS) do
    write_key(key)
  end

  local keys = {}
  for key, _ in pairs(configuration) do
    if not written[key] and not ConfigurationManager.DEPRECATED_CONFIGURATION_KEYS[key] then
      table.insert(keys, key)
    end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  for _, key in ipairs(keys) do
    write_key(key)
  end

  table.insert(lines, "}")
  table.insert(lines, "")
  table.insert(lines, "return CONFIGURATION")
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

function ConfigurationManager.parse_lua_literal(input)
  local loader = loadstring or load
  local chunk, compile_error = loader("return " .. tostring(input or ""))
  if not chunk then
    return nil, compile_error
  end

  local ok, value = pcall(chunk)
  if not ok then
    return nil, value
  end
  return value
end

function ConfigurationManager.display_value(key, value)
  if value == nil then
    return "Not set"
  end
  if type(value) == "string" and value:match("%S") == nil then
    return "Not set"
  end
  if key == "api_key" and type(value) == "string" and value ~= "" then
    if #value <= 10 then
      return "set"
    end
    return value:sub(1, 6) .. "..." .. value:sub(-4)
  end
  if type(value) == "table" then
    return ConfigurationManager.serialize_lua_value(value):gsub("\n", " ")
  end
  return tostring(value)
end

function ConfigurationManager.save(plugin, configuration)
  local configuration_path = ConfigurationManager.get_configuration_path(plugin)
  local file, err = io.open(configuration_path, "w")
  if not file then
    return false, err
  end

  file:write(ConfigurationManager.serialize_configuration(configuration))
  file:close()
  package.loaded["configuration"] = nil
  return true
end

return ConfigurationManager
