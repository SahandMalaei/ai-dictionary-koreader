local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local showLoadingDialog = require("dialogs")

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local ChatGPTViewer = require("chatgptviewer")
local handleNewQuestion = require("dialogs")

local queryChatGPT = require("gpt_query")
local queryStream = require("gpt_query_stream")
local LookupsReport = require("lookups_report")
local Updater = require("updater")

local clean_up_string = require("string_cleanup")

local get_selection_in_context = require("selection_context")

local TextViewer = require("ui/widget/textviewer")

local save_lookup_entry = require("lookups_log")

local MAX_HL = 2000
local MAX_TITLE = 100
local STREAM_UPDATE_TOKEN_INTERVAL = 10

local PTF_HEADER = "\u{FFF1}"
local PTF_BOLD_START = "\u{FFF2}"
local PTF_BOLD_END = "\u{FFF3}"

local DICTIONARY_SECTION_LABELS = { "Definition", "Example", "Synonyms", "Paraphrase", "Etymology" }

local OFFLINE_WAIT_MESSAGE = "You are offline. AI lookup requires an active internet connection."
local ONLINE_WAIT_MESSAGE = "Getting the answer..."

local CORE_CONFIGURATION_KEYS = { "api_key", "provider", "model" }
local CORE_CONFIGURATION_KEY_SET = {
  api_key = true,
  provider = true,
  model = true,
}
local CONFIGURATION_LABELS = {
  api_key = "API key",
  provider = "Provider URL",
  model = "Model",
  additional_parameters = "Additional parameters",
}

local AI_EXPLAIN_WEB_SEARCH_PARAMETERS = {
  plugins = {
    {
      id = "web",
      max_results = 3,
      search_prompt = "Use the web results only if it helps explain the selected text in the book context. Keep the answer concise.",
    },
  },
  web_search_options = {
    search_context_size = "low",
  },
}

local AskGPT = InputContainer:new {
  name = "askgpt",
  is_doc_only = true,
}

local function ptf_bold(s)
    return PTF_BOLD_START .. s .. PTF_BOLD_END
end

local function format_inline_markdown_emphasis(text)
    if type(text) ~= "string" then
        return text
    end

    -- Convert Markdown-style bold/emphasis to KOReader PTF bold markers.
    -- The viewer is not a Markdown renderer, so without this, model output like
    -- *word* or **word** is shown with literal asterisks.
    text = text:gsub("%*%*([^*\r\n]+)%*%*", function(s)
        return ptf_bold(s)
    end)
    text = text:gsub("%*([^*%s][^*\r\n]-)%*", function(s)
        return ptf_bold(s)
    end)

    return text
end

local function format_dictionary_output(selection, answer)
    local output = format_inline_markdown_emphasis(answer or "")
    local header = nil
    if selection and selection ~= "" then
        header = PTF_HEADER .. ptf_bold(selection)
    end
    for _, label in ipairs(DICTIONARY_SECTION_LABELS) do
        output = output:gsub("(^%s*)" .. label .. "%s*:", function(prefix)
            return prefix .. ptf_bold(label .. ":")
        end)
        output = output:gsub("([\r\n]%s*)" .. label .. "%s*:", function(prefix)
            return prefix .. ptf_bold(label .. ":")
        end)
    end
    return header, PTF_HEADER .. output
end

local function capitalize_first(s)
    return (s:gsub("^%l", string.upper))
end

local function get_configuration_path(plugin)
  local base_path = plugin and plugin.path
  if base_path and base_path ~= "" then
    return base_path .. "/configuration.lua"
  end
  return "AI_Dictionary.koplugin/configuration.lua"
end

local function load_configuration()
  package.loaded["configuration"] = nil
  local ok, config = pcall(function() return require("configuration") end)
  if ok and type(config) == "table" then
    return config
  end
  return {
    api_key = "",
    provider = "https://api.openai.com/v1/chat/completions",
    model = "gpt-5-nano",
  }
end

