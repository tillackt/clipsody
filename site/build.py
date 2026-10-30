#!/usr/bin/env python3
"""Builds the website's pages in all languages from site/content/<lang>.json into website/.

The HTML structure lives here, the texts in the JSON files, so every language has the same page.
Also writes sitemap.xml and the JSON-LD structured data (FAQ entries are the visible ones). The output
is committed: the site needs no build step on the server. After changing a text or the structure:

    python3 site/build.py           # write website/
    python3 site/build.py --check   # CI: fail if website/ is out of date

Hand-written pages (impressum.html, datenschutz.html, 404.html) are not touched.
"""
import hashlib
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTENT = ROOT / "site" / "content"
WEBSITE = ROOT / "website"
SITE = "https://tillackt.github.io/clipsody/"
DOWNLOAD = "https://github.com/tillackt/clipsody/releases/latest/download/Clipsody.dmg"
REPO = "https://github.com/tillackt/clipsody"
ISSUES = REPO + "/issues"
SECURITY_REPORT = REPO + "/security/advisories/new"
SUPPORT_FILE = "support.html"
LICENSE = "https://www.gnu.org/licenses/gpl-3.0.html"
PUBLISHED = "2026-10-30"
MODIFIED = "2026-10-30"
FINGERPRINT = "4d175a00dff7276c393a30bc11f2c9ec29cd17da08946cfada661e16b1f9a9d6"
AUTHOR = {"@type": "Person", "name": "tillackt", "url": "https://github.com/tillackt"}
# Pages in website/ that are written by hand; every other HTML file there belongs to the generator.
HANDWRITTEN = {"404.html", "impressum.html", "datenschutz.html"}

# Language code (hreflang, file name in site/content) → folder. German stays at the root, where the
# site started; English is x-default.
LANGUAGES = {"de": "", "en": "en/", "fr": "fr/", "es": "es/", "it": "it/", "nl": "nl/", "pl": "pl/", "pt-BR": "pt-br/"}
DEFAULT = "en"

I = "    "


def load():
    return {code: json.loads((CONTENT / f"{code}.json").read_text(encoding="utf-8")) for code in LANGUAGES}


def url(code, file=""):
    return SITE + LANGUAGES[code] + file


def rel(code, path):
    """`path` (relative to the site root) as seen from a page of `code`."""
    return ("../" if LANGUAGES[code] else "") + path or "./"


def text(fragment):
    """Visible text of an HTML fragment, whitespace collapsed."""
    return " ".join(html.unescape(re.sub(r"<[^>]+>", "", fragment)).split())


def fill(fragment, code, c):
    return (fragment.replace("{download}", DOWNLOAD).replace("{guide}", c["guideFile"])
            .replace("{issues}", ISSUES).replace("{security}", SECURITY_REPORT))


def attr(value):
    """Plain text for an attribute value or <title>; the JSON texts for page content may hold HTML."""
    return html.escape(value, quote=True)


def stylesheet(code):
    digest = hashlib.sha256((WEBSITE / "assets" / "style.css").read_bytes()).hexdigest()[:10]
    return rel(code, f"assets/style.css?v={digest}")


# ---------------------------------------------------------------------------------------------- head


