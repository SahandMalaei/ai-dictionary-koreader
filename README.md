# AI Dictionary: Supercharged Dictionary/Explainer for KOReader

AI Dictionary is a dictionary/explanation plugin for KOReader that can have a transformative effect on your reading and learning. I built it out of personal frustration with the dictionary solutions that are currently available, and the resulting plugin is something I use everyday with my reading. As I'm sure you are aware, the limitation of traditional dictionaries are:
1. They give you multiple definitions of the same word and you need to figure out which definition fits the context
2. The built-in dictionaries of ebook readers generally don't allow looking up the definition of multi-part words and idioms
3. They can't give you the definition in the context of the book that you are reading, and might—understandably—lack the definiton for words which only make sense in the context of a book, e.g. fictional terms in a novel.

AI Dictionary gives you the meaning of your selected text **in the context** of its surrounding words, and also **in the context of the book you are reading**. You can ask for the definition of any number of words, ask it to explain text in the context of the book, or to turn the selected text into more simplified English. All of that is available at the press of a button with no need to type anything. All the back-and-forth with the AI is done in the background, for a most seamless reading/learning experience.


## How to Use

To use this plugin, You'll need to do a few things:

1. Get [KoReader](https://github.com/koreader/koreader) installed on your e-reader/device.
2. Grab the latest release of this plugin, or clone the repository.
3. Acquire an API key from an API account on OpenAI. You need to add some credits to your account, but from experience I can tell you that the personal use of this plugin is practically free (mainly because it uses GPT5 mini—a fast and cheap AI model), so your credits probably won't be spent.
4. Once you have your API key, create a `configuration.lua` file in the following structure or modify and rename the `configuration.lua.sample` file. Replace YOUR_API_KEY with your own API key.

```lua
local CONFIGURATION = {
    api_key = "YOUR_API_KEY",
}

return CONFIGURATION
```
4. Copy the folder named `AI_Dictionary.koplugin` into the `koreader/plugins` directory on your device.
5. The plugin is ready! Now simply select some text, and use one of the options the plugins gives you ("AI Dictionary", "AI Explain", "English Explain") to get answers. You'll probably want to disable the automatic launch of KOReader's default dictionary functionality on single-word selection by opening KOReader's top menu (tap on the top part of the screen), going to `Settings` (the gear icon), selecting `Long-press on text` and disabling `Dictionary on single word selection`.


## What's Next?

I'm calling on the community to help expand this plugin with features that you think might help others read/study/learn better. Here are a few starters:
1. Add Gemini API as an option, to give the users more choice
2. Add a nice log file of every word/selection the user has looked up so far

This plugin wouldn't have been possible without the backbone provided by [AskGPT]("https://github.com/drewbaumann/AskGPT)—an excellent plugin that lets you talk to ChatGPT directly from inside KOReader. Open source is awesome!

License: GPLv3