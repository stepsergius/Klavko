#!/usr/bin/env python3
"""Builds the Klavko website (klavko.stepanix.com) into docs/: English in docs/, Ukrainian in docs/uk/.

Both pages come from the one template below, so their layout never drifts apart; only the texts differ.
Screenshots live in docs/assets as <name>-<light|dark>-<en|uk>.png; a page uses the dark one when the
visitor's system is in dark mode and the file exists.

    python3 scripts/build-site.py
"""
import html
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")
SITE = "https://klavko.stepanix.com/"
MAC = "https://github.com/stepsergius/Klavko/releases/latest"
WINDOWS = "https://github.com/stepsergius/Klavko/releases?q=windows&expanded=true"
BREW = "brew install --cask stepsergius/klavko/klavko"
THANKS = "https://send.monobank.ua/jar/2CKJVz8jam"
TELEGRAM = "https://t.me/klavko"
TAPKO = "https://tapko.stepanix.com/"

ICONS = {
    "layout": '<rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/>',
    "typo": '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13 7l4 4"/>',
    "voice": '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
    "translate": '<path d="M4 5h8M8 3v2m2 0c-1 4-3 7-6 9m2-5c1 2 3 4 6 5"/><path d="M13 21l4-9 4 9m-6.5-3h5"/>',
    "screen": '<path d="M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3"/><path d="M8 10h8M8 14h5"/>',
    "clipboard": '<rect x="6" y="4" width="12" height="17" rx="2"/><path d="M9 4V3h6v1M9 10h6M9 14h6"/>',
}