def head(code, c, page, file, kind, all_content):
    title, description = page["title"], page["description"]
    alternates = "\n".join(
        f'{I}<link rel="alternate" hreflang="{other}" href="{url(other, file_for(other, all_content[other], kind))}">'
        for other in LANGUAGES)
    og_alternates = "\n".join(
        f'{I}<meta property="og:locale:alternate" content="{all_content[other]["ogLocale"]}">'
        for other in LANGUAGES if other != code)
    return f"""<!DOCTYPE html>
<html lang="{code}">
<head>
{I}<meta charset="utf-8">
{I}<meta name="viewport" content="width=device-width, initial-scale=1">
{I}<title>{attr(title)}</title>
{I}<meta name="description" content="{attr(description)}">
{I}<meta name="color-scheme" content="light dark">
{I}<link rel="canonical" href="{url(code, file)}">
{alternates}
{I}<link rel="alternate" hreflang="x-default" href="{url(DEFAULT, file_for(DEFAULT, all_content[DEFAULT], kind))}">
{I}<link rel="icon" href="{rel(code, 'assets/logo.svg')}" type="image/svg+xml">
{I}<link rel="apple-touch-icon" href="{rel(code, 'assets/icon-180.png')}">
{I}<link rel="stylesheet" href="{stylesheet(code)}">
{I}<meta property="og:type" content="{'article' if kind == 'guide' else 'website'}">
{I}<meta property="og:site_name" content="Clipsody">
{I}<meta property="og:locale" content="{c['ogLocale']}">
{og_alternates}
{I}<meta property="og:title" content="{attr(page['ogTitle'])}">
{I}<meta property="og:description" content="{attr(page['ogDescription'])}">
{I}<meta property="og:url" content="{url(code, file)}">
{I}<meta property="og:image" content="{SITE}assets/{og_image(code)}">
{I}<meta property="og:image:width" content="1200">
{I}<meta property="og:image:height" content="630">
{I}<meta property="og:image:alt" content="{attr(c['home']['ogImageAlt'])}">
{I}<meta name="twitter:card" content="summary_large_image">
{I}<meta name="twitter:image:alt" content="{attr(c['home']['ogImageAlt'])}">
{I}<script type="application/ld+json">
{structured_data(code, c, page, file, kind)}
{I}</script>
</head>"""


def og_image(code):
    """Rendered per language by .github/scripts/website-images.swift."""
    return f"og-{code.lower()}.jpg"


def file_for(code, c, kind):
    return {"home": "", "guide": c["guideFile"], "support": SUPPORT_FILE}[kind]


# -------------------------------------------------------------------------------------------- header


def header(code, c, nav, kind, all_content):
    current = SUPPORT_FILE if kind == "support" else None
    links = "\n".join(f'{I*3}<a href="{href}"{" aria-current=\"page\"" if href == current else ""}>{label}</a>'
                      for href, label in nav)
    langs = "\n".join(
        f'{I*4}<li><a href="{rel(code, LANGUAGES[other] + file_for(other, all_content[other], kind))}" '
        f'hreflang="{other}" lang="{other}"{" aria-current=\"page\"" if other == code else ""}>'
        f'{all_content[other]["name"]}</a></li>'
        for other in LANGUAGES)
    return f"""<a class="skip" href="#main">{c['skipLink']}</a>
<header class="top">
{I}<div class="wrap">
{I*2}<a class="brand" href="./"><img src="{rel(code, 'assets/logo.svg')}" alt="" width="28" height="28">Clipsody</a>
{I*2}<nav aria-label="{c['mainNav']}">
{links}
{I*2}</nav>
{I*2}<details class="langs">
{I*3}<summary><span aria-hidden="true">🌐</span> <span class="visually-hidden">{c['otherLanguages']}: </span>{c['name']}</summary>
{I*3}<ul>
{langs}
{I*3}</ul>
{I*2}</details>
{I}</div>
</header>"""


def footer(code, c, kind):
    f = c["footer"]
    extra = (f'{I*2}<a href="{c["guideFile"]}">{f["guide"]}</a>' if kind == "home"
             else f'{I*2}<a href="./">{f["home"]}</a>')
    return f"""<footer>
{I}<div class="wrap">
{I*2}<span>{f['tagline']}</span>
{extra}
{I*2}<a href="{SUPPORT_FILE}"{' aria-current="page"' if kind == "support" else ""}>{f['support']}</a>
{I*2}<a href="{REPO}">GitHub</a>
{I*2}<a href="{REPO}/releases">{f['releases']}</a>
{I*2}<span>{f['license']} <a href="{LICENSE}">GPLv3</a></span>
{I*2}<span class="spacer"></span>
{I*2}<a href="{rel(code, 'impressum.html')}">{f['legal']}</a>
{I*2}<a href="{rel(code, 'datenschutz.html')}">{f['privacyPolicy']}</a>
{I}</div>
</footer>"""


# ---------------------------------------------------------------------------------------------- home


