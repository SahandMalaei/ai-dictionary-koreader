local Parameters = {}

Parameters.FEATURES = { "dictionary", "explain", "word_sense" }
Parameters.EFFORTS = { "", "none", "minimal", "low", "medium", "high", "xhigh", "max" }

local function text(value)
  return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

-- Add providers here; ordinary Chat Completions providers share one adapter.
local providers = {
  ["api.openai.com"] = "openai",
  ["openrouter.ai"] = "openrouter",
  ["eu.openrouter.ai"] = "openrouter",
  ["us.openrouter.ai"] = "openrouter",
  ["generativelanguage.googleapis.com"] = "gemini",
  ["api.x.ai"] = "xai",
  ["api.mistral.ai"] = "mistral",
  ["api.deepseek.com"] = "deepseek",
  ["api.groq.com"] = "groq",
  ["ollama.com"] = "ollama",
}
local formats = {
  openai = "reasoning_effort", openrouter = "reasoning", gemini = "reasoning_effort",
  xai = "reasoning_effort", mistral = "reasoning_effort", deepseek = "thinking",
  groq = "reasoning_effort", ollama = "reasoning_effort",
}

function Parameters.provider(endpoint, configuration)
  local authority, path = text(endpoint):lower():match("^https?://([^/]+)(/[^?#]*)")
  if not authority or not path:match("/chat/completions/?$") then return end
  local override = text(configuration and (configuration.text_endpoint_type or configuration.endpoint_type))
  -- An explicit unknown type disables detection, including for reverse proxies.
  if override ~= "" then return formats[override] and override or nil end
  local host = authority:match("^([^:]+):?%d*$")
  if providers[host] then
    if providers[host] == "gemini" and not path:match("/openai/chat/completions/?$") then return end
    return providers[host]
  end
  if authority:match(":11434$") then return "ollama" end
end

function Parameters.decode(raw, key)
  if raw == nil or raw == "" then return {} end
  if type(raw) ~= "string" then return nil, key .. " must be a JSON string." end
  raw = text(raw)
  if raw == "" then return {} end
  if raw:sub(1, 1) ~= "{" then return nil, key .. " must contain a JSON object." end
  -- KOReader's LuaJSON strict mode preserves array markers and null sentinels.
  local ok, value = pcall(function() return require("json").decode(raw, true) end)
  if not ok or type(value) ~= "table" then return nil, "Invalid JSON object in " .. key .. "." end
  return value
end

local function copy(target, source)
  if type(source) ~= "table" then return end
  -- Replace whole top-level values: never mutate configuration or decoded objects.
  for key, value in pairs(source) do target[key] = value end
end

local function has_reasoning(parameters)
  for _, key in ipairs({ "reasoning_effort", "reasoning", "thinking", "think",
      "enable_thinking", "thinking_budget" }) do
    if parameters[key] ~= nil then return true end
  end
  local extra = parameters.extra_body
  local google = type(extra) == "table" and extra.google
  return type(google) == "table" and google.thinking_config ~= nil
end

local function reasoning(provider, effort)
  if effort == "" or not provider then return {} end
  if formats[provider] == "reasoning" then return { reasoning = { effort = effort } } end
  if formats[provider] == "thinking" then
    if effort == "none" then return { thinking = { type = "disabled" } } end
    return { thinking = { type = "enabled" }, reasoning_effort = effort }
  end
  return { reasoning_effort = effort }
end

function Parameters.build(configuration, feature, messages)
  configuration = configuration or {}
  feature = feature or "dictionary"
  local known = false
  for _, name in ipairs(Parameters.FEATURES) do if name == feature then known = true end end
  if not known then return nil, "Unknown request feature: " .. tostring(feature) end
  local key = feature .. "_parameters_json"
  local custom, err = Parameters.decode(configuration[key], key)
  if not custom then return nil, err end
  local endpoint = text(configuration.text_endpoint or configuration.provider)
  if endpoint == "" then endpoint = "https://api.openai.com/v1/chat/completions" end
  local parameters = {}
  -- Existing shared Lua parameters remain supported; feature JSON wins.
  copy(parameters, configuration.additional_parameters)
  copy(parameters, custom)
  local body = {}
  if not has_reasoning(parameters) then
    copy(body, reasoning(Parameters.provider(endpoint, configuration),
      text(configuration[feature .. "_reasoning_effort"])))
  end
  copy(body, parameters)
  local model = text(configuration[feature .. "_model"])
  if model == "" then model = text(configuration.text_model or configuration.model) end
  if model == "" then model = "gpt-5-nano" end
  -- Feature model settings and transport fields cannot be overridden by JSON.
  body.model, body.messages, body.stream = model, messages, true
  return endpoint, body
end

return Parameters
