local DictionaryPrompt = {}

local RESPONSE_INSTRUCTIONS =
    "ONLY for the selected text, give me an informative, context-aware, dictionary-style answer strictly in this format ONCE and add nothing more:\n" ..
    "(v./n./idiom/etc.) " ..
    "/[ACCURATE and CORRECT American (US) English pronunciation in the form of IPA]/ " ..
    "([English alphabet pronunciation help American US English])\n" ..
    "[Up to 3 feel and register tags separated by '•', e.g. slang, conversational, blunt, historical, formal, neutral, offensive (all lower-case)]\n" ..
    "Definition: [Plain and understandable definition in under 20 words]\n" ..
    "Example: \"[A natural sentence that uses the word(s) in the same meaning and register, but in a different situation]\"\n" ..
    "Synonyms: [Up to 3 synonyms, if any exists. If there are no synonyms skip this section]\n" ..
    "Paraphrase: \"[A short example sentence paraphrasing the selection using simpler words, with the same meaning and register]\"\n" ..
    "Etymology: [Concise and helpful etymology with a focus on the different parts that make up the word or interesting history in case of idioms, in under 20 words]" ..
    "(Pay close attention to the number of line breaks in the formatting of the response)"

function DictionaryPrompt.for_book_selection()
  return "I'm an advanced learner of English. I'm reading '{title}' by '{author}'{chapter}. My selected text: \n'{selection}'\n" ..
      "This is the context where it appears: '...{context}...'\n" ..
      RESPONSE_INSTRUCTIONS
end

function DictionaryPrompt.for_popup_selection(selection, popup_context, book_context)
  return "I'm an advanced learner of English. I selected this text inside an AI Dictionary answer: \n'" ..
      tostring(selection or "") .. "'\n" ..
      "This is the context where it appears in that answer: '..." .. tostring(popup_context or "") .. "...'\n" ..
      "The original book passage that led to the answer was: '..." .. tostring(book_context or "") .. "...'\n" ..
      RESPONSE_INSTRUCTIONS
end

return DictionaryPrompt