def panel(search, entries, selected, preview, info, hint):
    rows = "\n".join(
        f'{I*7}<li{" class=\"sel\"" if index == selected else ""}><span class="ico {icon}"></span>'
        f'<span class="t">{label}</span><span class="k">⌘{index + 1}</span></li>'
        for index, (icon, label) in enumerate(entries))
    return f"""{I*4}<div class="panel">
{I*5}<div class="search">{search}<span class="caret"></span></div>
{I*5}<div class="body">
{I*6}<ul>
{rows}
{I*6}</ul>
{I*6}<div class="preview">
{I*7}{preview}
{I*7}<div class="info">{info}</div>
{I*7}<div class="hint">{hint}</div>
{I*6}</div>
{I*5}</div>
{I*4}</div>"""


def hero_figure(code, h):
    empty = f'<span class="placeholder">{h["placeholder"]}</span>'
    photo = (f'<picture><source srcset="{rel(code, "assets/sample-photo.avif")}" type="image/avif">'
             f'<img class="photo" src="{rel(code, "assets/sample-photo.jpg")}" alt="" width="940" height="470" '
             f'loading="lazy" decoding="async" fetchpriority="low"></picture>')
    file_card = (f'<div class="file"><span class="doc">PDF</span><b>{h["fileName"]}</b>'
                 f'<span>{h["filePath"]}</span><span>{h["fileMeta"]}</span></div>')
    scenes = [
        panel(empty, h["items"], 0, f'<div class="img">{h["textPreview"]}</div>', h["textInfo"], h["hint"]),
        panel(empty, h["items"], 1, photo, h["imageInfo"], h["hint"]),
        panel(empty, h["items"], 2, file_card, h["fileInfo"], h["hint"]),
        panel(f'<span class="typed">{h["ocrSearch"]}</span>', h["ocrItems"], 0,
              f'<div class="img">{h["ocrPreview"]}</div>', h["ocrInfo"], h["hint"]),
    ]
    parts = [f'{I*2}<figure class="shot">', f'{I*3}<div class="scenes" aria-hidden="true">']
    for number, (label, scene) in enumerate(zip(h["labels"], scenes), start=1):
        parts += [f'{I*3}<div class="scene s{number}">',
                  f'{I*4}<p class="scene-label"><span class="step">{number}</span>{label}</p>',
                  scene, f'{I*3}</div>']
    # Pause control (WCAG 2.2.2, no script): a checkbox right before its label, so the focus ring
    # shows where the control is; CSS pauses the figure with :has().
    parts += [f'{I*3}</div>',
              f'{I*3}<div class="controls">',
              f'{I*4}<span class="dots" aria-hidden="true"><span class="s1"></span><span class="s2"></span>'
              f'<span class="s3"></span><span class="s4"></span></span>',
              f'{I*4}<input class="pause-toggle visually-hidden" type="checkbox" id="pause-hero">',
              f'{I*4}<label class="pause" for="pause-hero"><span class="icon" aria-hidden="true"></span>{h["pause"]}</label>',
              f'{I*3}</div>',
              f'{I*3}<figcaption class="caption">{h["caption"]}</figcaption>',
              f'{I*2}</figure>']
    return "\n".join(parts)


def section(section_id, alt, h2, sub, body):
    cls = ' class="alt"' if alt else ""
    sub_html = f'\n{I*3}<p class="sub">{sub}</p>' if sub is not None else ""
    return f"""{I}<section{cls} id="{section_id}">
{I*2}<div class="wrap">
{I*3}<h2>{h2}</h2>{sub_html}
{body}
{I*2}</div>
{I}</section>"""


def cards(items, with_icon=False):
    rendered = []
    for item in items:
        if with_icon:
            icon, title, body = item
            rendered.append(f'{I*4}<div class="card"><div class="icon" aria-hidden="true">{icon}</div><h3>{title}</h3>\n'
                            f'{I*5}<p>{body}</p></div>')
        else:
            title, body = item
            rendered.append(f'{I*4}<div class="card"><h3>{title}</h3>\n{I*5}<p>{body}</p></div>')
    return f'{I*3}<div class="grid">\n' + "\n".join(rendered) + f'\n{I*3}</div>'