local function is_array(value)
  if type(value) ~= "table" then
    return false
  end

  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local function is_lua_identifier(value)
  return type(value) == "string" and value:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function serialize_lua_value(value, indent)
  indent = indent or ""
  local value_type = type(value)

  if value_type == "string" then
    return string.format("%q", value)
  elseif value_type == "number" or value_type == "boolean" then
    return tostring(value)
  elseif value_type == "table" then
    local next_indent = indent .. "    "
    local lines = { "{" }

    if is_array(value) then
      for _, item in ipairs(value) do
        table.insert(lines, next_indent .. serialize_lua_value(item, next_indent) .. ",")
      end
    else
      local keys = {}
      for key, _ in pairs(value) do
        table.insert(keys, key)
      end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

      for _, key in ipairs(keys) do
        local key_text
        if is_lua_identifier(key) then
          key_text = key
        else
          key_text = "[" .. serialize_lua_value(key, next_indent) .. "]"
        end
        table.insert(lines, next_indent .. key_text .. " = " .. serialize_lua_value(value[key], next_indent) .. ",")
      end
    end

    table.insert(lines, indent .. "}")
    return table.concat(lines, "\n")
  elseif value == nil then
    return "nil"
  end

  return "nil"
end

local function serialize_configuration(configuration)
  local lines = { "local CONFIGURATION = {" }
  local written = {}

  local function write_key(key)
    if configuration[key] ~= nil then
      local key_text
      if is_lua_identifier(key) then
        key_text = key
      else
        key_text = "[" .. serialize_lua_value(key, "    ") .. "]"
      end
      table.insert(lines, "    " .. key_text .. " = " .. serialize_lua_value(configuration[key], "    ") .. ",")
      written[key] = true
    end
  end

  for _, key in ipairs(CORE_CONFIGURATION_KEYS) do
    write_key(key)
  end

  local keys = {}
  for key, _ in pairs(configuration) do
    if not written[key] then
      table.insert(keys, key)
    end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  for _, key in ipairs(keys) do
    write_key(key)
  end

  table.insert(lines, "}")
  table.insert(lines, "")
  table.insert(lines, "return CONFIGURATION")
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

local function parse_lua_literal(input)
  local loader = loadstring or load
  local chunk, compile_error = loader("return " .. tostring(input or ""))
  if not chunk then
    return nil, compile_error
  end

  local ok, value = pcall(chunk)
  if not ok then
    return nil, value
  end
  return value
end

local function display_configuration_value(key, value)
  if value == nil then
    return "not set"
  end
  if key == "api_key" and type(value) == "string" and value ~= "" then
    if #value <= 10 then
      return "set"
    end
    return value:sub(1, 6) .. "..." .. value:sub(-4)
  end
  if type(value) == "table" then
    return serialize_lua_value(value):gsub("\n", " ")
  end
  return tostring(value)
end

local function show_message(text)
  UIManager:show(InfoMessage:new {
    text = text,
    timeout = 3,
  })
end

local function repaint_now()
  if UIManager.forceRePaint then
    pcall(function() UIManager:forceRePaint() end)
  end
  if UIManager.yieldToEPDC then
    pcall(function() UIManager:yieldToEPDC() end)
  end
end

local function find_dictionary_section_boundary(text, after_index)
  local latest_start = nil

  for _, label in ipairs(DICTIONARY_SECTION_LABELS) do
    local search_from = math.max((after_index or 0) + 1, 1)
    while true do
      local start_index, end_index = text:find(label .. "%s*:", search_from)
      if not start_index then
        break
      end

      local line_start = text:sub(1, start_index - 1):match(".*[\r\n]()") or 1
      local before_label = text:sub(line_start, start_index - 1)
      if before_label:match("^%s*$") then
        if not latest_start or start_index > latest_start then
          latest_start = start_index
        end
      end

      search_from = end_index + 1
    end
  end

  return latest_start
end

local function render_answer(chatgpt_viewer, is_dictionary, title_case_selection, preface_with_selection, answer)
    if is_dictionary then
      local header_text, body_text = format_dictionary_output(title_case_selection, answer)
      return chatgpt_viewer:update(body_text, header_text)
    elseif preface_with_selection then
      return chatgpt_viewer:update(string.format("%s %s", title_case_selection, answer))
    else
      return chatgpt_viewer:update(string.format("%s %s", "", answer))
    end
end

