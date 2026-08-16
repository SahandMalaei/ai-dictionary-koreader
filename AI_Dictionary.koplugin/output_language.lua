local OutputLanguage = {}

local SETTING_KEY = "ai_dictionary_output_language"
local memory_mode

OutputLanguage.LANGUAGES = {
  { id = "en", prompt_name = "English", native_name = "English" },
  { id = "es", prompt_name = "Spanish", native_name = "Español" },
  { id = "fr", prompt_name = "French", native_name = "Français" },
  { id = "de", prompt_name = "German", native_name = "Deutsch" },
  { id = "it", prompt_name = "Italian", native_name = "Italiano" },
  { id = "pt", prompt_name = "Portuguese", native_name = "Português" },
  { id = "ca", prompt_name = "Catalan", native_name = "Català" },
  { id = "nl", prompt_name = "Dutch", native_name = "Nederlands" },
  { id = "pl", prompt_name = "Polish", native_name = "Polski" },
  { id = "ru", prompt_name = "Russian", native_name = "Русский" },
  { id = "uk", prompt_name = "Ukrainian", native_name = "Українська" },
  { id = "zh", prompt_name = "Chinese", native_name = "中文" },
  { id = "ja", prompt_name = "Japanese", native_name = "日本語" },
  { id = "ko", prompt_name = "Korean", native_name = "한국어" },
  { id = "ar", prompt_name = "Arabic", native_name = "العربية" },
  { id = "tr", prompt_name = "Turkish", native_name = "Türkçe" },
  { id = "hu", prompt_name = "Hungarian", native_name = "Magyar" },
  { id = "id", prompt_name = "Indonesian", native_name = "Bahasa Indonesia" },
}

local LEGACY_MODE = {
  auto = "auto",
  book = "book",
  system = "auto",
  english = "en",
  en = "en",
  ["en-us"] = "en",
  ["en-gb"] = "en",
  spanish = "es",
  espanol = "es",
  ["español"] = "es",
  es = "es",
  french = "fr",
  francais = "fr",
  ["français"] = "fr",
  fr = "fr",
  german = "de",
  deutsch = "de",
  de = "de",
  italian = "it",
  italiano = "it",
  it = "it",
  portuguese = "pt",
  portugues = "pt",
  ["português"] = "pt",
  pt = "pt",
  ["pt-br"] = "pt",
  catalan = "ca",
  catala = "ca",
  ["català"] = "ca",
  ca = "ca",
  dutch = "nl",
  nederlands = "nl",
  nl = "nl",
  polish = "pl",
  polski = "pl",
  pl = "pl",
  russian = "ru",
  ru = "ru",
  ukrainian = "uk",
  uk = "uk",
  chinese = "zh",
  zh = "zh",
  ["zh-cn"] = "zh",
  ["zh_cn"] = "zh",
  japanese = "ja",
  ja = "ja",
  jp = "ja",
  korean = "ko",
  ko = "ko",
  arabic = "ar",
  ar = "ar",
  turkish = "tr",
  tr = "tr",
  hungarian = "hu",
  magyar = "hu",
  hu = "hu",
  indonesian = "id",
  id = "id",
}

local ISO3 = {
  eng = "en",
  spa = "es",
  fra = "fr",
  fre = "fr",
  deu = "de",
  ger = "de",
  ita = "it",
  por = "pt",
  cat = "ca",
  nld = "nl",
  dut = "nl",
  pol = "pl",
  rus = "ru",
  ukr = "uk",
  zho = "zh",
  chi = "zh",
  jpn = "ja",
  kor = "ko",
  ara = "ar",
  tur = "tr",
  hun = "hu",
  ind = "id",
}

local function language_by_id(id)
  if not id then
    return nil
  end
  for _, language in ipairs(OutputLanguage.LANGUAGES) do
    if language.id == id then
      return language
    end
  end
  return nil
end

function OutputLanguage.normalize_code(value)
  if type(value) ~= "string" then
    return nil
  end
  local code = value:match("^%s*([%a_-]+)")
  if not code then
    return nil
  end
  code = code:gsub("-", "_"):lower()
  if code == "c" then
    return "en"
  end
  if code:match("^zh") then
    return "zh"
  end
  if code:match("^pt") then
    return "pt"
  end
  if code == "jp" then
    return "ja"
  end
  if ISO3[code] then
    return ISO3[code]
  end
  local short = code:match("^(%a%a)")
  if language_by_id(short) then
    return short
  end
  return nil