T = {
    "en": {
        "title": "Klavko · Free typing assistant for Mac",
        "description": "Klavko switches the keyboard layout when you type in the wrong one, fixes typos, and adds voice input, translation, text from the screen and a clipboard history. Free, and everything stays on your Mac.",
        "nav_aria": "Sections", "nav_features": "Features", "nav_download": "Download", "nav_faq": "FAQ",
        "lang_aria": "Language", "cta_nav": "Download",
        "icon_alt": "Klavko app icon",
        "h1": 'Just type. <em class="hl">Klavko fixes the rest.</em>',
        "lead": "Typed a word in the wrong layout? Klavko switches it as you type. It also fixes typos, types what you say, translates and reads text from the screen.",
        "cta_free": "Download free", "cta_more": "See what it does",
        "small": "Free · macOS 14 Sonoma or later · Windows 10 and 11 in beta",
        "shot1_aria": "Klavko settings: automatic layout switching",
        "shot1_bar": "Klavko Settings",
        "ex_h2": 'Wrong layout? <em class="hl">Not anymore.</em>',
        "ex_p": "A few things Klavko fixes for you, right where you type.",
        "examples": [
            ("ghbdsn", "привіт", "fixed by the third letter"),
            ("руддщ", "hello", "and back the other way"),
            ("teh", "the", "obvious typos"),
            ("HEllo", "Hello", "a stuck Shift"),
            ("Hi,there", "Hi, there", "a space after punctuation"),
            ("ty", "thank you", "your own replacements"),
        ],
        "feat_h2": 'One small app. <em class="hl">Six helpers.</em>',
        "feat_p": "Klavko lives in the menu bar. Turn on what you need, leave the rest off.",
        "features": [
            ("layout", "Keyboard layout", "Switches between the layouts of 13 languages, including Ukrainian, English, German, French, Polish and Turkish. ⇧⇧ switches a word by hand."),
            ("typo", "Typos and tidy text", "Fixes obvious typos, adds a capital at the start of a sentence, turns ... into … and \" into “” or «»."),
            ("voice", "Voice input", "Press fn, speak, press it again: the text appears at the cursor, with punctuation. Recognized on your Mac."),
            ("translate", "Translation", "Select text anywhere and press ⌘ twice. Return replaces the selection with the translation."),
            ("screen", "Text from the screen", "Press ⌃Q and select an area: Klavko reads the text, even in a picture, and translates it. QR codes too."),
            ("clipboard", "Clipboard history", "⌥⌘V shows everything you copied: text, links, pictures and files, with search. Passwords are never kept."),
        ],
        "shot2_aria": "Klavko voice input settings with the spoken languages",
        "shot2_bar": "Voice",
        "keys_h2": "Hotkeys you'll remember.",
        "keys_p": "All of them can be changed in Settings.",
        "keys": [
            ("⇧ ⇧", "Switch the layout of the word"),
            ("⌥ ⌥", "Switch the selection or everything typed"),
            ("⌘ ⌘", "Translate the selection"),
            ("⌃ Q", "Text from the screen"),
            ("⌥ ⌘ V", "Clipboard history"),
            ("fn", "Voice input"),
        ],
        "dl_h2": 'Free. <em class="hl">For good.</em>',
        "dl_p": "No account, no subscription, no ads.",
        "dl_mac": "Mac", "dl_mac_p": "macOS 14 or later. Translation needs macOS 15.",
        "dl_mac_btn": "Download for Mac",
        "dl_brew": "Homebrew", "dl_brew_p": "Install and update from the Terminal.",
        "dl_win": "Windows (beta)", "dl_win_p": "Windows 10 and 11. Pick the x64 file for most computers, arm64 for Snapdragon laptops.",
        "dl_win_btn": "Download for Windows",
        "priv_h2": "Your text stays yours.",
        "priv_p": "Klavko runs entirely on your Mac. What you type and dictate, translations and the clipboard history are never sent anywhere. The internet is needed only to download the speech model and translation languages once, and to check GitHub for a new version. The one exception is Google AI voice input, if you turn it on yourself.",
        "faq_h2": "Questions",
        "faq": [
            ("macOS says it can't verify Klavko. What do I do?",
             "Klavko isn't distributed through the App Store. The first time you open it, macOS may block it: open System Settings → Privacy &amp; Security, scroll down and click <b>Open Anyway</b>. You do this only once; updates install with one click."),
            ("Why does Klavko need Accessibility access?",
             "To see which keys you press and to replace a word typed in the wrong layout, macOS requires the Accessibility permission. Klavko keeps only the text since the last click or Return in memory, and never saves or sends it."),
            ("The layout doesn't switch. Why?",
             "You need at least two keyboard layouts of the supported languages. Standard macOS layouts work best (System Settings → Keyboard → Input Sources). Chinese, Japanese and Korean use input methods and aren't supported."),
            ("Is it really free?",
             "Yes, all of it. If Klavko helps you, you can thank the author, but you don't have to."),
            ("Where do I report a bug or ask a question?",
             'In the Telegram group <a href="' + TELEGRAM + '">t.me/klavko</a>. The Windows version is a beta, so reports there help a lot.'),
        ],
        "thanks_h2": "Like Klavko?",
        "thanks_p": "It's made by one person in Ukraine. A thank-you helps keep it free and growing.",
        "thanks_btn": "Say thanks", "tg_btn": "Telegram group",
        "also": "Also by Stepanix",
        "tapko_p": "Custom trackpad gestures for your Mac: middle click, close a window, open an app.",
        "footer_source": "Source code", "footer_privacy": "Privacy",
    },
    "uk": {
        "title": "Klavko · Безкоштовний помічник для набору тексту на Mac",
        "description": "Klavko перемикає розкладку, коли ви набрали слово не тією мовою, виправляє помилки, а ще вміє голосовий ввід, переклад, текст з екрана та історію буфера. Безкоштовно, і все лишається на вашому Mac.",
        "nav_aria": "Розділи", "nav_features": "Можливості", "nav_download": "Завантажити", "nav_faq": "Питання",
        "lang_aria": "Мова", "cta_nav": "Завантажити",
        "icon_alt": "Значок програми Klavko",
        "h1": 'Просто друкуйте. <em class="hl">Решту виправить Klavko.</em>',
        "lead": "Набрали слово не тією розкладкою? Klavko перемкне її просто під час набору. А ще виправить помилки, запише сказане, перекладе й прочитає текст з екрана.",
        "cta_free": "Завантажити безкоштовно", "cta_more": "Що він уміє",
        "small": "Безкоштовно · macOS 14 Sonoma або новіша · Windows 10 і 11 у беті",
        "shot1_aria": "Налаштування Klavko: автоматичне перемикання розкладки",
        "shot1_bar": "Klavko — Налаштування",
        "ex_h2": 'Не та розкладка? <em class="hl">Уже ні.</em>',
        "ex_p": "Кілька речей, які Klavko виправляє сам, просто там, де ви пишете.",
        "examples": [
            ("ghbdsn", "привіт", "уже на третій літері"),
            ("руддщ", "hello", "і навпаки"),
            ("teh", "the", "очевидні помилки"),
            ("ПРивіт", "Привіт", "затиснутий Shift"),
            ("Привіт,друже", "Привіт, друже", "пробіл після коми"),
            ("дз", "дякую за допомогу", "ваші власні заміни"),
        ],
        "feat_h2": 'Одна невелика програма. <em class="hl">Шість помічників.</em>',
        "feat_p": "Klavko живе в рядку меню. Увімкніть потрібне, решту можна не чіпати.",
        "features": [
            ("layout", "Розкладка", "Перемикає розкладки 13 мов, серед них українська, англійська, німецька, французька, польська й турецька. ⇧⇧ перемикає слово вручну."),
            ("typo", "Помилки й охайний текст", "Виправляє очевидні помилки, ставить велику літеру на початку речення, перетворює ... на … і \" на «» або “”."),
            ("voice", "Голосовий ввід", "Натисніть fn, говоріть, натисніть ще раз: текст з'явиться біля курсора, з розділовими знаками. Розпізнає ваш Mac."),
            ("translate", "Переклад", "Виділіть текст будь-де й двічі натисніть ⌘. Return замінить виділене перекладом."),
            ("screen", "Текст з екрана", "Натисніть ⌃Q і виділіть ділянку: Klavko прочитає текст, навіть на картинці, і перекладе його. QR-коди теж."),
            ("clipboard", "Історія буфера", "⌥⌘V показує все скопійоване: текст, посилання, картинки й файли, з пошуком. Паролі ніколи не зберігаються."),
        ],
        "shot2_aria": "Налаштування голосового вводу Klavko з мовами, якими ви говорите",
        "shot2_bar": "Голос",
        "keys_h2": "Клавіші, які легко запам'ятати.",
        "keys_p": "Будь-яку можна змінити в налаштуваннях.",
        "keys": [
            ("⇧ ⇧", "Перемкнути розкладку слова"),
            ("⌥ ⌥", "Перемкнути виділене або весь набраний текст"),
            ("⌘ ⌘", "Перекласти виділене"),
            ("⌃ Q", "Текст з екрана"),
            ("⌥ ⌘ V", "Історія буфера"),
            ("fn", "Голосовий ввід"),
        ],
        "dl_h2": 'Безкоштовно. <em class="hl">Назавжди.</em>',
        "dl_p": "Без облікового запису, підписки й реклами.",
        "dl_mac": "Mac", "dl_mac_p": "macOS 14 або новіша. Для перекладу потрібна macOS 15.",
        "dl_mac_btn": "Завантажити для Mac",
        "dl_brew": "Homebrew", "dl_brew_p": "Встановлення й оновлення з Термінала.",
        "dl_win": "Windows (бета)", "dl_win_p": "Windows 10 і 11. Для більшості комп'ютерів файл x64, для ноутбуків на Snapdragon — arm64.",
        "dl_win_btn": "Завантажити для Windows",
        "priv_h2": "Ваш текст лишається вашим.",
        "priv_p": "Klavko працює повністю на вашому Mac. Те, що ви набираєте й диктуєте, переклади й історія буфера нікуди не надсилаються. Інтернет потрібен лише раз, щоб завантажити модель розпізнавання мовлення та мови перекладу, і ще щоб перевіряти на GitHub нову версію. Єдиний виняток — голосовий ввід через Google AI, якщо ви самі його ввімкнете.",
        "faq_h2": "Питання",
        "faq": [
            ("macOS пише, що не може перевірити Klavko. Що робити?",
             "Klavko поширюється не через App Store. Під час першого запуску macOS може його заблокувати: відкрийте Системні параметри → Приватність і безпека, прогорніть униз і натисніть <b>Усе одно відкрити</b>. Це потрібно лише раз, оновлення встановлюються одною кнопкою."),
            ("Навіщо Klavko доступ до Універсального доступу?",
             "Щоб бачити натиснуті клавіші й замінювати слово, набране не тією розкладкою, macOS вимагає дозвіл Універсального доступу. Klavko тримає в пам'яті лише текст від останнього кліку чи Return і ніколи його не зберігає й не надсилає."),
            ("Розкладка не перемикається. Чому?",
             "Потрібні щонайменше дві розкладки підтримуваних мов. Найкраще працюють стандартні розкладки macOS (Системні параметри → Клавіатура → Джерела вводу). Китайська, японська й корейська вводяться методами вводу, тому не підтримуються."),
            ("Це справді безкоштовно?",
             "Так, повністю. Якщо Klavko вам допомагає, можна подякувати автору, але це не обов'язково."),
            ("Куди написати про помилку чи з питанням?",
             'У Telegram-групу <a href="' + TELEGRAM + '">t.me/klavko</a>. Версія для Windows — бета, тож відгуки там дуже допомагають.'),
        ],
        "thanks_h2": "Подобається Klavko?",
        "thanks_p": "Його робить одна людина в Україні. Подяка допомагає йому лишатися безкоштовним і рости.",
        "thanks_btn": "Подякувати", "tg_btn": "Telegram-група",
        "also": "Ще від Stepanix",
        "tapko_p": "Власні жести трекпада на Mac: середній клік, закрити вікно, відкрити програму.",
        "footer_source": "Вихідний код", "footer_privacy": "Конфіденційність",
    },
}