local function stream_answer(chatgpt_viewer, message_history, is_dictionary, title_case_selection, preface_with_selection, on_success, request_parameters)
  local current_viewer = chatgpt_viewer
  local last_rendered_token_count = 0
  local last_rendered_dictionary_boundary = 0
  local last_rendered_answer = nil
  local cancel_stream

  local function is_stream_transport_error(err)
    return tostring(err):match("^wantread") ~= nil or tostring(err):match("^timeout") ~= nil
  end

  local function update_viewer(answer)
    last_rendered_answer = answer
    current_viewer = render_answer(
      current_viewer,
      is_dictionary,
      title_case_selection,
      preface_with_selection,
      answer
    )
    current_viewer.stream_cancel = cancel_stream
    repaint_now()
  end

  cancel_stream = queryStream(message_history, {
    request_parameters = request_parameters,
    on_delta = function(_, accumulated, token_count)
      if is_dictionary then
        local boundary = find_dictionary_section_boundary(accumulated, last_rendered_dictionary_boundary)
        if boundary then
          last_rendered_dictionary_boundary = boundary
          update_viewer(accumulated:sub(1, boundary - 1):gsub("%s+$", ""))
        end
      elseif token_count - last_rendered_token_count >= STREAM_UPDATE_TOKEN_INTERVAL then
        last_rendered_token_count = token_count
        update_viewer(accumulated)
      end
    end,
    on_done = function(accumulated)
      if accumulated ~= last_rendered_answer then
        update_viewer(accumulated)
      end
      if on_success then
        on_success(accumulated)
      end
    end,
    on_error = function(err)
      if is_stream_transport_error(err) then
        update_viewer("Streaming stalled; retrying without streaming...")
        local answer = queryChatGPT(message_history)
        update_viewer(answer)
        if on_success and answer and answer ~= "" and not tostring(answer):match("^Error querying AI:") then
          on_success(answer)
        end
      else
        update_viewer("Error querying AI: " .. tostring(err))
      end
    end,
  })

  current_viewer.stream_cancel = cancel_stream
end

function AskGPT:getCurrentChapterName()
    local ui = self.ui
    local doc = ui and ui.document
    if not (doc and doc.getToc) then return nil end

    local toc = doc:getToc() or {}
    if #toc == 0 then return nil end

    local chapter
    local has_pos = doc.getPos and doc.comparePositions
    if has_pos then
        local pos = doc:getPos()
        for i = 1, #toc do
            local e = toc[i]
            if e.pos and doc:comparePositions(e.pos, pos) <= 0 then
                chapter = e
            else
                break
            end
        end
    elseif doc.getCurrentPage then
        local page = doc:getCurrentPage()
        for i = 1, #toc do
            local e = toc[i]
            if e.page and e.page <= page then
                chapter = e
            else
                break
            end
        end
    end

    return chapter and chapter.title or nil
end

local lastQuery = ""
local lastPrefaceWithSelection = false
local lastTitleCaseSelection = ""
local lastRequestParameters = nil
local lastIsReport = false
local waitMessage = ""
local lastIsDictionary = false

function AskGPT:Query(_reader_highlight_instance, dialog_title, preface_with_selection, query, request_parameters)
  local ui = self.ui
  local title, author =
    ui.document:getProps().title or "Unknown Title",
    ui.document:getProps().authors
  if type(author) == "table" then
    author = table.concat(author, ", ")
  end
  author = (author and author ~= "" and author) or "Unknown Author"

  local highlightedText = tostring(_reader_highlight_instance.selected_text.text) or "Nothing highlighted"
  --showLoadingDialog()

  local chapterClause = ""
  local triedChapterName = self:getCurrentChapterName()
  if triedChapterName then
    chapterClause = ", chapter/part '" .. triedChapterName .. "'"
  end

  local safeTitle = clean_up_string(title, MAX_TITLE)
  local safeAuthor = clean_up_string(author, MAX_TITLE)
  local safeChapter = clean_up_string(chapterClause, MAX_TITLE)
  local safeHighlightedText = clean_up_string(highlightedText, MAX_HL)

  local selectionInContext = get_selection_in_context(self.ui.document, highlightedText, 10)
  local safeSelectionInContext = clean_up_string(selectionInContext, MAX_HL)

  local titleCaseSelection = capitalize_first(safeHighlightedText)
  lastTitleCaseSelection = titleCaseSelection

  local online = NetworkMgr:isOnline()

  if not online then
    waitMessage = OFFLINE_WAIT_MESSAGE
  else
    waitMessage = ONLINE_WAIT_MESSAGE
  end

  local chatgpt_viewer = ChatGPTViewer:new {
    title = dialog_title,
    text = string.format(waitMessage),
    onAskQuestion = nil,
    benedict = self
  }

  ui.highlight:onClose()
  UIManager:show(chatgpt_viewer)

  local replacements = {
    ["{title}"] = safeTitle,
    ["{author}"] = safeAuthor,
    ["{chapter}"] = safeChapter,
    ["{selection}"] = safeHighlightedText,
    ["{context}"] = safeSelectionInContext,
  }

  local resolvedQuery = query
  for key, value in pairs(replacements) do
    resolvedQuery = resolvedQuery:gsub(key, value)
  end

  lastQuery = resolvedQuery
  lastPrefaceWithSelection = preface_with_selection
  lastRequestParameters = request_parameters
  lastIsReport = false
  lastIsDictionary = dialog_title == "AI Dictionary"

  if not online then
    return
  end

  UIManager:scheduleIn(0.01, function()
    local message_history = {
    {
      role = "user",
      content = lastQuery
    }}

    stream_answer(chatgpt_viewer, message_history, lastIsDictionary, titleCaseSelection, preface_with_selection, function(answer)
      if lastIsDictionary and answer and answer ~= "" then
        save_lookup_entry(self.path, safeHighlightedText, safeSelectionInContext)
      end
    end, request_parameters)
  end)
