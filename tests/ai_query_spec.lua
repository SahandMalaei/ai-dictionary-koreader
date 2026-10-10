-- Run from the repository root: luajit tests/ai_query_spec.lua
-- Real builder; JSON decoding and KOReader networking are mocked.
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path
local configuration, body, request, callbacks, encode_error
local decoded = {}
package.preload.configuration = function() return configuration end
package.preload.api_key = function() return {} end
package.loaded["ssl.https"], package.loaded["socket.http"], package.loaded.ltn12 = {}, {}, {}
package.loaded.json = {
  encode = function(value)
    if encode_error then error("encoder failed") end
    body = value; return "encoded request"
  end,
  decode = function(value, strict)
    if value == "thinking" then return { choices = { { delta = { reasoning = "internal reasoning" } } } } end
    if value == "answer" then return { choices = { { delta = { content = '{"entries":[]}' } } } } end
    assert(strict == true and decoded[value], "invalid JSON")
    return decoded[value]
  end,
}
package.loaded.device = { isAndroid = function() return true end }
package.loaded.constants = { network = { request_timeout_seconds = 60 } }
package.loaded.background_worker = {}
package.loaded.android_http_worker = { start = function(options, handlers)
  request, callbacks = options, handlers
  return function() end
end }
local query, Parameters = require("ai_query"), require("request_parameters")
local messages = { { role = "user", content = "test" } }
local router, unknown = "https://openrouter.ai/api/v1/chat/completions", "http://localhost:8080/v1/chat/completions"
local endpoints = {
  openai = "https://api.openai.com/v1/chat/completions", openrouter = router,
  gemini = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
  xai = "https://api.x.ai/v1/chat/completions", mistral = "https://api.mistral.ai/v1/chat/completions",
  deepseek = "https://api.deepseek.com/chat/completions", groq = "https://api.groq.com/openai/v1/chat/completions",
  ollama = "http://localhost:11434/v1/chat/completions",
}
local function send(config, feature)
  configuration, request = config, nil
  configuration.api_key, configuration.text_model = "test-key", configuration.text_model or "text-model"
  local err
  assert(type(query(messages, { feature = feature, on_error = function(e) err = e end })) == "function")
  assert(not err and request, tostring(err))
  assert(request.body == "encoded request" and body.stream == true and body.messages == messages)
  return body
end
for id, endpoint in pairs(endpoints) do
  assert(Parameters.provider(endpoint) == id)
  for _, feature in ipairs(Parameters.FEATURES) do
    for _, empty in ipairs({ "", "  " }) do
      local config = { text_endpoint = endpoint }; config[feature .. "_reasoning_effort"] = empty
      send(config, feature)
      assert(body.reasoning == nil and body.reasoning_effort == nil and body.thinking == nil)
      assert(body.provider == nil and body.plugins == nil and body.verbosity == nil)
    end
    send({ text_endpoint = endpoint }, feature); assert(body.reasoning == nil and body.reasoning_effort == nil)
    local config = { text_endpoint = endpoint }; config[feature .. "_reasoning_effort"] = "low"
    send(config, feature)
    if id == "openrouter" then assert(body.reasoning.effort == "low" and body.reasoning_effort == nil)
    else assert(body.reasoning_effort == "low" and body.reasoning == nil) end
    if id == "deepseek" then assert(body.thinking.type == "enabled") end
  end
end
send({ text_endpoint = endpoints.deepseek, dictionary_reasoning_effort = "none" })
assert(body.thinking.type == "disabled" and body.reasoning_effort == nil)
for _, endpoint in ipairs({ unknown, "https://api.openai.com.evil.test/v1/chat/completions",
    "https://evil.test/v1/chat/completions?target=openrouter.ai", "https://api.openai.com/v1/responses",
    "http://localhost:11434/api/chat", "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent" }) do
  send({ text_endpoint = endpoint, dictionary_reasoning_effort = "high" })
  assert(body.reasoning == nil and body.reasoning_effort == nil and body.thinking == nil)
end
assert(Parameters.provider("https://eu.openrouter.ai/api/v1/chat/completions") == "openrouter")
assert(Parameters.provider("http://192.168.1.2:11434/v1/chat/completions") == "ollama")
send({ text_endpoint = unknown, text_endpoint_type = "openrouter", dictionary_reasoning_effort = "low" })
assert(body.reasoning.effort == "low")
send({ text_endpoint = router, text_endpoint_type = "unknown", dictionary_reasoning_effort = "low" })
assert(body.reasoning == nil)

