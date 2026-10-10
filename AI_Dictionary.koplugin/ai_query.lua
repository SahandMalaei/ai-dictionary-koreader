local api_key = nil

local success, result = pcall(function() return require("api_key") end)
if success then
  api_key = result.key
else
  print("api_key.lua not found, skipping...")
end

local Config = require("configuration_manager")
local https = require("ssl.https")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local Device = require("device")
local AndroidHttpWorker = require("android_http_worker")
local BackgroundWorker = require("background_worker")
local Parameters = require("request_parameters")

local REQUEST_TIMEOUT_SECONDS = require("constants").network.request_timeout_seconds

https.TIMEOUT = REQUEST_TIMEOUT_SECONDS
http.TIMEOUT = REQUEST_TIMEOUT_SECONDS

local function hasValue(value)
  return type(value) == "string" and value:match("%S") ~= nil
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

local function queryAI(message_history, opts)
  opts = opts or {}

  local configuration = Config.load()
  local api_key_value = hasValue(configuration.api_key) and configuration.api_key or api_key
  local ok, api_url, body = pcall(Parameters.build, configuration, opts.feature, message_history)
  if not ok or not api_url then
    if opts.on_error then opts.on_error(ok and body or "Could not build AI request parameters.") end
    return function() end
  end
  local encoded, requestBody = pcall(function() return json.encode(body) end)
  if not encoded or type(requestBody) ~= "string" then
    if opts.on_error then opts.on_error("Could not encode AI request parameters as JSON.") end
    return function() end
  end

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

    -- JSON null may decode to a non-nil sentinel while the stream is running.
    if choice and hasValue(choice.finish_reason) and choice.finish_reason ~= "null" then
      stream_completed = true
    end

    if type(delta) == "string" and delta ~= "" then
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
