local api_key = nil
local CONFIGURATION = nil

-- Attempt to load the api_key module. IN A LATER VERSION, THIS WILL BE REMOVED
local success, result = pcall(function() return require("api_key") end)
if success then
  api_key = result.key
else
  print("api_key.lua not found, skipping...")
end

-- Attempt to load the configuration module
success, result = pcall(function() return require("configuration") end)
if success then
  CONFIGURATION = result
else
  print("configuration.lua not found, skipping...")
end

-- Define your queryChatGPT function
local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")

local function queryChatGPT(message_history)
  -- Use api_key from CONFIGURATION or fallback to the api_key module
  local api_key_value = CONFIGURATION and CONFIGURATION.api_key or api_key
  --local api_url = "https://api.openai.com/v1/chat/completions"
  local api_url = "https://openrouter.ai/api/v1/chat/completions"
  --local model = "gpt-5-nano"
  local model = "google/gemini-2.5-flash-lite"

  -- Start building the request body
  local requestBodyTable = {
    --model = "gpt-5-mini",
    model = "google/gemini-2.5-flash-lite",
    --reasoning_effort = "minimal",
    --verbosity = "low",
    messages = message_history
  }

  -- Add additional parameters if they exist
  if CONFIGURATION and CONFIGURATION.additional_parameters then
    for key, value in pairs(CONFIGURATION.additional_parameters) do
      requestBodyTable[key] = value
    end
  end

  -- Encode the request body as JSON
  local requestBody = json.encode(requestBodyTable)

  local headers = {
    ["Content-Type"] = "application/json",
    --["Content-Length"] = tostring(#requestBody),
    ["Authorization"] = "Bearer " .. api_key_value,
  }

  local responseBody = {}

  -- Make the HTTPS request
  https.TIMEOUT = 10

  local ok, code, responseHeaders, status_line = https.request {
    url = api_url,
    method = "POST",
    headers = headers,
    source = ltn12.source.string(requestBody),
    sink = ltn12.sink.table(responseBody),
  }

  if tostring(code) ~= "200" then
    return "Error querying ChatGPT API: " .. tostring(code) .. "\n\nResponse: " .. table.concat(responseBody) .. "\n\nRequest: " .. tostring(requestBody)
  else
    local response = json.decode(table.concat(responseBody))
    return response.choices[1].message.content-- .. "\n\nRequest: " .. tostring(requestBody)
  end
end

return queryChatGPT