def compare_table(head_cells, rows, label, indent=3):
    pad = I * indent
    head_html = "".join(f'<th scope="col">{cell}</th>' for cell in head_cells)
    body = "\n".join(f'{pad}{I*2}<tr><th scope="row">{row[0]}</th>' + "".join(f"<td>{cell}</td>" for cell in row[1:]) + "</tr>"
                     for row in rows)
    return f"""{pad}<section class="table-scroll" tabindex="0" aria-label="{attr(text(label))}">
{pad}{I}<table class="compare">
{pad}{I*2}<thead>
{pad}{I*2}<tr><td></td>{head_html}</tr>
{pad}{I*2}</thead>
{pad}{I*2}<tbody>
{body}
{pad}{I*2}</tbody>
{pad}{I}</table>
{pad}</section>"""


def keys_table(rows, indent=3):
    pad = I * indent
    body = "\n".join(f'{pad}{I}<tr><th scope="row">{key}</th><td>{label}</td></tr>' for key, label in rows)
    return f"""{pad}<table class="keys">
{pad}{I}<tbody>
{body}
{pad}{I}</tbody>
{pad}</table>"""


def faq_list(items, indent=3, fill_with=None):
    pad = I * indent
    return "\n".join(f"{pad}<details><summary>{q}</summary>\n{pad}{I}<p>{fill(a, *fill_with) if fill_with else a}</p></details>"
                     for q, a in items)


def mini_window(o, highlighted):
    title = f'<mark>{o["dialogTitle"]}</mark>' if highlighted else o["dialogTitle"]
    body = f'<mark>{o["dialogText"]}</mark>' if highlighted else o["dialogText"]
    badge = f'<span class="scan">{o["recognised"]}</span>' if highlighted else ""
    return (f'<div class="mini-window"><span class="lights"><i></i><i></i><i></i></span>{badge}'
            f'<p class="warn">⚠︎ <b>{title}</b></p><p>{body}</p><span class="ok">OK</span></div>')


def ocr_body(o):
    visuals = [mini_window(o, False), mini_window(o, True),
               f'<div class="mini-search"><p class="q">{o["query"]}<span class="caret"></span></p>'
               f'<p class="hit"><span class="ico a"></span>{o["result"]}</p></div>']
    steps = "\n".join(
        f"""{I*4}<div class="card ocr-step">
{I*5}<div class="visual" aria-hidden="true">{visual}</div>
{I*5}<h3><span class="step">{number}</span>{title}</h3>
{I*5}<p>{body}</p>
{I*4}</div>"""
        for number, ((title, body), visual) in enumerate(zip(o["steps"], visuals), start=1))
    return f'{I*3}<div class="grid ocr">\n{steps}\n{I*3}</div>\n{I*3}<div class="note">{o["note"]}</div>'


