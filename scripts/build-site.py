#!/usr/bin/env python3
"""Build the dependency-free public site from explicitly allowlisted inputs."""

from __future__ import annotations

import argparse
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import shutil
import struct
import tempfile
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "site"
OUTPUT = ROOT / "build/site"
LANGUAGES = ("en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt-BR", "ru", "ar")
APP_KEYS = {
    "brand": "brand.name", "language": "settings.language",
    "scopeIntro": "apps.description", "featureProxyBody": "profiles.intro",
    "step1Title": "apps.add", "step1Body": "apps.empty_body",
    "step2Title": "profiles.add", "step2Body": "profiles.empty_body",
    "step3Title": "network.start", "step3Body": "apps.authorization",
    "scopeTcp": "help.tcp", "scopeHelpers": "help.helpers", "scopeUdp": "help.udp",
    "scopeDns": "help.dns", "scopeIpv6": "help.ipv6",
    "scopeLifecycle": "help.lifecycle", "scopeLicense": "help.license",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def source_file(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), f"Missing or symbolic-link input: {path.relative_to(ROOT)}")
    for parent in path.parents:
        if parent == ROOT:
            break
        require(not parent.is_symlink(), "Symbolic-link input directory refused")
    require(path.stat().st_size < 20_000_000, "Input exceeds the static asset size limit")
    return path


