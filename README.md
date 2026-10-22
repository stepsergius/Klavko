# Klavko

[🇺🇦 Українська](README.uk.md) · 🇬🇧 **English**

A free typing assistant for Mac — in Ukrainian, English and 11 more languages.

Klavko switches the keyboard layout by itself when a word was typed in the wrong one (`ghbdsn` → `привіт`), fixes obvious typos and tidies up your text. It also has voice input, translation of selected text, text recognition from the screen and a clipboard history. Everything runs on your Mac: no accounts, keys or online services, and nothing you type is sent anywhere.

## Download

**[⬇︎ Latest version](../../releases/latest)** — download `Klavko-….zip`, unzip it and follow “How to install Klavko.txt” in the archive (Ukrainian: «Як встановити Klavko.txt»).

Requirements: macOS 14 or later (translation needs macOS 15), at least two keyboard layouts of the supported languages (see “Layout languages”). The app isn’t notarized by Apple, so macOS warns on the first launch — the guide explains how to open it.

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

### Layout languages
- Switching works between any enabled macOS layouts of 13 languages, including Ukrainian, English, German, French, Spanish, Italian, Portuguese, Polish, Turkish, Greek, Hebrew and Arabic.
- With more than two layouts, Klavko checks the word against each language’s dictionary and picks the one where it is a real word. On a tie, a layout with a different alphabet comes first (Latin ↔ Cyrillic), then the one you used last.
- **Only by hand:** with three or more layouts, mark a language you rarely write in (for example Ukrainian next to Russian, where many words are the same). Klavko then never switches into it by itself; the hotkey still does.
- The text before the word helps decide: a typo at the start of a word doesn’t switch the layout in the middle of a sentence in the same language.
- Chinese, Japanese and Korean are typed with input methods rather than layouts, so they aren’t supported.

### Typos and formatting
- Obvious typos are fixed after the word: `teh` → `the`, `pertty` → `pretty`, `HEllo` → `Hello` (stuck Shift). Doubtful words, names mid-sentence and words with digits stay as they are.
- A missing space after punctuation: `Hi,there` → `Hi, there`.
- A capital at the start of a sentence; `...` → `…`, `"` → `“”` / `«»`, ` - ` → ` — `, `(c)` → `©`; lists `- ` and `1. ` continue after Return. Each of these has its own switch in Settings.
- Your own replacements: `ty` → `thank you`, `:)` → `🙂`.

### Voice input
- Press **fn (🌐)**, speak in the languages chosen in Settings (“I speak”: Ukrainian, English, German and more), press it again or Return — the text appears at the cursor. Esc cancels.
- A panel with a live wave shows what you say while you speak.
- Speech is recognized by the NVIDIA Parakeet Ultra model right on your Mac — with punctuation and automatic language detection. The model (~600 MB) is downloaded once; until then the built-in macOS recognition is used. Languages not chosen in “I speak” are never inserted. Turkish, Hebrew and Arabic are recognized by macOS.
- **Google AI (optional):** in the voice settings you can choose “Google AI” and paste your own key from [aistudio.google.com](https://aistudio.google.com/apikey). The recording is then sent to Google when you finish and any language is recognized; the “smart” mode removes fillers and self-corrections. The key is kept in the Keychain. If Google can’t be reached, your Mac recognizes the text.
- **Vocabulary:** fix a dictated word by hand and Klavko offers to remember how you write it. Your replacements apply to voice input too.

### Translation
- Select text anywhere and press **⌘** twice — the translation appears in a panel: Return replaces the selection, ⌘C copies.
- Text in your language goes into the chosen one, text in any other language into yours. The default pair (Ukrainian ↔ English at first) is set in Settings, and the languages can be changed right in the panel — the text is translated again at once.
- Translation languages: Ukrainian, English, German, French, Spanish, Italian, Portuguese, Polish, Turkish, Hebrew, Arabic and more.
- The macOS translator does the work on your Mac; the languages are downloaded once.

### Text from the screen
- Press **⌃Q** and select an area of the screen — Klavko reads the text in it (even in a picture or where it can’t be selected) and translates it with your language pair.
- The Translation / Original switch in the same panel shows the recognized text without translation; Copy takes what is shown.
- Recognition runs on your Mac, offline. It needs the Screen Recording permission (macOS asks once).

### Clipboard history
- **⌥⌘V** shows everything you copied: text, links, pictures, files — with search and preview.
- Return pastes into the app you came from; ⌘P pins, ⌘⌫ deletes, ⌘1…⌘9 paste right away.
- Kept on your Mac only (30 days by default). Passwords from password managers are never recorded. The copy sound can be changed or turned off.

### Interface and updates
- Settings in tabs: General, Layout, Text, Voice, Clipboard, Hotkeys, About.
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

A hotkey can be a key with modifiers (⌃⇧Space), modifiers alone together (⌥⌘) or a double press (⇧⇧). With “Tell left and right ⌃ ⌥ ⇧ ⌘ apart” on, a hotkey can use one side only, for example “twice right ⌘”.

## Privacy

Klavko runs entirely on your Mac. What you type and dictate, translations and the clipboard history are never sent anywhere; while you type, only the text since the last click or Return is kept in memory. The one exception is voice input through Google AI, if you turn it on yourself: then the recording is sent to Google. The internet is needed only once — to download the speech recognition model (from Hugging Face) and the translation languages (from Apple). Klavko also checks GitHub now and then for a new version (can be turned off in Settings).

## Support

Klavko is free. If it helps you, you can [thank the author](https://send.monobank.ua/jar/2CKJVz8jam) ❤️

## For developers

```bash
swift test               # logic tests
scripts/install.sh       # build, install to /Applications and launch
scripts/share.sh         # archive to share (dist/Klavko-<version>.zip)
scripts/check-translations.py  # are all interface texts translated in Sources/KlavkoCore/Translations
```

On the first launch, allow access in **System Settings → Privacy & Security → Accessibility**.

- `Sources/KlavkoCore` — layouts, language detection, spell checking, clipboard history (no permissions needed, covered by tests).
- `Sources/Klavko` — the menu bar app: key capture, text replacement, voice input, translation, windows.

Log (without the typed text):

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "app.klavko.Klavko"'
```

## Credits

- Voice input: the [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) model (CC-BY-4.0), Parakeet Ultra version, in Core ML format via [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0).
- Translation, spell checking and fallback speech recognition — built-in macOS features.

© 2026 Serhii Stepaniuk
