local Device = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")

local showLoadingDialog = require("dialogs")

local UIManager = require("ui/uimanager")
local ChatGPTViewer = require("chatgptviewer")
local handleNewQuestion = require("dialogs")

local queryChatGPT = require("gpt_query")
local queryStream = require("gpt_query_stream")

local clean_up_string = require("string_cleanup")

local get_selection_in_context = require("selection_context")

local TextViewer = require("ui/widget/textviewer")

local save_lookup_entry = require("lookups_log")

local MAX_HL = 2000
local MAX_TITLE = 100

local AskGPT = InputContainer:new {
  name = "askgpt",
  is_doc_only = true,
}

local function capitalize_first(s)
    return (s:gsub("^%l", string.upper))
end

function AskGPT:Query(_reader_highlight_instance, dialog_title, preface_with_selection, query)
  local ui = self.ui
  local title, author =
    ui.document:getProps().title or "Unknown Title",
    ui.document:getProps().authors
  if type(authors) == "table" then
    authors = table.concat(authors, ", ")
  end
  authors = (authors and authors ~= "" and authors) or "Unknown Author"

  local highlightedText = tostring(_reader_highlight_instance.selected_text.text) or "Nothing highlighted"
  --showLoadingDialog()

  local safeTitle = clean_up_string(title, MAX_TITLE)
  local safeAuthor = clean_up_string(author, MAX_TITLE)
  local safeHighlightedText = clean_up_string(highlightedText, MAX_HL)

  local selectionInContext = get_selection_in_context(self.ui.document, highlightedText)
  local safeSelectionInContext = clean_up_string(selectionInContext, MAX_HL)

  local titleCaseSelection = capitalize_first(safeHighlightedText)

  local waitMessage = "Getting the answer..."

  local online = NetworkMgr:isOnline()

  if not online then
    waitMessage = "You are offline. AI lookup requires an active internet connection."
  end

  local chatgpt_viewer = ChatGPTViewer:new {
    title = dialog_title,
    text = string.format(waitMessage),
    onAskQuestion = nil
  }

  ui.highlight:onClose()
  UIManager:show(chatgpt_viewer)

  local file_path = self.ui.document.file

  if not string.find(file_path, "- AI Lookups") then
    save_lookup_entry(file_path, safeTitle, dialog_title, safeSelectionInContext)
  end

  if not online then
    return
  end

  UIManager:scheduleIn(0.01, function()
    local message_history = {
    {
      role = "user",
      content = string.format(query, safeTitle, safeAuthor, safeHighlightedText, safeSelectionInContext)
    }}

    local answer = queryChatGPT(message_history)
    if preface_with_selection then
      chatgpt_viewer:update(string.format("%s %s", titleCaseSelection, answer))
    else
      chatgpt_viewer:update(string.format("%s %s", "", answer))
    end
  end)
end

function AskGPT:init()
  self.ui.highlight:addToHighlightDialog("aidictionary_1", function(_reader_highlight_instance)
    return {
      text = _("AI Explain"),
      enabled = Device:hasClipboard(),
      callback = function()
          self:Query(_reader_highlight_instance, "AI Explain", false,
            "I'm an advanced learner of English. I'm reading '%s' by '%s'. This is my highlighted text: \n'%s'\n" ..
            "This is the context where it appears: '...%s...'\n" ..
            "Explain it in the context/lore of the book, and help me understand it better. Keep your explanation concise and brief (under 50 words), and ask no questions at the end.")
      end,
    }
  end)

  self.ui.highlight:addToHighlightDialog("aidictionary_2", function(_reader_highlight_instance)
    return {
      text = _("AI English Explain"),
      enabled = Device:hasClipboard(),
      callback = function()
          self:Query(_reader_highlight_instance, "AI English Explain", false,
            "I'm an advanced learner of English. I'm reading '%s' by '%s'. This is my highlighted text: \n'%s'\n" ..
            "This is the context where it appears: '...%s...'\n" ..
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
            "I'm an advanced learner of English. I'm reading '%s' by '%s'. My selected text: \n'%s'\n"..
            "This is the context where it appears: '...%s...'\n" ..
            "ONLY for the selected text, give me an informative dictionary-style answer in this format ONCE and add nothing more:\n" ..
            "/[ACCURATE and CORRECT American (US) English pronunciation in the form of IPA]/\n\n" ..
            "Definition: [Definition in under 20 words]\n\n" ..
            "Synonyms: [Up to 3 synonyms, if any exists. If there are no synonyms skip this section]\n\n" ..
            "Etymology: [Helpful etymology in under 20 words]")
      end,
    }
  end)
end

return AskGPT