end

function AskGPT:Regenerate(chatgpt_viewer)
  local online = NetworkMgr:isOnline()

  if not online then
    waitMessage = OFFLINE_WAIT_MESSAGE
  else
    waitMessage = ONLINE_WAIT_MESSAGE
  end

  local updatedViewer = chatgpt_viewer:update(waitMessage)

  if not online then
    return
  end

  UIManager:scheduleIn(0.01, function()
    local message_history = {
    {
      role = "user",
      content = lastQuery
    }}

    if lastIsReport then
      local report = queryChatGPT(message_history)
      updatedViewer:update(report, nil, { scroll_to_bottom = false })
    else
      stream_answer(updatedViewer, message_history, lastIsDictionary, lastTitleCaseSelection, lastPrefaceWithSelection, nil, lastRequestParameters)
    end
  end)
end

function AskGPT:showLookupsReportRequestDialog(selected_index)
  selected_index = selected_index or 1
  local timeframe = LookupsReport.TIMEFRAMES[selected_index] or LookupsReport.TIMEFRAMES[1]
  local report_dialog

  report_dialog = ButtonDialog:new {
    title = "AI Dictionary Lookups Report",
    buttons = {
      {
        {
          text = "Timeframe: " .. timeframe.label,
          callback = function()
            UIManager:close(report_dialog)
            self:showLookupsReportTimeframeDialog(selected_index)
          end,
        },
      },
      {
        {
          text = "Generate Report",
          callback = function()
            UIManager:close(report_dialog)
            self:generateLookupsReport(timeframe)
          end,
        },
      },
    },
  }

  UIManager:show(report_dialog)
end

function AskGPT:showLookupsReportTimeframeDialog(selected_index)
  local selector_dialog
  local buttons = {}

  for index, timeframe in ipairs(LookupsReport.TIMEFRAMES) do
    table.insert(buttons, {
      {
        text = (index == selected_index and "* " or "") .. timeframe.label,
        callback = function()
          UIManager:close(selector_dialog)
          self:showLookupsReportRequestDialog(index)
        end,
      },
    })
  end

  selector_dialog = ButtonDialog:new {
    title = "Timeframe",
    buttons = buttons,
  }

  UIManager:show(selector_dialog)
end

function AskGPT:generateLookupsReport(timeframe)
  local entries = LookupsReport.load_entries(self.path, timeframe)
  if #entries == 0 then
    show_message("No lookups found for " .. timeframe.label .. ".")
    return
  end

  local report_viewer = ChatGPTViewer:new {
    title = "AI Dictionary Lookups Report",
    text = "Generating report...",
    onAskQuestion = nil,
    benedict = self
  }

  UIManager:show(report_viewer)

  UIManager:scheduleIn(0.01, function()
    local report_prompt = LookupsReport.build_prompt(entries, timeframe)
    lastQuery = report_prompt
    lastPrefaceWithSelection = false
    lastTitleCaseSelection = ""
    lastRequestParameters = nil
    lastIsDictionary = false
    lastIsReport = true

    local message_history = {
      {
        role = "user",
        content = report_prompt,
      },
    }

    local report = queryChatGPT(message_history)
    report_viewer:update(report, nil, { scroll_to_bottom = false })
  end)
end

function AskGPT:saveConfiguration(configuration)
  local configuration_path = get_configuration_path(self)
  local file, err = io.open(configuration_path, "w")
  if not file then
    show_message("Could not save configuration.lua:\n" .. tostring(err))
    return false
  end

  file:write(serialize_configuration(configuration))
  file:close()
  package.loaded["configuration"] = nil
  show_message("AI Dictionary settings saved.")
  return true
end