local config = { text_endpoint = router, dictionary_model = " dictionary-model ",
  explain_model = "explain-model", word_sense_model = "word-sense-model",
  dictionary_reasoning_effort = "low", explain_reasoning_effort = "high",
  additional_parameters = { temperature = 0.2, provider = { sort = "latency", only = { "shared" } } },
  dictionary_parameters_json = '{"provider":{"order":["google"]}}',
  explain_parameters_json = '{"provider":{"sort":"price"},"plugins":[{"id":"web"}]}',
  word_sense_parameters_json = '{"provider":{"only":["sense"]}}',
}
decoded[config.dictionary_parameters_json] = { provider = { order = { "google" } } }
decoded[config.explain_parameters_json] = { provider = { sort = "price" }, plugins = { { id = "web" } } }
decoded[config.word_sense_parameters_json] = { provider = { only = { "sense" } } }
send(config, "dictionary")
assert(body.model == "dictionary-model" and body.reasoning.effort == "low" and body.temperature == 0.2)
assert(body.provider.order[1] == "google" and body.provider.sort == nil and body.provider.only == nil)
send(config, "explain")
assert(body.model == "explain-model" and body.reasoning.effort == "high" and body.plugins[1].id == "web")
send(config, "word_sense")
assert(body.model == "word-sense-model" and body.provider.only[1] == "sense" and body.provider.sort == nil)
assert(body.reasoning == nil and body.plugins == nil and config.additional_parameters.provider.sort == "latency")
send(config, "dictionary"); assert(body.provider.order[1] == "google" and body.plugins == nil)
for _, feature in ipairs(Parameters.FEATURES) do
  config[feature .. "_model"] = " "; send(config, feature); assert(body.model == "text-model")
end

for _, custom in ipairs({ { reasoning = { enabled = false, max_tokens = 0 } }, { reasoning_effort = "high" },
    { thinking = { type = "disabled" } }, { enable_thinking = false }, { think = false },
    { extra_body = { google = { thinking_config = { thinking_budget = 2048 } } } } }) do
  decoded['{"custom":true}'] = custom
  send({ text_endpoint = router, dictionary_reasoning_effort = "low", dictionary_parameters_json = '{"custom":true}' })
  assert(body.reasoning == custom.reasoning and body.reasoning_effort == custom.reasoning_effort)
end
send({ text_endpoint = router, dictionary_reasoning_effort = "low", additional_parameters = { reasoning = { enabled = false } } })
assert(body.reasoning.enabled == false and body.reasoning.effort == nil)
-- Preserve decoder-provided type markers and sentinels instead of rebuilding nested objects.
local null, array = function() end, setmetatable({}, { __is_luajson_array = true })
local objects = { values = array, empty = {}, null_value = null, nested = { enabled = false } }
decoded['{"types":true}'] = objects
send({ text_endpoint = unknown, dictionary_parameters_json = '{"types":true}' })
assert(body.values == array and body.empty == objects.empty and body.null_value == null and body.nested.enabled == false)
decoded['{"model":"override"}'] = { model = "override", stream = false, messages = {} }
send({ text_endpoint = router, dictionary_model = "feature-model", dictionary_parameters_json = '{"model":"override"}' })
assert(body.model == "feature-model" and body.messages == messages and body.stream == true)
for _, invalid in ipairs({ "[]", "null", "false", "123", "{broken", '{"x":1} trailing', true, {} }) do
  configuration, request = { api_key = "test-key", text_endpoint = router, dictionary_parameters_json = invalid }, nil
  local err
  assert(type(query(messages, { on_error = function(e) err = e end })) == "function")
  assert(err and not request)
end
encode_error, request = true, nil
configuration = { api_key = "test-key", text_endpoint = router }
local err
query(messages, { on_error = function(e) err = e end }); assert(err and not request)
encode_error = false

-- A broken dictionary JSON field cannot block Explain or Word Sense.
send({ text_endpoint = router, dictionary_parameters_json = "{broken" }, "explain")
send({ text_endpoint = router, dictionary_parameters_json = "{broken" }, "word_sense")
send({ text_endpoint = unknown, dictionary_parameters_json = " \n " })
assert(body.reasoning == nil and body.provider == nil)

local answer, deltas
configuration = { api_key = "test-key", text_endpoint = router, word_sense_model = "sense-model" }
query(messages, { feature = "word_sense",
  on_delta = function(delta) deltas = (deltas or "") .. delta end,
  on_done = function(content) answer = content end, on_error = function(e) error(e) end,
})
assert(body.model == "sense-model" and body.reasoning == nil)
callbacks.on_complete(200, "data: thinking\n\ndata: answer\n\ndata: [DONE]\n\n")
assert(answer == '{"entries":[]}' and deltas == answer)
print("ai_query_spec: feature isolation, provider formats, custom JSON, safe errors and reasoning streams passed")