STYLE = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "site-style.css"), encoding="utf-8").read()


def svg(name):
    return ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
            f'stroke-linejoin="round" aria-hidden="true">{ICONS[name]}</svg>')


def shot(name, lang, prefix, aria, bar, extra=""):
    """A screenshot in a Mac window frame; the dark version is used in dark mode when it exists."""
    from PIL import Image  # only to read the size
    light = f"assets/{name}-light-{lang}.png"
    dark = f"assets/{name}-dark-{lang}.png"
    width, height = Image.open(os.path.join(DOCS, light)).size
    source = (f'\n        <source media="(prefers-color-scheme: dark)" srcset="{prefix}{dark}">'
              if os.path.exists(os.path.join(DOCS, dark)) else "")
    return f'''<div class="window"{extra} role="img" aria-label="{aria}">
      <div class="bar"><i></i><i></i><i></i><span>{bar}</span></div>
      <picture>{source}
        <img src="{prefix}{light}" alt="" width="{width}" height="{height}">
      </picture>
    </div>'''


def page(lang):
    t = T[lang]
    up = "../" if lang == "uk" else ""
    alt = "../" if lang == "uk" else "uk/"
    here = SITE + ("uk/" if lang == "uk" else "")
    en_link = (f'<a href="./" aria-current="true" lang="en" data-set-lang="en">EN</a>' if lang == "en"
               else f'<a href="../" hreflang="en" lang="en" data-set-lang="en" title="English">EN</a>')
    uk_link = (f'<a href="./" aria-current="true" lang="uk" data-set-lang="uk">UA</a>' if lang == "uk"
               else f'<a href="uk/" hreflang="uk" lang="uk" data-set-lang="uk" title="Українська">UA</a>')
    examples = "\n".join(
        f'        <div class="pair"><code>{html.escape(a)}</code><span class="arrow">→</span><b>{html.escape(b)}</b><span>{c}</span></div>'
        for a, b, c in t["examples"])
    features = "\n".join(
        f'        <div class="card"><span class="badge">{svg(icon)}</span><h3>{title}</h3><p>{html.escape(text)}</p></div>'
        for icon, title, text in t["features"])
    keys = "\n".join(
        f'        <div class="key">{"".join(f"<kbd>{k}</kbd>" for k in combo.split())}<span>{label}</span></div>'
        for combo, label in t["keys"])
    faq = "\n".join(
        f"        <details>\n          <summary>{q}</summary>\n          <p>{a}</p>\n        </details>" for q, a in t["faq"])
    download_icon = svg_download()
    return f'''<!doctype html>
<html lang="{lang}" data-alt="{alt}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{t["title"]}</title>
<meta name="description" content="{html.escape(t["description"])}">
<link rel="canonical" href="{here}">
<link rel="alternate" hreflang="en" href="{SITE}">
<link rel="alternate" hreflang="uk" href="{SITE}uk/">
<link rel="alternate" hreflang="x-default" href="{SITE}">
<meta property="og:title" content="Klavko">
<meta property="og:description" content="{html.escape(t["description"])}">
<meta property="og:image" content="{SITE}assets/icon.png">
<link rel="icon" href="{up}assets/icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:ital,wght@0,500;0,700;0,800;1,800&family=Inter:wght@400;500;600&display=swap">
<style>
{STYLE}</style>
<script>
/* Remembers the chosen language and opens that version on later visits. English is the default. */
(function () {{
  try {{
    var root = document.documentElement, saved = localStorage.getItem("klavko-lang");
    if (saved && saved !== root.lang && root.dataset.alt) location.replace(root.dataset.alt + location.search + location.hash);
    document.addEventListener("click", function (e) {{
      var link = e.target.closest && e.target.closest("[data-set-lang]");
      if (link) localStorage.setItem("klavko-lang", link.getAttribute("data-set-lang"));
    }});
  }} catch (e) {{}}
}})();
</script>
</head>
<body>

<header class="nav">
  <div class="wrap">
    <a class="brand" href="#top"><img src="{up}assets/icon.png" alt="">Klavko</a>
    <nav aria-label="{t["nav_aria"]}">
      <a href="#features">{t["nav_features"]}</a>
      <a href="#download">{t["nav_download"]}</a>
      <a href="#faq">{t["nav_faq"]}</a>
    </nav>
    <div class="lang" role="group" aria-label="{t["lang_aria"]}">
      {en_link}
      {uk_link}
    </div>
    <a class="btn primary" href="#download">{t["cta_nav"]}</a>
  </div>
</header>

<main id="top">
  <div class="wrap hero">
    <img class="icon" src="{up}assets/icon.png" alt="{t["icon_alt"]}" width="96" height="96">
    <h1>{t["h1"]}</h1>
    <p class="lead">{t["lead"]}</p>
    <div class="ctas">
      <a class="btn primary" href="#download">{download_icon}{t["cta_free"]}</a>
      <a class="btn" href="#features">{t["cta_more"]}</a>
    </div>
    <small>{t["small"]}</small>
  </div>

  <div class="wrap">
    {shot("layout", lang, up, t["shot1_aria"], t["shot1_bar"])}
  </div>

  <section>
    <div class="wrap">
      <div class="center">
        <h2>{t["ex_h2"]}</h2>
        <p>{t["ex_p"]}</p>
      </div>
      <div class="pairs">
{examples}
      </div>
    </div>
  </section>

  <section class="soft" id="features">
    <div class="wrap">
      <div class="center">
        <h2>{t["feat_h2"]}</h2>
        <p>{t["feat_p"]}</p>
      </div>
      <div class="grid">
{features}
      </div>
      {shot("voice", lang, up, t["shot2_aria"], t["shot2_bar"], ' style="max-width: 820px; margin-top: 48px;"')}
    </div>
  </section>

  <section>
    <div class="wrap">
      <div class="center">
        <h2>{t["keys_h2"]}</h2>
        <p>{t["keys_p"]}</p>
      </div>
      <div class="keys">
{keys}
      </div>
    </div>
  </section>

  <section class="soft" id="download">
    <div class="wrap">
      <div class="center">
        <h2>{t["dl_h2"]}</h2>
        <p>{t["dl_p"]}</p>
      </div>
      <div class="plans">
        <div class="plan pro">
          <h3>{t["dl_mac"]}</h3>
          <p>{t["dl_mac_p"]}</p>
          <a class="btn primary" href="{MAC}">{download_icon}{t["dl_mac_btn"]}</a>
          <h3 class="sub">{t["dl_brew"]}</h3>
          <p>{t["dl_brew_p"]}</p>
          <pre><code>{BREW}</code></pre>
        </div>
        <div class="plan">
          <h3>{t["dl_win"]}</h3>
          <p>{t["dl_win_p"]}</p>
          <a class="btn" href="{WINDOWS}">{download_icon}{t["dl_win_btn"]}</a>
        </div>
      </div>
    </div>
  </section>

  <section id="privacy">
    <div class="wrap">
      <div class="center">
        <span class="badge">{svg_lock()}</span>
        <h2>{t["priv_h2"]}</h2>
        <p>{t["priv_p"]}</p>
      </div>
    </div>
  </section>

  <section class="soft" id="faq">
    <div class="wrap">
      <div class="center"><h2>{t["faq_h2"]}</h2></div>
      <div class="faq">
{faq}
      </div>
    </div>
  </section>

  <section>
    <div class="wrap">
      <div class="center">
        <h2>{t["thanks_h2"]}</h2>
        <p>{t["thanks_p"]}</p>
        <div class="ctas">
          <a class="btn primary" href="{THANKS}">❤️ {t["thanks_btn"]}</a>
          <a class="btn" href="{TELEGRAM}">{t["tg_btn"]}</a>
        </div>
      </div>
      <a class="also" href="{TAPKO}{"uk/" if lang == "uk" else ""}">
        <img src="{up}assets/tapko.png" alt="" width="48" height="48">
        <span><small>{t["also"]}</small><b>Tapko</b><span>{t["tapko_p"]}</span></span>
        <span class="arrow" aria-hidden="true">→</span>
      </a>
    </div>
  </section>
</main>

<footer>
  <div class="wrap">
    <span>© 2026 Stepanix</span>
    <div class="links">
      <a href="#privacy">{t["footer_privacy"]}</a>
      <a href="https://github.com/stepsergius/Klavko">{t["footer_source"]}</a>
      <a href="{TELEGRAM}">Telegram</a>
    </div>
  </div>
</footer>
</body>
</html>
'''


def svg_download():
    return ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
            'stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12m0 0l-5-5m5 5l5-5M5 21h14"/></svg>')


def svg_lock():
    return ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" '
            'stroke-linejoin="round" aria-hidden="true"><rect x="5" y="11" width="14" height="10" rx="2"/>'
            '<path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>')


for lang, path in (("en", "index.html"), ("uk", "uk/index.html")):
    out = os.path.join(DOCS, path)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(page(lang))
    print("docs/" + path)
