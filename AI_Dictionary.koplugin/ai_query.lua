local api_key = nil

local success, result = pcall(function() return require("api_key") end)
if success then
  api_key = result.key
else
  print("api_key.lua not found, skipping...")
end

local function loadConfiguration()
  package.loaded["configuration"] = nil
  local ok, config = pcall(function() return require("configuration") end)
  if ok then
    return config
  end

  print("configuration.lua not found, skipping...")
  return nil
end

local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local Device = require("device")
local AndroidHttpWorker = require("android_http_worker")
local BackgroundWorker = require("background_worker")

local REQUEST_TIMEOUT_SECONDS = 20

https.TIMEOUT = REQUEST_TIMEOUT_SECONDS
http.TIMEOUT = REQUEST_TIMEOUT_SECONDS

local function hasValue(value)
  return type(value) == "string" and value:match("%S") ~= nil
end

local function urlContains(url, needle)
  return type(url) == "string" and url:lower():find(needle, 1, true) ~= nil
end

local ENDPOINT_PROFILES = {
  {
    id = "openai",
    supports_verbosity = true,
    default_reasoning_effort = "medium",
    matches = function(url)
      return urlContains(url, "api.openai.com")
    end,
  },
  {
    id = "groq",
    default_reasoning_effort = "medium",
    matches = function(url)
      return urlContains(url, "api.groq.com")
    end,
  },
  {
    id = "openrouter",
    supports_verbosity = true,
    supports_request_parameters = true,
    default_reasoning_effort = "medium",
    matches = function(url)
      return urlContains(url, "openrouter.ai")
    end,
    apply_body_defaults = function(requestBodyTable)
      requestBodyTable.provider = requestBodyTable.provider or {
        sort = "latency"
      }
    end,
  },
}

local DEFAULT_ENDPOINT_PROFILE = {
  id = "groq",
}

local function getEndpointProfile(api_url, configuration)
  local configured_id = configuration and (configuration.text_endpoint_type or configuration.endpoint_type)

  if hasValue(configured_id) then
    for _, profile in ipairs(ENDPOINT_PROFILES) do
      if profile.id == configured_id then
        return profile
      end
    end
  end

  for _, profile in ipairs(ENDPOINT_PROFILES) do
    if profile.matches and profile.matches(api_url) then
      return profile
    end
  end

  return DEFAULT_ENDPOINT_PROFILE
end

local function isHttpUrl(url)
  return type(url) == "string" and url:lower():sub(1, 7) == "http://"
end

local function getRequestClient(url)
  if isHttpUrl(url) then
    return http.request
  end
  return https.request
end

