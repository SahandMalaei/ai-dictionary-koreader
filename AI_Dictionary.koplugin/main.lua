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

local PTF_HEADER = "\u{FFF1}"
local PTF_BOLD_START = "\u{FFF2}"
local PTF_BOLD_END = "\u{FFF3}"

local AskGPT = InputContainer:new {
  name = "askgpt",
  is_doc_only = true,
}

local function ptf_bold(s)
    return PTF_BOLD_START .. s .. PTF_BOLD_END
end

local function format_dictionary_output(selection, answer)
    local output = answer or ""
    if selection and selection ~= "" then
        output = ptf_bold(selection) .. " " .. output
    end
    for _, label in ipairs({ "Definition", "Example", "Synonyms", "Etymology" }) do
        output = output:gsub("(^%s*)" .. label .. "%s*:", function(prefix)
            return prefix .. ptf_bold(label .. ":")
        end)
        output = output:gsub("([\r\n]%s*)" .. label .. "%s*:", function(prefix)
            return prefix .. ptf_bold(label .. ":")
        end)
    end
    return PTF_HEADER .. output
end

local function capitalize_first(s)
    return (s:gsub("^%l", string.upper))
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
local waitMessage = ""
local lastIsDictionary = false

function AskGPT:Query(_reader_highlight_instance, dialog_title, preface_with_selection, query)
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
    waitMessage = "You are offline. AI lookup requires an active internet connection."
  else
    waitMessage = "Getting the answer..."
  end

  local chatgpt_viewer = ChatGPTViewer:new {
    title = dialog_title,
    text = string.format(waitMessage),
    onAskQuestion = nil,
    benedict = self
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
  lastIsDictionary = dialog_title == "AI Dictionary"

  UIManager:scheduleIn(0.01, function()
    local message_history = {
    {
      role = "user",
      content = lastQuery
    }}

    local answer = queryChatGPT(message_history)
    if lastIsDictionary then
      chatgpt_viewer:update(format_dictionary_output(titleCaseSelection, answer))
    elseif preface_with_selection then
      chatgpt_viewer:update(string.format("%s %s", titleCaseSelection, answer))
    else
      chatgpt_viewer:update(string.format("%s %s", "", answer))
    end
  end)
end

function AskGPT:Regenerate(chatgpt_viewer)
  local updatedViewer = chatgpt_viewer:update(waitMessage)

  UIManager:scheduleIn(0.01, function()
    local message_history = {
    {
      role = "user",
      content = lastQuery
    }}

    local answer = queryChatGPT(message_history)
    if lastIsDictionary then
      updatedViewer:update(format_dictionary_output(lastTitleCaseSelection, answer))
    elseif lastPrefaceWithSelection then
      updatedViewer:update(string.format("%s %s", lastTitleCaseSelection, answer))
    else
      updatedViewer:update(string.format("%s %s", "", answer))
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
            "I'm reading '{title}' by '{author}'{chapter}. This is my highlighted text: \n'{selection}'\n" ..
            "This is the context where it appears: '...{context}...'\n" ..
            "Explain it in the context/lore of the book, and help me understand it better (like Amazon Kindle's X-Ray, but much more concise)." ..
            "No spoilers if it's fiction. Plain text. Keep your explanation concise and brief (under 80 words), and ask no questions at the end.")
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
            "([English alphabet pronunciation help American US English])\n\n" ..
            "Definition: [Definition in under 20 words]\n\n" ..
            "Example: [A natural sentence that uses the word(s) in the same meaning and register, but in a different situation]\n\n" ..
            "Synonyms: [Up to 3 synonyms, if any exists. If there are no synonyms skip this section]\n\n" ..
            "Etymology: [Helpful etymology with a focus on the different parts that make up the word, in under 30 words]")
      end,
    }
  end)
end

return AskGPT
