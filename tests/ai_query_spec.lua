-- Run from the repository root: luajit tests/ai_query_spec.lua
-- Exercise the real request builder without credentials, network or KOReader.
package.path = "./AI_Dictionary.koplugin/?.lua;" .. package.path

local configuration, body, request, callbacks
package.preload.configuration = function() return configuration end
package.preload.api_key = function() return {} end
package.loaded["ssl.https"] = {}
package.loaded["socket.http"] = {}
package.loaded.ltn12 = {}
package.loaded.json = {
  encode = function(value) body = value; return "encoded request" end,
  decode = function(value)
    if value == "thinking" then
      return { choices = { { delta = { reasoning = "internal reasoning" } } } }
    elseif value == "answer" then
      return { choices = { { delta = { content = '{"entries":[]}' } } } }
    end
    error("unexpected SSE payload")
  end,
}
package.loaded.device = { isAndroid = function() return true end }
package.loaded.constants = { network = { request_timeout_seconds = 60 } }
package.loaded.background_worker = {}
package.loaded.android_http_worker = { start = function(options, handlers)
  request = options
  callbacks = handlers
  return function() end
end }

local query = require("ai_query")
local function send(endpoint, effort, additional, endpoint_type, model, provider_sort)
  configuration = {
    api_key = "test-key", text_endpoint = endpoint, text_model = "test-model",
    additional_parameters = additional, text_endpoint_type = endpoint_type,
  }
  assert(type(query({ { role = "user", content = "test" } }, {
    reasoning_effort = effort, model = model, provider_sort = provider_sort,
  })) == "function")
  assert(request.url == endpoint and request.body == "encoded request" and body.stream == true)
  assert(body.messages[1].content == "test")
  return body
end

local router = "https://openrouter.ai/api/v1/chat/completions"
local direct = "https://api.openai.com/v1/chat/completions"
local compatible = "http://localhost:8080/v1/chat/completions"

assert(send(router).reasoning_effort == "none")
assert(body.model == "test-model")
assert(body.reasoning == nil)
assert(send(direct).reasoning_effort == "minimal")
assert(send(compatible).reasoning_effort == nil)

assert(send(router, "low").reasoning.effort == "low")
assert(body.reasoning_effort == nil, "do not send the default 'none' alongside explicit reasoning")
assert(send(direct, "low").reasoning_effort == "low")
assert(body.reasoning == nil)
assert(send(compatible, "low").reasoning_effort == "low")
assert(send(compatible, "low", nil, "openrouter").reasoning.effort == "low")

local additional = { reasoning_effort = "none", reasoning = { enabled = false, max_tokens = 0 } }
send(router, "low", additional)
assert(body.reasoning.effort == "low" and body.reasoning.enabled == nil and body.reasoning.max_tokens == nil)
assert(additional.reasoning.enabled == false and additional.reasoning.max_tokens == 0)
assert(additional.reasoning_effort == "none", "query overrides must not mutate shared settings")
send(router, nil, additional)
assert(body.reasoning_effort == "none" and body.reasoning.enabled == false)
assert(send(direct, nil, { reasoning_effort = "high" }).reasoning_effort == "high")

-- A foreground request immediately after Word Sense keeps its original defaults.
send(router, "low"); send(router)
assert(body.reasoning_effort == "none" and body.reasoning == nil)
send(direct, "low"); send(direct)
assert(body.reasoning_effort == "minimal" and body.reasoning == nil)

local word_sense_model = "deepseek/deepseek-v4.1-flash"
-- Word Sense sorts by price while preserving explicit provider restrictions.
send(router, "low", nil, nil, word_sense_model, "price")
assert(body.provider.sort == "price" and body.reasoning.effort == "low")
query({ { role = "user", content = "foreground lookup" } })
assert(body.provider.sort == "latency" and body.reasoning_effort == "none")
local routing = { provider = {
  sort = "throughput", only = { "example-provider" }, allow_fallbacks = false,
  data_collection = "deny", max_price = { completion = 1 },
} }
send(router, "low", routing, nil, word_sense_model, "price")
assert(body.provider.sort == "price" and body.provider.only[1] == "example-provider")
assert(body.provider.allow_fallbacks == false and body.provider.data_collection == "deny")
assert(body.provider.max_price.completion == 1 and routing.provider.sort == "throughput")
query({ { role = "user", content = "foreground lookup" } })
assert(body.provider.sort == "throughput", "Word Sense must not change foreground routing")
for _, endpoint in ipairs({ direct, compatible }) do
  send(endpoint, "low", nil, nil, word_sense_model, "price")
  assert(body.provider == nil, "OpenRouter routing must not leak to other endpoints")
end
send(compatible, "low", nil, "openrouter", word_sense_model, "price")
assert(body.provider.sort == "price")

for _, endpoint in ipairs({ router, direct, compatible }) do
  assert(send(endpoint, "low", nil, nil, word_sense_model).model == word_sense_model)
  assert(configuration.text_model == "test-model")
  query({ { role = "user", content = "foreground lookup" } })
  assert(body.model == "test-model", "Word Sense must not change the foreground model")
  for _, empty in ipairs({ "", "  ", false, {} }) do
    assert(send(endpoint, "low", nil, nil, empty).model == "test-model")
  end
end

local overrides = { model = "shared-model", reasoning = { enabled = false } }
send(router, "low", overrides, nil, "  " .. word_sense_model .. "  ")
assert(body.model == word_sense_model and body.reasoning.effort == "low")
assert(body.reasoning_effort == nil and overrides.model == "shared-model")
assert(overrides.reasoning.enabled == false)

-- Reasoning deltas must not contaminate the JSON consumed by Word Sense.
local answer, deltas
query({ { role = "user", content = "page" } }, {
  model = word_sense_model, reasoning_effort = "low",
  on_delta = function(delta) deltas = (deltas or "") .. delta end,
  on_done = function(content) answer = content end,
  on_error = function(err) error(err) end,
})
assert(body.model == word_sense_model and body.reasoning.effort == "low")
callbacks.on_complete(200, "data: thinking\n\ndata: answer\n\ndata: [DONE]\n\n")
assert(answer == '{"entries":[]}' and deltas == answer)
print("ai_query_spec: model/reasoning/routing overrides, foreground isolation and reasoning streams passed")
