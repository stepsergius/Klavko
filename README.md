# Klavko

[🇺🇦 Українська](README.uk.md) · 🇬🇧 **English**

A typing assistant for Mac (and, in beta, Windows) — in Ukrainian, English and 11 more languages. The basics are free; more features come with Klavko Pro.

Klavko switches the keyboard layout by itself when a word was typed in the wrong one (`ghbdsn` → `привіт`), fixes obvious typos and tidies up your text. It also has voice input, translation of selected text, text recognition from the screen and a clipboard history. Everything runs on your Mac: no accounts or online services, and nothing you type is sent anywhere.

⭐ **Like Klavko? Star this repository.** At 75 stars Klavko can join Homebrew’s main catalog, and installing becomes just `brew install --cask klavko`.

## Download

**With [Homebrew](https://brew.sh):**

```bash
brew install --cask stepsergius/klavko/klavko
```

**Or by hand:** **[⬇︎ Latest version](../../releases/latest)** — download `Klavko-….zip`, unzip it and follow “How to install Klavko.txt” in the archive (Ukrainian: «Як встановити Klavko.txt»).

Requirements: macOS 14 or later (translation needs macOS 15), at least two keyboard layouts of the supported languages (see “Layout languages”). The app is signed with a Developer ID and notarized by Apple, so macOS only asks once whether to open an app downloaded from the internet.

### Windows (beta)

**[⬇︎ Klavko for Windows](../../releases?q=windows&expanded=true)** — a beta of the same app for Windows 10 and 11. Download `Klavko-…-windows-x64.exe` (most computers) or `Klavko-…-windows-arm64.exe` (Windows on ARM, e.g. Snapdragon laptops) and run it. The app isn’t signed, so Windows SmartScreen warns on the first launch: click “More info” → “Run anyway”. Klavko then installs itself and updates from here.

It’s a beta: if something doesn’t work or works wrong, please tell us in the Telegram group **[t.me/klavko](https://t.me/klavko)**.

## Features

### Keyboard layout
- Type `ghb…` — by the third letter Klavko sees it’s the Ukrainian «при…» and switches the layout in the middle of the word.
- A word not recognized while typing is checked after Space, Tab, Return or punctuation: `ghbdsn?` becomes `привіт,`.
- Hotkeys to switch the layout of the word, the selection or everything just typed, and to change case (lower → Title → UPPER).
- Undo a fix with Backspace right after it, or by pressing the hotkey again.
- **Exceptions** — words Klavko never changes. Undo the fix of the same word twice and Klavko offers to add it.
- The current layout’s flag (🇺🇦, 🇺🇸, 🇩🇪…) in the menu bar and a soft sound after switching (can be changed or turned off). The menu lists the layouts with their flags: a click switches by hand.
- A word you went back into with Backspace (or retyped after deleting Klavko’s fix) is left as you write it.
- Off by default in terminals and code editors; any app can be excluded from the menu.
- **A layout for each app** (Pro): Klavko switches to the one you typed in that app (Ukrainian in Telegram, English in Terminal). You can also pin a layout to an app: Settings → Layout or the menu.
- **A hotkey for each layout** (Pro), even a lone modifier by its side: left ⌘ for Ukrainian, right ⌘ for English.
- **The Caps Lock light can show the language** (Pro, optional): lit for the language you choose, off for the others.

### The language flag at the cursor
- A small flag of the current language shows at the text cursor when you go to a text field, and goes away as soon as you start typing. It sits just above the cursor (below it when there’s no room above).
- When the layout changes (by you or by Klavko), the flag flashes for a second and a half; after a while without typing (15 seconds by default) it shows again.
- Next to the mouse pointer: the flag appears when you switch to another app and goes away after the pause.
- Esc hides the flag. Where it shows (at the text, at the pointer, in both places or nowhere) and a pause for each place, from 0 (always shown) to 60 seconds — Settings → General.

### Layout languages
- Switching works between any enabled macOS layouts of 13 languages, including Ukrainian, English, German, French, Spanish, Italian, Portuguese, Polish, Turkish, Greek, Hebrew and Arabic.
- With more than two layouts, Klavko checks the word against each language’s dictionary and picks the one where it is a real word. On a tie, a layout with a different alphabet comes first (Latin ↔ Cyrillic), then the one you used last.
- **Only by hand:** with three or more layouts, mark a language you rarely write in (for example Ukrainian next to Russian, where many words are the same). Klavko then never switches into it by itself; the hotkey still does.
- The text before the word helps decide: a typo at the start of a word doesn’t switch the layout in the middle of a sentence in the same language.
- Chinese, Japanese and Korean are typed with input methods rather than layouts, so they aren’t supported.
- **If the layout doesn’t switch:** check for a non-standard layout (installed separately, for example “Ukrainian — PC” from a .keylayout file). Klavko tries to work out its language itself and shows ⚠️ in its menu when it can’t. Standard macOS layouts work best: System Settings → Keyboard → Input Sources.

### Typos and formatting
- Obvious typos are fixed after the word: `teh` → `the`, `pertty` → `pretty`, `HEllo` → `Hello` (stuck Shift). Doubtful words, names mid-sentence and words with digits stay as they are.
- A missing space after punctuation: `Hi,there` → `Hi, there`.
- A capital at the start of a sentence; `...` → `…`, `"` → `“”` / `«»`, ` - ` → ` — `, `(c)` → `©`; lists `- ` and `1. ` continue after Return. Each of these has its own switch in Settings.
- Your own replacements: `ty` → `thank you`, `:)` → `🙂`.
- **The answer after “=”** (Pro): type `2+3*4=` or `Price 25*4=` and the answer appears at the cursor; Return or Tab inserts it.
- **Emoji by name** (Pro): a space, a colon and a name (`:laugh`, `:heart`) show emoji at the cursor; after some words Klavko suggests emoji by itself.

### Spelling and grammar check (Pro)
- [LanguageTool](https://languagetool.org) right on your Mac (~300 MB, downloaded once): **⌃⌥G** checks the selected text, and, if you like, mistakes are underlined while you type, also in Obsidian and Google Docs.
- Add to Dictionary next to an underlined word, and it’s no longer taken for a mistake.

### Voice input
- Press **fn (🌐)**, speak in the languages chosen in Settings (“I speak”: Ukrainian, English, German and more), press it again or Return — the text appears at the cursor. Esc cancels.
- A panel with a live wave shows what you say while you speak.
- Speech is recognized by the NVIDIA Parakeet Ultra model right on your Mac — with punctuation and automatic language detection. The model (~600 MB) is downloaded once; until then the built-in macOS recognition is used. Languages not chosen in “I speak” are never inserted. Turkish, Hebrew and Arabic are recognized by macOS.
- **One language** (Pro): each language can get a key of its own (for example, right ⌘ for Ukrainian, right ⌥ for English). Klavko then listens for that language only, so English spoken with an accent isn’t written in Cyrillic. For this input you can choose the [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) model (~2.9 GB): it recognizes English better but knows only 14 languages, without Ukrainian or Russian.
- **Google AI (optional):** in the voice settings you can choose “Google AI” and paste your own key from [aistudio.google.com](https://aistudio.google.com/apikey). The recording is then sent to Google when you finish and any language is recognized; the “smart” mode removes fillers and self-corrections. The key is kept in the Keychain. If Google can’t be reached, your Mac recognizes the text.
- **With translation** (Pro): **fn + ⌃** — speak in one language, and the translated text is inserted (the macOS translator, offline).
- **Voice commands:** “comma”, “period”, “question mark”, “new line”, “new paragraph” put the mark, and “literally comma” the word itself.
- **Vocabulary:** fix a dictated word by hand and Klavko offers to remember how you write it. Your replacements apply to voice input too.
- **History:** what you dictate is kept with its date and time (on your Mac only, can be turned off) — search it, copy or delete each entry.
- Choose the microphone; music and videos are turned down while you dictate (to a volume you set) and come back gradually.
- The look while dictating: an island by the camera, a small panel with the text, or no window. Statistics of what you dictated by day, month and year.

### Translation
- Select text anywhere and press **⌘** twice — the translation appears in a panel: Return replaces the selection, ⌘C copies.
- Text in your language goes into the chosen one, text in any other language into yours. The default pair (Ukrainian ↔ English at first) is set in Settings, and the languages can be changed right in the panel — the text is translated again at once.
- Translation languages: Ukrainian, English, German, French, Spanish, Italian, Portuguese, Polish, Turkish, Hebrew, Arabic and more.
- The macOS translator does the work on your Mac; the languages are downloaded once.

### Text from the screen
- Press **⌃Q** and select an area of the screen — Klavko reads the text in it (even in a picture or where it can’t be selected) and translates it with your language pair.
- The Translation / Original switch in the same panel shows the recognized text without translation; Copy takes what is shown.
- **QR codes:** select a QR code and Klavko shows what it holds; a link opens with Return.
- Recognition runs on your Mac, offline. It needs the Screen Recording permission (macOS asks once).

### Clipboard history
- **⌥⌘V** shows everything you copied: text, links, pictures, files — with search and preview.
- Return pastes into the app you came from; ⌘P pins, ⌘⌫ deletes, digits 1…9 pick an item (or paste it at once, as you choose in Settings). Links in copied text are clickable.
- Kept on your Mac only (30 days by default; without Pro the last 7 show). Passwords from password managers are never recorded, and you can list apps to record nothing from. The copy sound can be changed or turned off.

### Quick Actions
- Select text with the mouse and a bar appears over it: copy, search, translate, change case, wrap in quotes or brackets, bold and italic.
- With Pro also AI (ChatGPT, Claude, Perplexity), YouTube, Read Aloud, Transliterate by each language’s official system, Calculate (`1,250 * 3 + 15%`), Character Count and more.
- Choose the actions and their order in Settings → Quick Actions; point at an icon to see its name.

### Key remapping (Pro)
- Any key or combination can act as another, in every app and layout: Settings → Hotkeys.

### Interface and updates
- Settings with a sidebar: General, Layout, Text, Voice, Quick Actions, Clipboard, Hotkeys, Klavko Pro, About — and Say Thanks and What’s New at the bottom.
- The menu: the layouts with their flags, the main switches, Check for Updates, How to Use (a short welcome tour), Report a Problem…, Settings.
- **Report a problem:** describe what happened and Klavko sends it to the author with technical details you can see before sending. No typed text goes with it.
- **Move your settings:** Settings → General → Save to File…, and on another Mac Restore from File…
- Klavko tells you about a new version and updates with one “Update” button — nothing to download or install by hand.
- Interface languages: Українська, English, español, français, Deutsch, italiano, português, polski, Türkçe, 简体中文, 日本語 and 한국어.

## Hotkeys

All can be changed in Settings (Hotkeys tab).

| Action | Default |
|---|---|
| Switch the layout of the word | ⇧⇧ (Shift twice) |
| Switch the layout of the selection or everything typed | ⌥⌥ (Option twice) |
| Undo or redo a fix | not set |
| Change case | not set |
| Translate the selection | ⌘⌘ (Command twice) |
| Text from the screen (read and translate) | ⌃Q |
| Clipboard history | ⌥⌘V |
| Voice input | fn |
| Voice input with translation (Pro) | fn + ⌃ |
| Check the spelling and grammar of the selection (Pro) | ⌃⌥G |

A hotkey can be a key with modifiers (⌃⇧Space), modifiers alone together (⌥⌘), a double press (⇧⇧) or a double press within a combination (⌘C C: the first press copies as always, a quick second one runs the action). With “Tell left and right ⌃ ⌥ ⇧ ⌘ apart” on, a hotkey can use one side only, for example “twice right ⌘”.

## Privacy

Klavko runs entirely on your Mac. What you type and dictate, translations and the clipboard history are never sent anywhere; while you type, only the text since the last click or Return is kept in memory. The one exception is voice input through Google AI, if you turn it on yourself: then the recording is sent to Google. The internet is needed only once — to download the speech recognition model (from Hugging Face) and the translation languages (from Apple). Klavko also checks GitHub now and then for a new version (can be turned off in Settings), and talks to its license server about Pro: the trial start and founder status (known only by an anonymous fingerprint of the device) and checking a Pro key. A problem report is sent only when you click Send in Report a Problem, and you see everything in it first.

## Price

Everything basic in Klavko is free, with no time limit. **Klavko Pro** is a one-time $9.99 for two computers, Mac or Windows; new users get a 14-day Pro trial. **Everyone who installs Klavko before January 1, 2027 gets Pro free for good**, with no key. What Pro includes: [klavko.stepanix.com](https://klavko.stepanix.com/#pricing).

If Klavko helps you, you can also [thank the author](https://send.monobank.ua/jar/2CKJVz8jam) ❤️

## Credits

- Voice input: the [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) model (CC-BY-4.0), Parakeet Ultra version, in Core ML format via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0).
- Voice input in one language (optional): the [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) model (Apache-2.0) (int8 ONNX export by k2-fsa), run by [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) with [ONNX Runtime](https://github.com/microsoft/onnxruntime) (MIT).
- Translation, spell checking and fallback speech recognition — built-in macOS features.
- Some of the sounds (Bubble Pop, Click, Pen Click and others): [Pixabay](https://pixabay.com/sound-effects/), under the [Pixabay Content License](https://pixabay.com/service/license-summary/).

© 2026 Serhii Stepaniuk
