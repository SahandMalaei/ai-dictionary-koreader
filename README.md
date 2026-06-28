# AI Dictionary: Supercharged Dictionary/Explainer for KOReader

AI Dictionary is a dictionary/explanation plugin for KOReader that can have a transformative effect on your reading and learning. I built it out of personal frustration with the dictionary solutions that are currently available, and the resulting plugin is something I use every day with my reading. The limitations of traditional dictionaries, which this project adresses, include:
1. They give you multiple definitions of the same word and you need to figure out/guess which definition fits the context.
2. The built-in dictionaries of ebook readers generally don't support looking up the definition of multi-part phrases and idioms.
3. They can't give you the definition in the context of the book that you are reading, and might—understandably—lack the definiton for words which only make sense in the context of a book, e.g. fictional terms in a novel.

AI Dictionary gives you the meaning of your selected text **in the context** of its surrounding words, and also **in the context of the book you are reading**. You can ask for the definition of any number of words together, ask it to explain text in the context of the book, or to turn the selected text into more simplified English. All of that is available at the press of a button with no need to type anything. All the back-and-forth with the AI is done in the background, for a most seamless reading/learning experience.

![Demo](demo.gif)

## How to Use

To use this plugin, You'll need to do a few things, which I've listed below.

1. Get [KoReader](https://koreader.rocks/) installed on your e-reader/device.
2. Download [the latest release of this plugin](https://github.com/SahandMalaei/ai-dictionary-koreader/releases/latest).
3. The default AI provider is OpenAI's ChatGPT. Acquire an API key from [the OpenAI platform](https://platform.openai.com/). **Optional**: Alternatively, you can use any OpenAI-compatible AI provider of your own. I personally use [OpenRouter](https://openrouter.ai/api/v1/chat/completions) along with Google's Gemini 2.5 Flash for the best balance between speed and accuracy. You probably need to add some credits to your account, but from experience I can tell you that the personal use of this plugin is practically free (as long as you use fast and cheap models such as GPT5-Nano or Gemini 2.5 Flash). For reference, my own personal use over seven days costs me about 2 cents.
4. Once you have your API key, rename `configuration.lua.sample` to `configuration.lua` and inside it, replace `YOUR_API_KEY` with your own API key. **Optional**: Alternatively, you can use any OpenAI-compatible endpoint and model by setting them in `configuration.lua`. As said earlier, I personally use [OpenRouter](https://openrouter.ai/api/v1/chat/completions) along with `google/gemini-2.5-flash` for the quick and accurate results. For this, you need to fill out the `text_endpoint` and `text_model` properties of `configuration.lua` with values of your own.

```lua
local CONFIGURATION = {
    api_key = "YOUR_API_KEY",
    text_endpoint = "https://api.openai.com/v1/chat/completions",
    text_model = "gpt-5-nano"
}

return CONFIGURATION
```

**Android-Only:** The AI Dictionary popup can also show a Pronounce button on Android when AI voice output is configured. It uses the same `api_key` as text completion. You can use it by setting `voice_endpoint`, `voice_model`, and optionally `voice_voice` in `configuration.lua`:

```lua
voice_endpoint = "https://api.openai.com/v1/audio/speech",
voice_model = "gpt-4o-mini-tts",
voice_voice = "nova",
```

5. Copy the folder named `AI_Dictionary.koplugin` into the `koreader/plugins` directory on your device.
6. You'll most probably want to disable the automatic launch of KOReader's default dictionary functionality on single-word selection. To do that, open KOReader's top menu (tap on the top part of the screen), go to `Settings` (the gear icon), select `Long-press on text` and disable `Dictionary on single word selection`.
7. You are all set! Now simply select some word(s)/text, and use one of the options the plugins gives you ("AI Dictionary", "AI Explain", "AI English Simplify") to get answers.

## Sample config.lua

This is the configuration I personally use for the best results (don't forget to fill in your own API key):

```lua
local CONFIGURATION = {
    api_key = "[YOUR_API_KEY]",

    text_endpoint = "https://openrouter.ai/api/v1/chat/completions",
    text_model = "google/gemini-2.5-flash",

    voice_endpoint = "https://openrouter.ai/api/v1/audio/speech",
    voice_model = "x-ai/grok-voice-tts-1.0",
    voice_voice = "Ara"
}

return CONFIGURATION
```

## What's Next?

I'm calling on you—the community—to help expand this plugin with features that might help others read/study/learn better. A few starters:
1. The plugin is built around English-to-English dictionary lookups, though supporting other languages in the future might make sense. Making it seamless is the main challenge.
2. The plugin currently keeps a local log of every dictionary lookup. I'm open to suggestions about what kinds of personalized learning material we can create for the user with that.

This plugin wouldn't have been possible without the backbone provided by [AskGPT](https://github.com/drewbaumann/AskGPT)—an excellent plugin that lets you talk to ChatGPT directly from inside KOReader. Open source is awesome!

## Support the Project ❤️

If you found this project helpful, you can support the work through my [GitHub Sponsor page](https://github.com/sponsors/SahandMalaei).

License: GPLv3