function AskGPT:editConfigurationValue(key, parse_as_literal)
  local configuration = load_configuration()
  local current_value = configuration[key]
  local current_type = type(current_value)
  local label = CONFIGURATION_LABELS[key] or tostring(key)
  local input_value

  if parse_as_literal or current_type == "table" then
    input_value = serialize_lua_value(current_value)
  else
    input_value = current_value == nil and "" or tostring(current_value)
  end

  local input_dialog
  input_dialog = InputDialog:new {
    title = "Edit " .. label,
    input = input_value,
    input_type = current_type == "number" and "number" or "text",
    description = (parse_as_literal or current_type == "table") and "Enter a Lua literal: string, number, boolean, or table." or nil,
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(input_dialog)
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local raw_value = input_dialog:getInputText()
            local new_value = raw_value

            if current_type == "number" then
              new_value = tonumber(raw_value)
              if new_value == nil then
                show_message("Please enter a valid number.")
                return
              end
            elseif current_type == "boolean" then
              new_value = raw_value == "true" or raw_value == "1"
            elseif parse_as_literal or current_type == "table" then
              local parsed_value, parse_error = parse_lua_literal(raw_value)
              if parsed_value == nil then
                show_message("Please enter a valid non-nil Lua value.\n" .. tostring(parse_error or ""))
                return
              end
              new_value = parsed_value
            end

            configuration[key] = new_value
            if self:saveConfiguration(configuration) then
              UIManager:close(input_dialog)
            end
          end,
        },
      },
    },
  }

  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

function AskGPT:addConfigurationValue()
  local key_dialog
  key_dialog = InputDialog:new {
    title = "Add setting",
    input = "",
    input_type = "text",
    description = "Enter a Lua identifier, for example: additional_parameters",
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(key_dialog)
          end,
        },
        {
          text = _("Next"),
          is_enter_default = true,
          callback = function()
            local key = key_dialog:getInputText()
            if not is_lua_identifier(key) then
              show_message("Setting names must be Lua identifiers.")
              return
            end

            local configuration = load_configuration()
            if configuration[key] ~= nil then
              show_message("That setting already exists.")
              return
            end

            UIManager:close(key_dialog)
            self:editNewConfigurationLiteral(key)
          end,
        },
      },
    },
  }

  UIManager:show(key_dialog)
  key_dialog:onShowKeyboard()
end

function AskGPT:editNewConfigurationLiteral(key)
  local value_dialog
  value_dialog = InputDialog:new {
    title = "Set " .. key,
    input = "\"\"",
    input_type = "text",
    description = "Enter a Lua literal: string, number, boolean, or table.",
    buttons = {
      {
        {
          text = _("Cancel"),
          callback = function()
            UIManager:close(value_dialog)
          end,
        },
        {
          text = _("Save"),
          is_enter_default = true,
          callback = function()
            local value, parse_error = parse_lua_literal(value_dialog:getInputText())
            if value == nil then
              show_message("Please enter a valid non-nil Lua value.\n" .. tostring(parse_error or ""))
              return
            end

            local configuration = load_configuration()
            configuration[key] = value
            if self:saveConfiguration(configuration) then
              UIManager:close(value_dialog)
            end
          end,
        },
      },
    },
  }

  UIManager:show(value_dialog)
  value_dialog:onShowKeyboard()
end

function AskGPT:deleteConfigurationValue(key)
  local configuration = load_configuration()
  configuration[key] = nil
  self:saveConfiguration(configuration)
end

function AskGPT:getSettingsMenuItems()
  local configuration = load_configuration()
  local items = {}
  local written = {}

  local function add_value_item(key)
    local value = configuration[key]
    local label = CONFIGURATION_LABELS[key] or tostring(key)
    written[key] = true

    if type(value) == "boolean" then
      table.insert(items, {
        text = label,
        checked_func = function() return load_configuration()[key] == true end,
        callback = function()
          local updated_configuration = load_configuration()
          updated_configuration[key] = not updated_configuration[key]
          self:saveConfiguration(updated_configuration)
        end,
      })
    else
      table.insert(items, {
        text = label .. ": " .. display_configuration_value(key, value),
        callback = function()
          self:editConfigurationValue(key, not CORE_CONFIGURATION_KEY_SET[key])
        end,
      })
    end
  end

  for _, key in ipairs(CORE_CONFIGURATION_KEYS) do
    add_value_item(key)
  end

  local custom_keys = {}
  for key, _ in pairs(configuration) do
    if not written[key] then
      table.insert(custom_keys, key)
    end
  end
  table.sort(custom_keys, function(a, b) return tostring(a) < tostring(b) end)

  for _, key in ipairs(custom_keys) do
    add_value_item(key)
  end

  local delete_items = {}
  for _, key in ipairs(custom_keys) do
    if not CORE_CONFIGURATION_KEY_SET[key] then
      table.insert(delete_items, {
        text = tostring(key),
        callback = function()
          self:deleteConfigurationValue(key)
        end,
      })
    end
  end

  if #delete_items > 0 then
    table.insert(items, {
      text = "Delete custom setting",
      sub_item_table = delete_items,
    })
  end

  return items
