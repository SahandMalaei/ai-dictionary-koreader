## Intro
This is an AI-powered, context-aware dictionary plugin for KOReader. It can look up the definition of the user's selected words, explain concepts, and simplify the selected text.
The Project is currently hosted on [GitHub](https://github.com/SahandMalaei/ai-dictionary-koreader) and is open-source.
## Features
- The 3 main functionalities:
    1. AI Dictionary: Context-aware, LLM-powered dictionary lookups. Can also show one relevant picture from Wikipedia. It also includes a pronunciation feature. Pronunciation currently only works on Android.
    2. AI Explain: Explains the selected text in context using an LLM, similar to the X-Ray feature of Amazon's Kindle e-readers. Allows for diving deeper into a concept. Can also show one relevant picture from Wikipedia.
    3. AI Simplify: Simplifies the language used in the selected text.
- All the main functionalities include a "regenerate" button, to query the LLM again in case the original response was unsatisfactory.
- The configurable settings of the plugin reside in configuration.lua. Inside KOReader, all of those configs are also accessible through the plugin's own settings menu.
- Supports various LLM endpoints, as long as they use an OpenAI-compatible API.
- The dictionary lookups are stored on the device's persistent storage. There is an option to generate a vocabulary learning report of previous time periods.
## Development Guidelines
- Prefer a flat structure of small scripts each doing one specific thing, rather than big scripts doing everything.
- Prefer small, specialized functions to make the code more understandable and more easily debuggable.
- Avoid introducing dependencies that are not bundled with KOReader.
- The plugin is supposed to run on every OS KOReader supports, yet some of its features will naturally not work everywhere.
- Adopt a defensive approach in that all the code must be safe, ideally with no errors causing KOReader to crash. We need good error-handling to catch exceptions wherever they arise, so they don't propagate into KOReader.
- Design for reusability and long-term project development, rather than using quick fixes. Keep in mind that the project is going to expand and be under development for a long time, and the structure must remain robust no matter how many new features are added.
## Validation
After completing a set of changes:
1. Run LuaJIT syntax checks on every modified Lua file.
2. Perform isolated tests for modified functions and modules where practical.
3. Report any behavior that still requires testing inside KOReader.
If LuaJIT is unavailable, ask for permission before installing it. Runtime testing inside KOReader is performed by a human developer.