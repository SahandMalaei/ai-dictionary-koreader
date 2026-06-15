local api_key = nil

-- Attempt to load the api_key module. IN A LATER VERSION, THIS WILL BE REMOVED
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

-- Define your queryChatGPT function
local https = require("ssl.https")
local http = require("socket.http") -- needed to cap the pre-SSL socket connect phase
local ltn12 = require("ltn12")
local json = require("json")

local REQUEST_TIMEOUT_SECONDS = 20

https.TIMEOUT = REQUEST_TIMEOUT_SECONDS -- cap reads once the TLS session exists
http.TIMEOUT = REQUEST_TIMEOUT_SECONDS -- also cap DNS lookup + TCP connect latency

local function isOpenRouterUrl(url)
  return type(url) == "string" and url:lower():find("openrouter.ai", 1, true) ~= nil
end

local function isOpenAIUrl(url)
  return type(url) == "string" and url:lower():find("api.openai.com", 1, true) ~= nil
end

local function isGpt5Model(model)
  return type(model) == "string" and model:lower():match("^gpt%-5") ~= nil
end

local function queryChatGPT(message_history)
  local configuration = loadConfiguration()
  local api_key_value = configuration and configuration.api_key or api_key
  local api_url = configuration and configuration.provider or "https://api.openai.com/v1/chat/completions"
  local llm = configuration and configuration.model or "gpt-5-nano"

  local requestBodyTable = {
    model = llm,
    --reasoning_effort = "minimal",
    --verbosity = "low",
    messages = message_history
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

  local requestBody = json.encode(requestBodyTable)

  local headers = {
    ["Content-Type"] = "application/json",
    ["Content-Length"] = tostring(#requestBody),
    ["Authorization"] = "Bearer " .. api_key_value,
  }

  local responseBody = {}

  local ok, code, responseHeaders, status_line = https.request {
    url = api_url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(requestBody),
    sink = ltn12.sink.table(responseBody)
  }

  if tostring(code) ~= "200" then
    return "Error querying AI: " .. tostring(code) .. "\n\nResponse: " .. table.concat(responseBody) .. "\n\nRequest: " .. tostring(requestBody)
  else
    local response = json.decode(table.concat(responseBody))
    return response.choices[1].message.content-- .. "\n\nRequest: " .. tostring(requestBody)
  end
end

return queryChatGPT