def home_page(code, c, all_content):
    p = c["home"]
    nav = [("#features", p["nav"]["features"]), ("#compare", p["nav"]["compare"]), ("#privacy", p["nav"]["privacy"]),
           ("#install", p["nav"]["install"]), ("#faq", p["nav"]["faq"]), (SUPPORT_FILE, p["nav"]["support"])]
    badges = "\n".join(f'{I*3}<span class="badge">{badge}</span>' for badge in p["badges"])
    problem = p["problem"]
    without = "\n".join(f"{I*6}<li>{item}</li>" for item in problem["without"])
    with_ = "\n".join(f"{I*6}<li>{item}</li>" for item in problem["with"])
    problem_body = f"""{I*3}<div class="grid two">
{I*4}<div class="card"><h3>{problem['withoutTitle']}</h3>
{I*5}<ul class="plain">
{without}
{I*5}</ul></div>
{I*4}<div class="card"><h3>{problem['withTitle']}</h3>
{I*5}<ul class="plain">
{with_}
{I*5}</ul></div>
{I*3}</div>"""
    compare = p["compare"]
    compare_body = compare_table(compare["head"], compare["rows"], compare["h2"]) + \
        f'\n{I*3}<p class="asof">{c["spotlightAsOf"]}</p>' + \
        f'\n{I*3}<p class="more">{fill(compare["more"], code, c)}</p>'
    install = p["install"]
    steps = "\n".join(f"{I*4}<li>{fill(step, code, c)}</li>" for step in install["steps"])
    install_body = f"""{I*3}<ol class="steps">
{steps}
{I*3}</ol>
{I*3}<div class="note" id="verify">
{I*4}{install['verify']}
{I*4}<pre><code>shasum -a 256 ~/Downloads/Clipsody.dmg
codesign -d --extract-certificates=/tmp/clipsody-cert /Applications/Clipsody.app &amp;&amp; shasum -a 256 /tmp/clipsody-cert0</code></pre>
{I*4}{install['fingerprint']} <code>{FINGERPRINT}</code>
{I*3}</div>"""
    sections = [
        ("problem", problem["h2"], problem["sub"], problem_body),
        ("features", p["features"]["h2"], p["features"]["sub"], cards(p["features"]["cards"], with_icon=True)),
        ("text-in-images", p["ocr"]["h2"], p["ocr"]["sub"], ocr_body(p["ocr"])),
        ("uses", p["uses"]["h2"], p["uses"]["sub"], cards(p["uses"]["cards"])),
        ("compare", compare["h2"], compare["sub"], compare_body),
        ("keys", p["keys"]["h2"], p["keys"]["sub"], keys_table(p["keys"]["rows"])),
        ("privacy", p["privacy"]["h2"], p["privacy"]["sub"], cards(p["privacy"]["cards"])),
        ("install", install["h2"], install["sub"], install_body),
        ("faq", p["faq"]["h2"], None, faq_list(p["faq"]["items"], fill_with=(code, c))),
    ]
    rendered = "\n\n".join(section(sid, index % 2 == 0, h2, sub, body)
                           for index, (sid, h2, sub, body) in enumerate(sections))
    return f"""{head(code, c, p, "", "home", all_content)}
<body>
{header(code, c, nav, "home", all_content)}

<main id="main">
{I}<div class="hero wrap">
{I*2}<h1>{p['h1']}</h1>
{I*2}<p class="lead">{p['lead']}</p>
{I*2}<div class="cta">
{I*3}<a class="button" href="{DOWNLOAD}">{p['download']}</a>
{I*3}<a class="button secondary" href="{REPO}">{p['source']}</a>
{I*2}</div>
{I*2}<p class="meta">{p['meta']}</p>
{I*2}<div class="badges">
{badges}
{I*2}</div>

{hero_figure(code, p['hero'])}
{I}</div>

{rendered}
</main>

{footer(code, c, "home")}
</body>
</html>
"""


# --------------------------------------------------------------------------------------------- guide


def guide_page(code, c, all_content):
    g = c["guide"]
    nav_labels = c["home"]["nav"]
    nav = [("./#features", nav_labels["features"]), ("./#install", nav_labels["install"]), ("./#faq", nav_labels["faq"]),
           (SUPPORT_FILE, nav_labels["support"])]

    def steps(items):
        return f"{I}<ol>\n" + "\n".join(f"{I*2}<li>{fill(item, code, c)}</li>" for item in items) + f"\n{I}</ol>"

    blocks = []
    for block_id, key in [("finder", "finder"), ("spotlight", "spotlight"), ("clipboard-manager", "manager")]:
        b = g[key]
        blocks.append(f'{I}<h2 id="{block_id}">{b["h2"]}</h2>\n{I}<p>{fill(b["intro"], code, c)}</p>\n'
                      f'{steps(b["steps"])}\n{I}<p>{fill(b["after"], code, c)}</p>')
    blocks.append(f'{I}<h2 id="compare">{g["compare"]["h2"]}</h2>\n'
                  + compare_table(g["compare"]["head"], g["compare"]["rows"], g["compare"]["h2"], 1)
                  + f'\n{I}<p class="asof">{c["spotlightAsOf"]}</p>')
    blocks.append(f'{I}<h2 id="shortcuts">{g["shortcuts"]["h2"]}</h2>\n' + keys_table(g["shortcuts"]["rows"], 1))
    blocks.append(f'{I}<h2 id="faq">{g["faq"]["h2"]}</h2>\n' + faq_list(g["faq"]["items"], 1))
    cta = g["cta"]
    body = "\n\n".join(blocks)
    return f"""{head(code, c, g, c['guideFile'], "guide", all_content)}
<body>
{header(code, c, nav, "guide", all_content)}

<main class="article wrap" id="main">
{I}<nav class="crumbs" aria-label="{g['breadcrumbLabel']}"><a href="./">Clipsody</a> › <span aria-current="page">{g['crumb']}</span></nav>
{I}<h1>{g['h1']}</h1>
{I}<p class="lead">{g['lead']}</p>
{I}<p class="updated">{g['updated']}</p>

{I}<div class="note">{g['summary']}</div>

{body}

{I}<div class="cta-box">
{I*2}<h2>{cta['h2']}</h2>
{I*2}<p>{cta['text']}</p>
{I*2}<a class="button" href="{DOWNLOAD}">{cta['button']}</a>
{I}</div>
</main>

{footer(code, c, "guide")}
</body>
</html>
"""


