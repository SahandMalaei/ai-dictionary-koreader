local Providers = {}

local TEXT_PROVIDERS = {
  {
    id = "gemini",
    label = "Google Gemini",
    endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    endpoint_type = "openai_compatible",
    default_model = "gemini-3.6-flash",
    match = {
      "generativelanguage.googleapis.com",
      "ai.google.dev",
    },
    models = {
      { id = "gemini-3.6-flash", cost = "free" },
      { id = "gemini-3.5-flash", cost = "free" },
      { id = "gemini-3.5-flash-lite", cost = "free" },
      { id = "gemini-3.1-flash-lite", cost = "free" },
      { id = "gemini-2.5-flash", cost = "free" },
      { id = "gemini-2.5-flash-lite", cost = "free" },
      { id = "gemini-2.5-pro", cost = "paid" },
    },
  },
  {
    id = "openai",
    label = "OpenAI",
    endpoint = "https://api.openai.com/v1/chat/completions",
    endpoint_type = "openai",
    default_model = "gpt-5.4-nano",
    match = {
      "api.openai.com",
    },
    models = {
      { id = "gpt-5.6-terra", cost = "paid" },
      { id = "gpt-5.6-luna", cost = "paid" },
      { id = "gpt-5.5", cost = "paid" },
      { id = "gpt-5.4-mini", cost = "paid" },
      { id = "gpt-5.4-nano", cost = "paid" },
      { id = "gpt-5-nano", cost = "paid" },
      { id = "gpt-4o-mini", cost = "paid" },
    },
  },
  {
    id = "openrouter",
    label = "OpenRouter",
    endpoint = "https://openrouter.ai/api/v1/chat/completions",
    endpoint_type = "openrouter",
    default_model = "google/gemini-3.6-flash",
    match = {
      "openrouter.ai",
    },
    models = {
      { id = "google/gemini-3.6-flash", cost = "paid" },
      { id = "google/gemini-2.5-flash", cost = "paid" },
      { id = "openai/gpt-5.4-mini", cost = "paid" },
      { id = "openai/gpt-5.4-nano", cost = "paid" },
      { id = "anthropic/claude-sonnet-4.6", cost = "paid" },
      { id = "deepseek/deepseek-v4-flash", cost = "paid" },
    },
  },
  {
    id = "deepseek",
    label = "DeepSeek",
    endpoint = "https://api.deepseek.com/chat/completions",
    endpoint_type = "openai_compatible",
    default_model = "deepseek-v4-flash",
    match = {
      "api.deepseek.com",
    },
    models = {
      { id = "deepseek-v4-flash", cost = "paid" },
      { id = "deepseek-v4-pro", cost = "paid" },
      { id = "deepseek-chat", cost = "paid" },
    },
  },
  {
    id = "custom",
    label = "Custom / Other",
    endpoint = nil,
    endpoint_type = "openai_compatible",
    default_model = nil,
    match = {},
    models = {},
  },
}

local VOICE_PROVIDERS = {
  {
    id = "openai",
    endpoint = "https://api.openai.com/v1/audio/speech",
    default_model = "gpt-4o-mini-tts",
    match = {
      "api.openai.com",
    },
    models = {
      { id = "gpt-4o-mini-tts" },
      { id = "tts-1" },
      { id = "tts-1-hd" },
    },
  },
  {
    id = "openrouter",
    endpoint = "https://openrouter.ai/api/v1/audio/speech",
    default_model = "openai/gpt-4o-mini-tts",
    match = {
      "openrouter.ai",
    },
    models = {
      { id = "openai/gpt-4o-mini-tts" },
      { id = "x-ai/grok-voice-tts-1.0" },
    },
  },
}

local function url_contains(url, needle)
  return type(url) == "string" and url:lower():find(needle, 1, true) ~= nil
end

local function find_in_catalog(catalog, url)
  if type(url) ~= "string" or url == "" then
    return nil
  end
  for _, provider in ipairs(catalog) do
    for _, needle in ipairs(provider.match or {}) do
      if url_contains(url, needle) then
        return provider
      end
    end
  end
  return nil
end

local function provider_by_id(catalog, id)
  for _, provider in ipairs(catalog) do
    if provider.id == id then
      return provider
    end
  end
  return nil
end

local function model_known(provider, model_id)
  if not provider or not model_id then
    return false
  end
  for _, model in ipairs(provider.models or {}) do
    if model.id == model_id then
      return true
    end
  end
  return false
end

function Providers.list_text()
  return TEXT_PROVIDERS
end

function Providers.detect_text(url)
  return find_in_catalog(TEXT_PROVIDERS, url) or provider_by_id(TEXT_PROVIDERS, "custom")
end

function Providers.get_text(id)
  return provider_by_id(TEXT_PROVIDERS, id) or provider_by_id(TEXT_PROVIDERS, "custom")
end

function Providers.detect_voice(url)
  return find_in_catalog(VOICE_PROVIDERS, url)
end

function Providers.apply_text_provider(configuration, provider_id)
  local provider = Providers.get_text(provider_id)
  if not provider then
    return configuration
  end

  if provider.endpoint then
    configuration.text_endpoint = provider.endpoint
  end
  if provider.endpoint_type then
    configuration.text_endpoint_type = provider.endpoint_type
  end
  if provider.default_model and not model_known(provider, configuration.text_model) then
    configuration.text_model = provider.default_model
  end
  return configuration
end

function Providers.apply_text_model(configuration, model_id)
  if type(model_id) == "string" and model_id:match("%S") then
    configuration.text_model = model_id
  end
  return configuration
end

function Providers.apply_voice_model(configuration, model_id)
  if type(model_id) == "string" and model_id:match("%S") then
    configuration.voice_model = model_id
  end
  return configuration
end

return Providers
