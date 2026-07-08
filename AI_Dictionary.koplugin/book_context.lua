local AnswerFormatter = require("answer_formatter")
local clean_up_string = require("string_cleanup")
local get_selection_in_context = require("selection_context")

local BookContext = {}

local MAX_HL = 2000
local MAX_TITLE = 100

function BookContext.get_current_chapter_name(plugin)
  local ui = plugin.ui
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

function BookContext.build_query_context(plugin, reader_highlight_instance, dialog_title)
  local ui = plugin.ui
  local title, author =
    ui.document:getProps().title or "Unknown Title",
    ui.document:getProps().authors
  if type(author) == "table" then
    author = table.concat(author, ", ")
  end
  author = (author and author ~= "" and author) or "Unknown Author"

  local highlighted_text = tostring(reader_highlight_instance.selected_text.text) or "Nothing highlighted"

  local chapter_clause = ""
  local chapter_name = BookContext.get_current_chapter_name(plugin)
  if chapter_name then
    chapter_clause = ", chapter/part '" .. chapter_name .. "'"
  end

  local safe_highlighted_text = clean_up_string(highlighted_text, MAX_HL)
  local selection_in_context = get_selection_in_context(reader_highlight_instance, highlighted_text, 15)
  local safe_selection_in_context = clean_up_string(selection_in_context, MAX_HL)

  local display_selection = safe_highlighted_text
  if dialog_title == "AI Dictionary" then
    safe_highlighted_text = AnswerFormatter.trim_to_dictionary_limit(safe_highlighted_text, 64)
    display_selection = safe_highlighted_text
  end

  return {
    replacements = {
      ["{title}"] = clean_up_string(title, MAX_TITLE),
      ["{author}"] = clean_up_string(author, MAX_TITLE),
      ["{chapter}"] = clean_up_string(chapter_clause, MAX_TITLE),
      ["{selection}"] = safe_highlighted_text,
      ["{context}"] = safe_selection_in_context,
    },
    display_selection = display_selection,
    selected_text = safe_highlighted_text,
    selection_context = safe_selection_in_context,
  }
end

return BookContext
