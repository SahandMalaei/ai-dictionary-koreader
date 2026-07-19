## Intro
This is an AI-powered, context-aware dictionary plugin for KOReader. It can look up the definition of the user's selected words, explain concepts, and simplify the selected text.
The Project is currently hosted on [GitHub](https://github.com/SahandMalaei/ai-dictionary-koreader) and is open-source.
## Development Guidelines
- Prefer a flat structure of small scripts each doing one specific thing, rather than big scripts doing everything.
- Prefer small, specialized functions to make the code more understandable and more easily debuggable.
- Avoid introducing dependencies that are not bundled with KOReader.
- The plugin is supposed to run on every OS KOReader supports, yet some of its features will naturally not work everywhere.
- Adopt a defensive approach in that all the code must be safe, with no errors causing KOReader to crash. We need good error-handling to catch exceptions wherever they arise, so they don't hurt the flow of KOReader's execution.