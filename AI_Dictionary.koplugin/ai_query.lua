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
local _ = require("plugin_i18n")
local RequestTimeout = require("request_timeout")

local logger
do
  local ok, required_logger = pcall(require, "logger")
  if ok then
    logger = required_logger
  else
    logger = {
      warn = function() end,
      err = function() end,
    }
  end
end

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
    default_reasoning_effort = "minimal",
    matches = function(url)
      return urlContains(url, "api.openai.com")
    end,
  },
  {
    id = "openrouter",
    supports_verbosity = true,
    supports_request_parameters = true,
    default_reasoning_effort = "none",
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
  id = "openai_compatible",
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

local function consumeSseEvent(event, on_payload)
  for line in event:gmatch("[^\r\n]+") do
    if line:sub(1, 5) == "data:" then
      on_payload(line:sub(6):match("^%s*(.-)%s*$"))
    end
  end
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

    consumeSseEvent(buffer:sub(1, sep_start - 1), on_payload)
    buffer = buffer:sub(sep_end + 1)
  end

  return buffer
end

local function isFinishReason(value)
  return type(value) == "string" and value ~= "" and value ~= "null"
end

local function choiceContent(choice)
  if type(choice) ~= "table" then
    return nil
  end
  local message = choice.message
  if type(message) == "table" and hasValue(message.content) then
    return message.content
  end
  local delta = choice.delta
  if type(delta) == "table" and hasValue(delta.content) then
    return delta.content
  end
  if hasValue(choice.text) then
    return choice.text
  end
  return nil
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
    if opts.on_error then opts.on_error(_("No API key configured.")) end
    return function() end
  end

  local accumulated = ""
  local token_count = 0
  local response_buffer = ""
  local response_body = {}
  local response_code = nil
  local android_response_length = 0
  local stream_completed = false
  local network_timeout = RequestTimeout.hard_seconds()
  https.TIMEOUT = network_timeout
  http.TIMEOUT = network_timeout

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

    if choice and isFinishReason(choice.finish_reason) then
      stream_completed = true
    end

    local delta = choice
        and choice.delta
        and choice.delta.content

    if hasValue(delta) then
      accumulated = accumulated .. delta
      token_count = token_count + countTokens(delta)
      if opts.on_delta then opts.on_delta(delta, accumulated, token_count) end
    elseif not hasValue(accumulated) then
      local content = choiceContent(choice)
      if content then
        accumulated = content
        token_count = token_count + countTokens(content)
        if opts.on_delta then opts.on_delta(content, accumulated, token_count) end
      end
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
    if response_buffer ~= "" then
      consumeSseEvent(response_buffer, handlePayload)
      response_buffer = ""
    end

    if not hasValue(accumulated) then
      local body = table.concat(response_body)
      local ok_json, obj = pcall(function() return json.decode(body) end)
      if ok_json and type(obj) == "table" then
        local content = choiceContent(obj.choices and obj.choices[1])
        if content then
          accumulated = content
          stream_completed = true
        end
      end
    end

    local http_ok = response_code == "200"
        or response_code == "wantread"
        or response_code == "timeout"
    local usable = hasValue(accumulated)

    if not http_ok then
      if opts.on_error then
        opts.on_error(tostring(response_code) .. "\n\nResponse: " .. table.concat(response_body))
      end
      return
    end

    if usable then
      if not stream_completed then
        logger.warn("AI Dictionary: stream ended without a finish marker; using received content")
      end
      if opts.on_done then
        opts.on_done(accumulated)
      end
      return
    end

    if opts.on_error then
      opts.on_error(_("Incomplete AI response: the connection ended before the stream completed."))
    end
  end

  local function recover_or_error(err)
    if response_buffer ~= "" then
      consumeSseEvent(response_buffer, handlePayload)
      response_buffer = ""
    end
    if hasValue(accumulated) then
      logger.warn("AI Dictionary: recovering streamed content after: " .. tostring(err))
      if opts.on_done then
        opts.on_done(accumulated)
      end
      return
    end
    if opts.on_error then
      opts.on_error(err)
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
      timeout_seconds = network_timeout,
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
      on_error = function(err, full_response)
        if type(full_response) == "string" and #full_response > android_response_length then
          handle_message("C" .. full_response:sub(android_response_length + 1))
          android_response_length = #full_response
        end
        recover_or_error(err)
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
    on_error = recover_or_error,
  })
end

return queryAI
