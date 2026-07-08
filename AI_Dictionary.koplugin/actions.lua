local Device = require("device")
local _ = require("gettext")

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
  plugin.ui.highlight:addToHighlightDialog("aidictionary_1", function(reader_highlight_instance)
    return {
      text = _("AI Explain"),
      enabled = Device:hasClipboard(),
      callback = function()
        plugin:Query(reader_highlight_instance, "AI Explain", false,
          "I'm reading '{title}' by '{author}'{chapter}. This is my highlighted text: \n'{selection}'\n" ..
          "This is the context where it appears: '...{context}...'\n" ..
          "Use web search economically to identify or verify the book, character, place, term, reference, or allusion if that helps. " ..
          "Explain it and dive deep in relation to the book, and help me understand it better (like Amazon Kindle's X-Ray, but more concise). " ..
          "No spoilers if it's fiction. Use Markdown emphasis (*x*) when it helps understanding. Keep your explanation brief (under 150 words, ONLY ONE PARAGRAPH), and ask no questions at the end.",
          AI_EXPLAIN_WEB_SEARCH_PARAMETERS)
      end,
    }
  end)

  plugin.ui.highlight:addToHighlightDialog("aidictionary_2", function(reader_highlight_instance)
    return {
      text = _("AI English Simplify"),
      enabled = Device:hasClipboard(),
      callback = function()
        plugin:Query(reader_highlight_instance, "AI English Simplify", false,
          "I'm an advanced learner of English. I'm reading '{title}' by '{author}'{chapter}. This is my highlighted text: \n'{selection}'\n" ..
          "This is the context where it appears: '...{context}...'\n" ..
          "Rewrite it in simpler, more understandable English. Brevity is important.")
      end,
    }
  end)

  plugin.ui.highlight:addToHighlightDialog("aidictionary_3", function(reader_highlight_instance)
    return {
      text = _("AI Dictionary"),
      enabled = Device:hasClipboard(),
      callback = function()
        plugin:Query(reader_highlight_instance, "AI Dictionary", true,
          "I'm an advanced learner of English. I'm reading '{title}' by '{author}'{chapter}. My selected text: \n'{selection}'\n" ..
          "This is the context where it appears: '...{context}...'\n" ..
          "ONLY for the selected text, give me an informative, context-aware, dictionary-style answer strictly in this format ONCE and add nothing more:\n" ..
          "(v./n./idiom/etc.) " ..
          "/[ACCURATE and CORRECT American (US) English pronunciation in the form of IPA]/ " ..
          "([English alphabet pronunciation help American US English])\n" ..
          "[Up to 3 feel and register tags separated by '•', e.g. slang, conversational, blunt, historical, formal, neutral, offensive (all lower-case)]\n" ..
          "Definition: [Plain and understandable definition in under 20 words]\n" ..
          "Example: [A natural sentence that uses the word(s) in the same meaning and register, but in a different situation]\n" ..
          "Synonyms: [Up to 3 synonyms, if any exists. If there are no synonyms skip this section]\n" ..
          "Paraphrase: [A short example sentence paraphrasing the selection using simpler words, with the same meaning and register]\n" ..
          "Etymology: [Concise and helpful etymology with a focus on the different parts that make up the word or interesting history in case of idioms, in under 20 words]" ..
          "(Pay close attention to the number of line breaks in the formatting of the response)")
      end,
    }
  end)
end

return Actions
