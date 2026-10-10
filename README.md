# AI Dictionary for KOReader

I built AI Dictionary out of personal frustration with the dictionaries available on e-readers. Looking up a word often meant sorting through several definitions and guessing which one fit the sentence. Phrases, idioms, and fictional terms could leave me with nothing useful at all. I wanted something that understood what I was reading, and the resulting plugin is something I now use every day.

AI Dictionary lets you look up words and idioms, understand references, and simplify passages **in the context of your book**. It uses your selection, nearby text, and the book's title, author, and chapter (when available). Just select some text and choose an action.

![AI Dictionary in use inside KOReader](demo-v3.gif)

[Features](#features) · [Installation](#installation) · [Settings reference](#settings-reference) · [Vocabulary reports](#vocabulary-reports) · [Updates](#updates-and-saved-data) · [Troubleshooting](#troubleshooting)

## Features

| Action | What it does |
| --- | --- |
| **AI Dictionary** | Defines a word, phrase, or idiom in its current context, with pronunciation, usage tags, an example, synonyms, a simpler paraphrase, and etymology. |
| **AI Explain** | Explains concepts, characters, places, and allusions in relation to your book. |
| **AI Simplify** | Rewrites a difficult passage in simpler language. |

Inside the answer popup:

- Tap **↻** to regenerate an answer, or **✕** to close it.
- Tap a word or select a phrase in a Dictionary answer to look it up. In Explain, the same gesture explores that topic further.
- Use **‹** and **›** at the bottom to revisit answers and their images without querying again. Arrows appear only when usable; going back during a lookup cancels and discards its unfinished answer. A new lookup from an earlier answer replaces the forward history; regenerating replaces only the current answer. Closing the popup releases this in-memory history.
- Dictionary and Explain can show a relevant **Wikipedia image** when available; tap it to enlarge.
- On **Android**, configure voice output to hear dictionary pronunciations using the speaker button.

I built the dictionary around learning English, including American English pronunciation. You can also choose any other language (even fictional ones) for Dictionary and Explain answers; this setting does not change Simplify or vocabulary reports.

## Installation

You'll need [KOReader](https://koreader.rocks/), a network connection, and an API key from [OpenAI](https://platform.openai.com/), [OpenRouter](https://openrouter.ai/), or another provider supporting streaming OpenAI-compatible Chat Completions. API costs depend on your provider, model, and usage.

1. Download and extract the [latest release](https://github.com/SahandMalaei/ai-dictionary-koreader/releases/latest).
2. Copy the **`AI_Dictionary.koplugin`** folder into your device's `koreader/plugins` directory. The resulting path should be `koreader/plugins/AI_Dictionary.koplugin/main.lua`.
3. Now you need to configure the plugin. Settings are saved in `AI_Dictionary.koplugin/configuration.lua`. You can rename [configuration.lua.sample](AI_Dictionary.koplugin/configuration.lua.sample) to `configuration.lua` and edit the file yourself (easier), or edit the settings from the plugin's menu inside KOReader.

    A minimal configuration using the default OpenAI model, [GPT-5 nano](https://developers.openai.com/api/docs/models/gpt-5-nano):

    ```lua
    local CONFIGURATION = {
        api_key = "YOUR_API_KEY",
        text_endpoint = "https://api.openai.com/v1/chat/completions",
        text_model = "gpt-5-nano",
    }

    return CONFIGURATION
    ```

    For [Gemini 2.5 Flash through OpenRouter](https://openrouter.ai/google/gemini-2.5-flash), use an OpenRouter API key and replace these entries inside the table:

    ```lua
    text_endpoint = "https://openrouter.ai/api/v1/chat/completions",
    text_model = "google/gemini-2.5-flash",
    ```

4. Now tap and hold on any word or group of words, and select **AI Dictionary**, **AI Explain**, or **AI Simplify**.

**Tip:** If KOReader's default dictionary opens immediately, disable **Dictionary on single word selection** under **Settings → Taps and gestures → Long-press on text**. Menu placement may vary by KOReader version.

To launch an AI lookup directly when you release a text selection, choose **AI Dictionary**, **AI Explain**, or **AI Simplify** in that same **Long-press on text** menu. Disable **Dictionary on single word selection** to apply your choice to single words as well. A very-long press still opens the selection popup. Choose **Ask with popup dialog** to return to the normal menu.

## Settings reference
| Setting | Purpose / default |
| --- | --- |
| `api_key` | Your provider's API key; shared by text and voice requests. |
| `text_endpoint`, `text_model` | Full Chat Completions URL and default model ID; defaults shown above. **Default text model** is used by any feature group whose model is blank. |
| `output_language` | Language of Dictionary, Explain, and experimental Word Sense definitions; `"English"`. Dictionary section labels remain English. |
| `word_sense_active` | Enable automatic Word Sense annotations; `false` by default. Toggle **Word Sense** in the plugin settings or set this to `true` in `configuration.lua`. |
| `word_sense_level` | Word Sense reader proficiency: `"Basic"`, `"Intermediate"` (default), or `"Advanced"`. Choose from the reading-level list in the plugin settings. Basic provides the most help. |
| `dictionary_model`, `explain_model`, `word_sense_model` | Optional models for Dictionary + Simplify, Explain + reports, and Word Sense. Each defaults to `""`, using `text_model`. All share the text endpoint and API key. |
| `dictionary_reasoning_effort`, `explain_reasoning_effort`, `word_sense_reasoning_effort` | Separate reasoning controls for those groups; `""` sends no automatic reasoning parameters. Select an effort or **Use provider default** in settings. Supported levels depend on the provider and model. |
| `dictionary_parameters_json`, `explain_parameters_json`, `word_sense_parameters_json` | Config-only strings containing extra JSON request fields for each group; `""` adds nothing. Hidden from the settings menu. |
| `images` | Show Wikipedia images in Dictionary and Explain; `true`. |
| `voice_endpoint`, `voice_model`, `voice_voice` | Optional Android pronunciation; see below. |
| `update_check` | **Auto-check for updates:** toggle; checks at startup when enabled (`true` by default). |
| `debug_mode` | Show the query prompt alongside the answer for troubleshooting; `false`. |
| `additional_parameters` | Optional Lua table of extra text API request parameters supported by your provider. |

### Custom models and reasoning efforts

Dictionary and Simplify share `dictionary_model` and `dictionary_reasoning_effort`. Explain, its follow-up explorations, and vocabulary reports share the `explain_` settings. Word Sense uses the `word_sense_` settings. Regenerating keeps the same feature group. Blank models fall back to `text_model`, including on updates where the new settings are absent from the existing configuration.

### Word Sense

Word Sense automatically scans book text when enabled, using the configured Word Sense model. It marks difficult words, expressions, and idioms with subtle wavy underlines, with visual inspiration from [Footcream](https://github.com/Fank1/foot-cream), similar to Word Wise on Amazon's Kindle devices. Tap one to see a contextual meaning of up to five words in a small bubble beside the text.

Choose **AI Dictionary settings → Word Sense reading level → Basic / Intermediate / Advanced**. The level describes the reader's proficiency: Advanced marks only the most difficult vocabulary. Meanings follow `output_language`.

Word Sense is off by default. Enable it with **AI Dictionary settings → Word Sense**, or set `word_sense_active = true` in `configuration.lua`. 

### Pronunciation on Android

For OpenAI voice output with [GPT-4o mini TTS](https://developers.openai.com/api/docs/models/gpt-4o-mini-tts), add these entries inside the configuration table:

```lua
voice_endpoint = "https://api.openai.com/v1/audio/speech",
voice_model = "gpt-4o-mini-tts",
voice_voice = "nova",
```

The voice endpoint must accept the same API key as your text endpoint. When configured, audio is generated after each dictionary answer, even before you tap the speaker. Leave `voice_endpoint` or `voice_model` empty to disable it.

## Vocabulary reports

Open **Search (magnifying glass) → AI Dictionary Lookups Report** in KOReader's top menu, choose a timeframe, and tap **Generate Report**. Options range from **Today** to **All Time**. The AI uses your saved lookups to identify a learning pattern and create up to ten fill-in-the-blank exercises with answers.

## Updates and saved data

Use **AI Dictionary settings → Check for updates now**, or leave startup checks enabled. Accept an available update, then quit and restart KOReader.

The built-in updater preserves `configuration.lua` and `Lookups/`. Keep these when updating manually, too. Dictionary lookup dates, selected words, and surrounding context are stored in `AI_Dictionary.koplugin/Lookups/Lookups.txt`.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| No AI actions in the selection menu | Check the folder path above, enable the plugin in KOReader's plugin management menu if needed, and restart KOReader. |
| A request fails or returns no text | Check connectivity, API key, account balance, model ID, and the full endpoint URL. The text endpoint must support streaming Chat Completions. |
| No speaker button or audio | Pronunciation requires Android, a configured voice endpoint and model, and a key valid for that endpoint. Also check media volume. |
| No image | Enable **Show images**. Some topics have no suitable Wikipedia image. |
| An answer seems wrong | Try **↻** or select more context. Answers are AI-generated; the Explain prompt asks to avoid fiction spoilers, but cannot guarantee it. |

## Contributing and support

I'd love to hear what would help you read, study, or learn better. [Share an idea or report a bug](https://github.com/SahandMalaei/ai-dictionary-koreader/issues), or [contribute a pull request](https://github.com/SahandMalaei/ai-dictionary-koreader/pulls). There's plenty of room to make this more useful together.

For bug reports, include your device, KOReader version, plugin version, provider/model, and steps to reproduce. Remove API keys from anything you share.

This plugin wouldn't have been possible without the initial backbone provided by [AskGPT](https://github.com/drewbaumann/AskGPT), an excellent plugin that lets you talk to ChatGPT directly from inside KOReader. Open source is awesome!

If you find AI Dictionary helpful in your own reading, you can support the work through my [GitHub Sponsors page](https://github.com/sponsors/SahandMalaei). Thank you! ❤️

Licensed under [GPLv3](LICENSE).