end

function AskGPT:addToMainMenu(menu_items)
  menu_items.ai_dictionary_lookups_report = {
    text = "AI Dictionary Lookups Report",
    sorting_hint = "search",
    callback = function()
      self:showLookupsReportRequestDialog()
    end,
  }
  menu_items.ai_dictionary_settings = {
    text = "AI Dictionary settings",
    sorting_hint = "more_tools",
    sub_item_table_func = function()
      return self:getSettingsMenuItems()
    end,
  }
end

function AskGPT:init()
  if self.ui and self.ui.menu then
    self.ui.menu:registerToMainMenu(self)
  end
  self.updater = Updater:new(self)
  self.updater:checkOnStartup()

  self.ui.highlight:addToHighlightDialog("aidictionary_1", function(_reader_highlight_instance)
    return {
      text = _("AI Explain"),
      enabled = Device:hasClipboard(),
      callback = function()
          self:Query(_reader_highlight_instance, "AI Explain", false,
            "I'm reading '{title}' by '{author}'{chapter}. This is my highlighted text: \n'{selection}'\n" ..
            "This is the context where it appears: '...{context}...'\n" ..
            "Use web search economically to identify or verify the book, character, place, term, reference, or allusion if that helps. " ..
            "Explain it in the context/lore of the book, and help me understand it better (like Amazon Kindle's X-Ray, but much more concise). " ..
            "No spoilers if it's fiction. Plain text. Keep your explanation concise and brief (under 90 words), and ask no questions at the end.",
            AI_EXPLAIN_WEB_SEARCH_PARAMETERS)
      end,
    }
  end)

  self.ui.highlight:addToHighlightDialog("aidictionary_2", function(_reader_highlight_instance)
    return {
      text = _("AI English Simplify"),
      enabled = Device:hasClipboard(),
      callback = function()
          self:Query(_reader_highlight_instance, "AI English Explain", false,
            "I'm an advanced learner of English. I'm reading '{title}' by '{author}'{chapter}. This is my highlighted text: \n'{selection}'\n" ..
            "This is the context where it appears: '...{context}...'\n" ..
            "Explain its meaning in simple understandable English. Keep your explanation brief and under 30 words.")
      end,
    }
  end)

  self.ui.highlight:addToHighlightDialog("aidictionary_3", function(_reader_highlight_instance)
    return {
      text = _("AI Dictionary"),
      enabled = Device:hasClipboard(),
      callback = function()
          self:Query(_reader_highlight_instance, "AI Dictionary", true,
            "I'm an advanced learner of English. I'm reading '{title}' by '{author}'{chapter}. My selected text: \n'{selection}'\n"..
            "This is the context where it appears: '...{context}...'\n" ..
            "ONLY for the selected text, give me an informative, context-aware, dictionary-style answer strictly in this format ONCE and add nothing more:\n" ..
            "(v./n./idiom/etc.) " ..
            "/[ACCURATE and CORRECT American (US) English pronunciation in the form of IPA]/ " ..
            "([English alphabet pronunciation help American US English])\n" ..
            "[Up to 3 feel and register tags separated by '•', e.g. slang, conversational, blunt, historical, formal, neutral, offensive (all lower-case)]\n\n" ..
            "Definition: [Plain and understandable definition in under 20 words]\n\n" ..
            "Example: [A natural sentence that uses the word(s) in the same meaning and register, but in a different situation]\n\n" ..
            "Synonyms: [Up to 3 synonyms, if any exists. If there are no synonyms skip this section]\n\n" ..
            "Paraphrase: [A short example sentence paraphrasing the selection using simpler words, with the same meaning and register]\n\n" ..
            "Etymology: [Concise and helpful etymology with a focus on the different parts that make up the word or interesting history in case of idioms, in under 20 words]"..
            "(Pay close attention to the number of line breaks in the formatting of the response)")
      end,
    }
  end)
end

return AskGPT