end

function OutputLanguage.from_legacy(value)
  if type(value) ~= "string" then
    return nil
  end
  local trimmed = value:match("^%s*(.-)%s*$") or ""
  if trimmed == "" then
    return nil
  end
  local lowered = trimmed:lower()
  if LEGACY_MODE[lowered] then
    return LEGACY_MODE[lowered]
  end
  return OutputLanguage.normalize_code(trimmed)
end

local function read_saved_mode()
  if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
    local ok, value = pcall(G_reader_settings.readSetting, G_reader_settings, SETTING_KEY)
    if ok and type(value) == "string" and value:match("%S") then
      return value
    end
  end
  return memory_mode
end

function OutputLanguage.get_mode()
  local mode = read_saved_mode()
  if mode == "auto" or mode == "book" or language_by_id(mode) then
    return mode
  end
  local mapped = OutputLanguage.from_legacy(mode)
  if mapped then
    return mapped
  end
  return "auto"
end

function OutputLanguage.set_mode(mode)
  if mode ~= "auto" and mode ~= "book" and not language_by_id(mode) then
    mode = OutputLanguage.from_legacy(mode) or "auto"
  end
  memory_mode = mode
  if G_reader_settings and type(G_reader_settings.saveSetting) == "function" then
    pcall(G_reader_settings.saveSetting, G_reader_settings, SETTING_KEY, mode)
    if type(G_reader_settings.flush) == "function" then
      pcall(G_reader_settings.flush, G_reader_settings)
    end
  end
  return mode
end

local function system_language_code()
  local gettext_ok, gettext = pcall(require, "gettext")
  local ko_lang
  if gettext_ok and gettext then
    if type(gettext.getLanguage) == "function" then
      ko_lang = gettext.getLanguage()
    end
    if not ko_lang then
      ko_lang = gettext.current_lang
    end
  end
  if not ko_lang and G_reader_settings and type(G_reader_settings.readSetting) == "function" then
    local ok, value = pcall(G_reader_settings.readSetting, G_reader_settings, "language")
    if ok then
      ko_lang = value
    end
  end
  return OutputLanguage.normalize_code(ko_lang) or "en"
end

local function book_language_code(plugin)
  local ui = plugin and plugin.ui
  if not (ui and ui.document and type(ui.document.getProps) == "function") then
    return nil
  end
  local ok, props = pcall(function()
    return ui.document:getProps()
  end)
  if not ok or type(props) ~= "table" then
    return nil
  end
  return OutputLanguage.normalize_code(props.language)
end

function OutputLanguage.resolve_code(plugin)
  local mode = OutputLanguage.get_mode()
  if mode == "auto" then
    return system_language_code()
  end
  if mode == "book" then
    return book_language_code(plugin) or system_language_code()
  end
  if language_by_id(mode) then
    return mode
  end
  return "en"
end

function OutputLanguage.resolve_prompt_name(plugin)
  local language = language_by_id(OutputLanguage.resolve_code(plugin))
  return language and language.prompt_name or "English"
end

function OutputLanguage.is_english(plugin)
  return OutputLanguage.resolve_code(plugin) == "en"
end

function OutputLanguage.display_label(plugin)
  local _ = require("plugin_i18n")
  local mode = OutputLanguage.get_mode()
  if mode == "auto" then
    return _("Automatic (follow system)")
  end
  if mode == "book" then
    return _("Automatic (follow book)")
  end
  local language = language_by_id(mode)
  return language and language.native_name or mode
end

function OutputLanguage.prompt_suffix(plugin)
  if OutputLanguage.is_english(plugin) then
    return ""
  end
  local language = OutputLanguage.resolve_prompt_name(plugin)
  return "\n\nWrite the user-visible answer in " .. language .. ". " ..
      "Keep machine-readable metadata, the exact English Wikipedia article title, and formatting markers exactly as specified. " ..
      "Use the dictionary section labels exactly as specified in the format instructions. " ..
      "Translate only the user-visible content."
end

function OutputLanguage.migrate(plugin)
  local Config = require("configuration_manager")
  local configuration = Config.load()
  if not read_saved_mode() then
    local mapped = OutputLanguage.from_legacy(configuration.output_language)
    OutputLanguage.set_mode(mapped or "auto")
  end
  if configuration.output_language ~= nil then
    configuration.output_language = nil
    Config.save(plugin, configuration)
  end
end

return OutputLanguage
