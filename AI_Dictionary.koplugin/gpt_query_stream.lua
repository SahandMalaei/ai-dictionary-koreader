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

local REQUEST_TIMEOUT_SECONDS = 20

https.TIMEOUT = REQUEST_TIMEOUT_SECONDS
http.TIMEOUT = REQUEST_TIMEOUT_SECONDS

local function isOpenRouterUrl(url)
  return type(url) == "string" and url:lower():find("openrouter.ai", 1, true) ~= nil
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

local function buildRequestBody(message_history, configuration, request_parameters)
  local api_url = configuration and (configuration.text_endpoint or configuration.provider) or "https://api.openai.com/v1/chat/completions"
  local llm = configuration and (configuration.text_model or configuration.model) or "gpt-5-nano"

  local requestBodyTable = {
    model = llm,
    messages = message_history,
  }

  if isOpenRouterUrl(api_url) then
    requestBodyTable.provider = {
      sort = "latency"
    }
  end

  if configuration and configuration.additional_parameters then
    for key, value in pairs(configuration.additional_parameters) do
      requestBodyTable[key] = value
    end
  end

  if isOpenRouterUrl(api_url) and request_parameters then
    for key, value in pairs(request_parameters) do
      requestBodyTable[key] = value
    end
  end

  requestBodyTable.reasoning_effort = "none"
  requestBodyTable.verbosity = "low"
  requestBodyTable.stream = true

  return api_url, json.encode(requestBodyTable)
end

local function queryChatGPTStream(message_history, opts)
  opts = opts or {}

  local configuration = loadConfiguration()
  local api_key_value = configuration and configuration.api_key or api_key
  if not api_key_value or api_key_value == "" then
    if opts.on_error then opts.on_error("No API key configured.") end
    return function() end
  end

  local api_url, requestBody = buildRequestBody(message_history, configuration, opts.request_parameters)
  local accumulated = ""
  local token_count = 0
  local response_buffer = ""
  local cancelled = false
  local done = false

  local function handlePayload(payload)
    if payload == "[DONE]" then
      done = true
      return
    end

    local ok_json, obj = pcall(function() return json.decode(payload) end)
    local delta = ok_json
        and obj
        and obj.choices
        and obj.choices[1]
        and obj.choices[1].delta
        and obj.choices[1].delta.content

    if delta and delta ~= "" then
      accumulated = accumulated .. delta
      token_count = token_count + countTokens(delta)
      if opts.on_delta then opts.on_delta(delta, accumulated, token_count) end
    end
  end

  local responseBody = {}
  local sink = function(chunk)
    if cancelled then
      return nil, "cancelled"
    end
    if not chunk then
      return 1
    end

    table.insert(responseBody, chunk)
    response_buffer = parseSseBuffer(response_buffer .. chunk, handlePayload)
    return 1
  end

  local ok, code = https.request {
    url = api_url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#requestBody),
      ["Accept"] = "text/event-stream",
      ["Authorization"] = "Bearer " .. api_key_value,
    },
    source = ltn12.source.string(requestBody),
    sink = sink,
  }

  if cancelled then
    return function() end
  end

  if (code == "wantread" or code == "timeout") and accumulated ~= "" then
    if opts.on_done then
      opts.on_done(accumulated)
    end
  elseif tostring(code) ~= "200" then
    if opts.on_error then
      opts.on_error(tostring(code) .. "\n\nResponse: " .. table.concat(responseBody))
    end
  elseif opts.on_done then
    opts.on_done(accumulated)
  end

  return function()
    cancelled = true
  end
end

return queryChatGPTStream