# ------------------------------------------------------------------------------------------- support


def support_page(code, c, all_content):
    """A form that opens GitHub's issue form with the entries filled in (field ids of
    .github/ISSUE_TEMPLATE/*.yml as query parameters). No script and no server: the browser sends a
    GET request to GitHub, and the visitor submits the issue there with their own account."""
    s = c["support"]
    nav_labels = c["home"]["nav"]
    nav = [("./#features", nav_labels["features"]), ("./#install", nav_labels["install"]), ("./#faq", nav_labels["faq"]),
           (SUPPORT_FILE, nav_labels["support"])]
    check = "\n".join(f"{I*2}<li>{fill(item, code, c)}</li>" for item in s["check"])
    include = "\n".join(f"{I*2}<li>{fill(item, code, c)}</li>" for item in s["include"])
    return f"""{head(code, c, s, SUPPORT_FILE, "support", all_content)}
<body>
{header(code, c, nav, "support", all_content)}

<main class="article wrap" id="main">
{I}<nav class="crumbs" aria-label="{s['breadcrumbLabel']}"><a href="./">Clipsody</a> › <span aria-current="page">{s['crumb']}</span></nav>
{I}<h1>{s['h1']}</h1>
{I}<p class="lead">{s['lead']}</p>

{I}<h2 id="check">{s['checkTitle']}</h2>
{I}<ul>
{check}
{I}</ul>

{I}<h2 id="report">{s['formTitle']}</h2>
{I}<p>{s['formIntro']}</p>
{I}<form class="support-form" method="get" action="{ISSUES}/new">
{I*2}<label for="issue-title">{s['titleLabel']}</label>
{I*2}<input id="issue-title" name="title" type="text" maxlength="120" placeholder="{attr(s['titlePlaceholder'])}">
{I*2}<label for="issue-description">{s['descriptionLabel']}</label>
{I*2}<textarea id="issue-description" name="description" rows="6" maxlength="1500" placeholder="{attr(s['descriptionPlaceholder'])}"></textarea>
{I*2}<div class="pair">
{I*3}<div>
{I*4}<label for="issue-version">{s['versionLabel']}</label>
{I*4}<input id="issue-version" name="clipsody-version" type="text" maxlength="80" aria-describedby="issue-version-hint">
{I*4}<p class="hint" id="issue-version-hint">{s['versionHint']}</p>
{I*3}</div>
{I*3}<div>
{I*4}<label for="issue-macos">{s['macosLabel']}</label>
{I*4}<input id="issue-macos" name="macos-version" type="text" maxlength="80" aria-describedby="issue-macos-hint">
{I*4}<p class="hint" id="issue-macos-hint">{s['macosHint']}</p>
{I*3}</div>
{I*2}</div>
{I*2}<p class="note">{s['publicNote']}</p>
{I*2}<div class="cta">
{I*3}<button class="button" type="submit" name="template" value="bug_report.yml">{s['bugButton']}</button>
{I*3}<button class="button secondary" type="submit" name="template" value="feature_request.yml">{s['ideaButton']}</button>
{I*2}</div>
{I}</form>

{I}<h2 id="details">{s['includeTitle']}</h2>
{I}<ul>
{include}
{I}</ul>

{I}<h2 id="security">{s['securityTitle']}</h2>
{I}<p>{fill(s['securityText'], code, c)}</p>
</main>

{footer(code, c, "support")}
</body>
</html>
"""


# ----------------------------------------------------------------------------------- structured data