def strings_catalog(path):
    text = source_file(path).read_text(encoding="utf-8")
    records = re.findall(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;', text)
    result = {}
    for raw_key, raw_value in records:
        key, value = json.loads(raw_key), json.loads(raw_value)
        require(key not in result, "Duplicate app catalog key")
        result[key] = value
    return result


def catalogs():
    copy = json.loads(source_file(SOURCE / "copy.json").read_text(encoding="utf-8"))
    require(set(copy) == set(LANGUAGES), "The site must contain all eleven languages")
    keys = set(copy["en"])
    result = {}
    for language in LANGUAGES:
        values = copy[language]
        require(set(values) == keys and all(isinstance(value, str) and value.strip() for value in values.values()), f"Incomplete site copy: {language}")
        app = strings_catalog(ROOT / "Sources/AppProxyKit/Resources" / (language + ".lproj") / "Interface.strings")
        result[language] = {**values, **{key: app[source] for key, source in APP_KEYS.items()}}
        result[language]["diagramAria"] = f'{values["selectedApp"]}: SOCKS5 / HTTP CONNECT. {app["apps.description"]}'
    return result


def translated_html(source, english):
    pattern = r'(<(?P<tag>[a-z0-9]+)\b[^>]*\bdata-i18n="(?P<key>[^"]+)"[^>]*>).*?(</(?P=tag)>)'

    def replace(match):
        key = match["key"]
        require(key in english, f"Missing static English text: {key}")
        return match[1] + html.escape(english[key], quote=False) + match[4]

    source = re.sub(pattern, replace, source, flags=re.DOTALL)
    for match in list(re.finditer(r'<[a-z][^>]*\bdata-i18n-aria="([^"]+)"[^>]*>', source)):
        tag = match[0]
        key = match[1]
        require(key in english, f"Missing accessible English text: {key}")
        changed = re.sub(r'aria-label="[^"]*"', 'aria-label="' + html.escape(english[key], quote=True) + '"', tag)
        source = source.replace(tag, changed)
    return source


class PageReferences(HTMLParser):
    def __init__(self):
        super().__init__()
        self.references = []
        self.ids = []
        self.translations = set()
        self.language_options = []

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        require(not any(key.lower().startswith("on") for key in attributes), "Inline event handlers are not permitted")
        require(not (tag == "script" and "src" not in attributes), "Inline scripts are not permitted")
        if "id" in attributes:
            self.ids.append(attributes["id"])
        for key in ("href", "src"):
            if key in attributes:
                self.references.append(attributes[key])
        for key in ("data-i18n", "data-i18n-aria"):
            if key in attributes:
                self.translations.add(attributes[key])
        if tag == "option":
            self.language_options.append(attributes.get("value"))


def validate(directory):
    require(directory.is_dir() and not directory.is_symlink(), "Static output directory is missing or symbolic")
    parsed = PageReferences()
    parsed.feed((directory / "index.html").read_text(encoding="utf-8"))
    require(len(parsed.ids) == len(set(parsed.ids)), "Duplicate HTML IDs")
    require(tuple(parsed.language_options) == LANGUAGES, "Language selector differs from the app language list")
    values = json.loads((directory / "locales.json").read_text(encoding="utf-8"))
    require(set(values) == set(LANGUAGES), "Built language catalogs differ")
    for language, catalog in values.items():
        require(parsed.translations <= set(catalog), f"Untranslated page elements: {language}")
    for reference in parsed.references:
        parts = urlsplit(reference)
        if parts.scheme or parts.netloc:
            require(parts.scheme == "https" and parts.netloc in {"github.com", "MRongM.github.io"}, "Unexpected external dependency or unsafe link")
            continue
        if parts.path:
            require(not parts.path.startswith("/"), "Root-relative assets break project Pages URLs")
            destination = (directory / unquote(parts.path)).resolve()
            require(destination.is_relative_to(directory.resolve()) and destination.is_file(), f"Broken or escaping relative reference: {reference}")
        elif parts.fragment:
            require(parts.fragment in parsed.ids, f"Broken section link: {reference}")
    for path in directory.rglob("*"):
        require(not path.is_symlink(), "Symbolic links are not deployable")
        require(path.is_file() or path.is_dir(), "Special files are not deployable")
        if path.is_file():
            require(path.stat().st_nlink == 1, "Hard links are not deployable")
    require((directory / ".nojekyll").is_file(), "Missing .nojekyll")
    return {"passed": True, "languages": len(LANGUAGES), "translation_keys": len(values["en"]), "files": sum(path.is_file() for path in directory.rglob("*")), "screenshot_included": (directory / "assets/flowlane-ui-en.png").is_file()}


def copy_png(source, destination):
    source_file(source)
    with source.open("rb") as stream:
        header = stream.read(24)
    require(header[:8] == b"\x89PNG\r\n\x1a\n" and len(header) == 24, "Expected a PNG asset")
    width, height = struct.unpack("!II", header[16:24])
    require(0 < width <= 12000 and 0 < height <= 12000, "Invalid image dimensions")
    shutil.copyfile(source, destination)
    return width, height


def build():
    require(not SOURCE.is_symlink(), "Symbolic-link source directory refused")
    build_root = ROOT / "build"
    require(not build_root.is_symlink() and not OUTPUT.is_symlink(), "Symbolic-link build directory refused")
    build_root.mkdir(exist_ok=True)
    values = catalogs()
    with tempfile.TemporaryDirectory(prefix="site-stage-", dir=build_root) as temporary:
        stage = Path(temporary)
        (stage / "assets").mkdir()
        copy_png(ROOT / "Resources/Brand/FlowLane.png", stage / "assets/flowlane.png")
        markup = source_file(SOURCE / "index.html").read_text(encoding="utf-8")
        screenshot = SOURCE / "assets/flowlane-ui-en.png"
        figure = ""
        if screenshot.exists():
            width, height = copy_png(screenshot, stage / "assets/flowlane-ui-en.png")
            figure = f'<section class="app-preview wrap"><figure><img src="./assets/flowlane-ui-en.png" alt="FlowLane native macOS app, English interface" loading="lazy" width="{width}" height="{height}"><figcaption data-i18n="screenshotCaption"></figcaption></figure></section>'
        require(markup.count("<!-- UI_SCREENSHOT -->") == 1, "Expected exactly one screenshot insertion point")
        markup = translated_html(markup.replace("<!-- UI_SCREENSHOT -->", figure), values["en"])
        (stage / "index.html").write_text(markup, encoding="utf-8")
        for name in ("style.css", "app.mjs"):
            shutil.copyfile(source_file(SOURCE / name), stage / name)
        (stage / "locales.json").write_text(json.dumps(values, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (stage / ".nojekyll").touch()
        result = validate(stage)
        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        shutil.copytree(stage, OUTPUT, symlinks=False)
    result["output"] = str(OUTPUT.relative_to(ROOT))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate an existing build without changing it")
    arguments = parser.parse_args()
    print(json.dumps(validate(OUTPUT) if arguments.check else build(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