local function buildHeaders(requestBody, api_key_value)
  local headers = {
    ["Content-Type"] = "application/json",
    ["Content-Length"] = tostring(#requestBody),
    ["Accept"] = "text/event-stream",
  }

  if hasValue(api_key_value) then
    headers["Authorization"] = "Bearer " .. api_key_value
  end

  return headers
end

local function countTokens(text)
  if not text or text == "" then
    return 0
  end

  local count = 0
  for _ in text:gmatch("%S+") do
    count = count + 1
  end
  return count
end

local function parseSseBuffer(buffer, on_payload)
  while true do
    local sep_start, sep_end = buffer:find("\n\n", 1, true)
    local crlf_start, crlf_end = buffer:find("\r\n\r\n", 1, true)

    if crlf_start and (not sep_start or crlf_start < sep_start) then
      sep_start = crlf_start
      sep_end = crlf_end
    end

    if not sep_start then
      break
    end

    local event = buffer:sub(1, sep_start - 1)
    buffer = buffer:sub(sep_end + 1)

    for line in event:gmatch("[^\r\n]+") do
      if line:sub(1, 5) == "data:" then
        on_payload(line:sub(6):match("^%s*(.-)%s*$"))
      end
    end
  end

  return buffer
end

local function copyParameters(target, source)
  if not source then
    return
  end

  for key, value in pairs(source) do
    target[key] = value
  end
end

local function applyDefaultParameters(requestBodyTable, endpointProfile, request_parameters)
  endpointProfile = endpointProfile or DEFAULT_ENDPOINT_PROFILE

  if endpointProfile.apply_body_defaults then
    endpointProfile.apply_body_defaults(requestBodyTable)
  end

  if endpointProfile.supports_request_parameters then
    copyParameters(requestBodyTable, request_parameters)
  end

 if endpointProfile.default_reasoning_effort and requestBodyTable.reasoning_effort == nil then
    requestBodyTable.reasoning_effort = endpointProfile.default_reasoning_effort
  end

  if endpointProfile.supports_verbosity and requestBodyTable.verbosity == nil then
    requestBodyTable.verbosity = "low"
  end
end

local function buildRequestBody(message_history, configuration, request_parameters)
  local api_url = configuration and (configuration.text_endpoint or configuration.provider) or "https://api.openai.com/v1/chat/completions"
  local llm = configuration and (configuration.text_model or configuration.model) or "gpt-5-nano"
  local endpointProfile = getEndpointProfile(api_url, configuration)

  local requestBodyTable = {
    model = llm,
    messages = message_history,
  }

  copyParameters(requestBodyTable, configuration and configuration.additional_parameters)
  
  applyDefaultParameters(requestBodyTable, endpointProfile, request_parameters)
  requestBodyTable.stream = true

  return api_url, json.encode(requestBodyTable)
end

local function queryAI(message_history, opts)
  opts = opts or {}

  local configuration = loadConfiguration()
  local api_key_value = configuration and configuration.api_key or api_key
  local api_url, requestBody = buildRequestBody(message_history, configuration, opts.request_parameters)

  if not hasValue(api_key_value) and not isHttpUrl(api_url) then
    if opts.on_error then opts.on_error("No API key configured.") end
    return function() end
  end

  local accumulated = ""
  local token_count = 0
  local response_buffer = ""
  local response_body = {}
  local response_code = nil
  local android_response_length = 0
  local stream_completed = false

  local function handlePayload(payload)
    if payload == "[DONE]" then
      stream_completed = true
      return
    end

    local ok_json, obj = pcall(function() return json.decode(payload) end)
    local choice = ok_json
        and obj
        and obj.choices
        and obj.choices[1]
    local delta = choice
        and choice.delta
        and choice.delta.content

    if choice and choice.finish_reason ~= nil then
      stream_completed = true
    end

    if delta and delta ~= "" then
      accumulated = accumulated .. delta
      token_count = token_count + countTokens(delta)
      if opts.on_delta then opts.on_delta(delta, accumulated, token_count) end
    end
  end

  local function handle_message(message)
    local kind = message:sub(1, 1)
    local payload = message:sub(2)
    if kind == "C" then
      response_body[#response_body + 1] = payload
      response_buffer = parseSseBuffer(response_buffer .. payload, handlePayload)
    elseif kind == "R" then
      response_code = payload
    end
  end

  local function finish_request()
    if response_code ~= "200" and response_code ~= "wantread" and response_code ~= "timeout" then
      if opts.on_error then
        opts.on_error(tostring(response_code) .. "\n\nResponse: " .. table.concat(response_body))
      end
    elseif not stream_completed then
      if opts.on_error then
        opts.on_error("Incomplete AI response: the connection ended before the stream completed.")
      end
    elseif opts.on_done then
      opts.on_done(accumulated)
    end
  end

  if Device.isAndroid and Device:isAndroid() then
    return AndroidHttpWorker.start({
      url = api_url,
      method = "POST",
      authorization = hasValue(api_key_value) and ("Bearer " .. api_key_value) or "",
      content_type = "application/json",
      accept = "text/event-stream",
      body = requestBody,
      timeout_seconds = REQUEST_TIMEOUT_SECONDS,
    }, {
      on_progress = function(full_response)
        if #full_response <= android_response_length then return end
        local chunk = full_response:sub(android_response_length + 1)
        android_response_length = #full_response
        handle_message("C" .. chunk)
      end,
      on_complete = function(code, full_response)
        if #full_response > android_response_length then
          handle_message("C" .. full_response:sub(android_response_length + 1))
          android_response_length = #full_response
        end
        response_code = tostring(code)
        finish_request()
      end,
      on_error = function(err)
        if opts.on_error then opts.on_error(err) end
      end,
    })
  end

  return BackgroundWorker.start(function(emit)
    local request_client = getRequestClient(api_url)
    local _, code = request_client {
      url = api_url,
      method = "POST",
      headers = buildHeaders(requestBody, api_key_value),
      source = ltn12.source.string(requestBody),
      sink = function(chunk)
        if chunk then emit("C" .. chunk) end
        return 1
      end,
    }
    emit("R" .. tostring(code))
  end, {
    on_message = handle_message,
    on_complete = finish_request,
    on_error = function(err)
      if opts.on_error then opts.on_error(err) end
    end,
  })
end

return queryAI