def structured_data(code, c, page, file, kind):
    page_url = url(code, file)
    items = []
    if kind == "support":
        items.append({
            "@type": "BreadcrumbList",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "Clipsody", "item": url(code)},
                {"@type": "ListItem", "position": 2, "name": page["crumb"], "item": page_url},
            ],
        })
    elif kind == "home":
        items.append({
            "@type": "SoftwareApplication",
            "name": "Clipsody",
            "url": page_url,
            "description": page["appDescription"],
            "applicationCategory": "UtilitiesApplication",
            "operatingSystem": "macOS 13 or later",
            "offers": {"@type": "Offer", "price": "0", "priceCurrency": "EUR"},
            "isAccessibleForFree": True,
            "downloadUrl": DOWNLOAD,
            "license": LICENSE,
            "image": SITE + "assets/" + og_image(code),
            "inLanguage": list(LANGUAGES),
            "author": AUTHOR,
        })
    else:
        items.append({
            "@type": "Article",
            "headline": text(page["h1"]),
            "description": html.unescape(page["description"]),
            "inLanguage": code,
            "datePublished": PUBLISHED,
            "dateModified": MODIFIED,
            "mainEntityOfPage": page_url,
            "image": SITE + "assets/" + og_image(code),
            "author": AUTHOR,
        })
        items.append({
            "@type": "BreadcrumbList",
            "itemListElement": [
                {"@type": "ListItem", "position": 1, "name": "Clipsody", "item": url(code)},
                {"@type": "ListItem", "position": 2, "name": page["crumb"], "item": page_url},
            ],
        })
    if "faq" in page:
        items.append({
            "@type": "FAQPage",
            "mainEntity": [{"@type": "Question", "name": text(q), "acceptedAnswer": {"@type": "Answer", "text": text(a)}}
                           for q, a in page["faq"]["items"]],
        })
    data = json.dumps({"@context": "https://schema.org", "@graph": items}, ensure_ascii=False, indent=2)
    # "</" inside the JSON would end the script element early.
    return data.replace("</", "<\\/")


# ------------------------------------------------------------------------------------------- sitemap


def sitemap(all_content):
    entries = []
    for kind in ("home", "guide", "support"):
        alternates = "\n".join(
            f'    <xhtml:link rel="alternate" hreflang="{code}" href="{url(code, file_for(code, all_content[code], kind))}"/>'
            for code in LANGUAGES)
        default = url(DEFAULT, file_for(DEFAULT, all_content[DEFAULT], kind))
        for code in LANGUAGES:
            entries.append(f"""  <url>
    <loc>{url(code, file_for(code, all_content[code], kind))}</loc>
    <lastmod>{MODIFIED}</lastmod>
{alternates}
    <xhtml:link rel="alternate" hreflang="x-default" href="{default}"/>
  </url>""")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(entries) + "\n</urlset>\n")


# ---------------------------------------------------------------------------------------------- main


def outputs():
    all_content = load()
    files = {"sitemap.xml": sitemap(all_content)}
    for code, c in all_content.items():
        files[LANGUAGES[code] + "index.html"] = home_page(code, c, all_content)
        files[LANGUAGES[code] + c["guideFile"]] = guide_page(code, c, all_content)
        files[LANGUAGES[code] + SUPPORT_FILE] = support_page(code, c, all_content)
    return files


def leftovers(names):
    """Generated pages from earlier builds that the current content no longer produces."""
    relative = (str(path.relative_to(WEBSITE)) for path in WEBSITE.rglob("*.html"))
    return sorted(name for name in relative if name not in names and name not in HANDWRITTEN)


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    files = outputs()
    for name in leftovers(files):
        stale.append(name + " (no longer generated)")
        if not check:
            (WEBSITE / name).unlink()
    for name, content in files.items():
        path = WEBSITE / name
        if not path.exists() or path.read_text(encoding="utf-8") != content:
            stale.append(name)
            if not check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
    if check and stale:
        sys.exit("website/ is out of date (run python3 site/build.py): " + ", ".join(stale))
    print(("Checked" if check else "Wrote") + f" website/ ({len(LANGUAGES)} languages)"
          + ("" if check else f", {len(stale)} files changed"))


if __name__ == "__main__":
    main()
