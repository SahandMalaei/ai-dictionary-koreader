local Device = require("device")
local _ = require("gettext")

local ErrorBoundary = require("error_boundary")
local DictionaryPrompt = require("dictionary_prompt")

local Actions = {}

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

function Actions.register(plugin)
  plugin.ui.highlight:addToHighlightDialog("aidictionary_1", ErrorBoundary.wrap("build AI Explain action", function(reader_highlight_instance)
    return {
      text = _("AI Explain"),
      enabled = Device:hasClipboard(),
      callback = function()
        plugin:Query(reader_highlight_instance, "AI Explain", false,
          "I'm reading '{title}' by '{author}'{chapter}. This is my highlighted text: \n'{selection}'\n" ..
          "This is the text context where it appears (use it only as a hint, and don't let it limit your scope): '...{context}...'\n" ..
          "Use web search economically to identify or verify the book, character, place, term, reference, or allusion if that helps. " ..
          "Explain it and dive deep in relation to the book, and help me understand it better (like Amazon Kindle's X-Ray, but more concise). " ..
          "No spoilers if it's fiction. Use Markdown emphasis (*x*) when it helps understanding. Keep your explanation brief (under 90 words, ONLY ONE PARAGRAPH), and ask no questions at the end.",
          AI_EXPLAIN_WEB_SEARCH_PARAMETERS)
      end,
    }
  end))

  plugin.ui.highlight:addToHighlightDialog("aidictionary_2", ErrorBoundary.wrap("build AI Simplify action", function(reader_highlight_instance)
    return {
      text = _("AI Simplify"),
      enabled = Device:hasClipboard(),
      callback = function()
        plugin:Query(reader_highlight_instance, "AI Simplify", false,
          "I'm an advanced language learner. I'm reading '{title}' by '{author}'{chapter}. This is my highlighted text: \n'{selection}'\n" ..
          "This is the context where it appears: '...{context}...'\n" ..
          "Rewrite and simplify it to make it more understandable. Brevity is also important. Give just one output and not several options. Ask no questions at the end.")
      end,
    }
  end))

  plugin.ui.highlight:addToHighlightDialog("aidictionary_3", ErrorBoundary.wrap("build AI Dictionary action", function(reader_highlight_instance)
    return {
      text = _("AI Dictionary"),
      enabled = Device:hasClipboard(),
      callback = function()
        plugin:Query(reader_highlight_instance, "AI Dictionary", true,
          DictionaryPrompt.for_book_selection())
      end,
    }
  end))
end

return Actions
