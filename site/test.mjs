import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {LANGUAGES, resolveLanguage, applyLanguage} from "./app.mjs";

const catalogs = JSON.parse(await readFile(new URL("../build/site/locales.json", import.meta.url), "utf8"));
const markup = await readFile(new URL("../build/site/index.html", import.meta.url), "utf8");
const keys = [...markup.matchAll(/data-i18n="([^"]+)"/g)].map(match => match[1]);

function fakeDocument() {
  const nodes = keys.map(key => ({dataset: {i18n: key}, textContent: ""}));
  const image = {dataset: {i18nAlt: "screenshotCaption"}, attributes: {}, setAttribute(name, value) { this.attributes[name] = value; }};
  const select = {value: ""};
  return {nodes, select, image, documentElement: {}, title: "",
    querySelectorAll: selector => selector === "[data-i18n]" ? nodes : selector === "[data-i18n-alt]" ? [image] : [],
    querySelector: selector => selector === "#language" ? select : null};
}

test("all eleven catalogs contain complete, nonempty site translations", () => {
  assert.deepEqual(Object.keys(catalogs).sort(), [...LANGUAGES].sort());
  for (const language of LANGUAGES) {
    assert.deepEqual(Object.keys(catalogs[language]).sort(), Object.keys(catalogs.en).sort());
    for (const key of keys) assert.ok(catalogs[language][key]?.trim(), `${language}: ${key}`);
    assert.match(catalogs[language].scopeUdp, /UDP/);
    assert.match(catalogs[language].scopeDns, /DNS/);
    assert.match(catalogs[language].scopeLicense, /GPL-3\.0-or-later/);
    assert.ok(catalogs[language].acceptanceTitle);
  }
});

test("switching every language updates text, HTML language, direction and selector", () => {
  const document = fakeDocument();
  for (const language of LANGUAGES) {
    assert.equal(applyLanguage(language, catalogs, document), language);
    assert.equal(document.documentElement.lang, language);
    assert.equal(document.documentElement.dir, language === "ar" ? "rtl" : "ltr");
    assert.equal(document.select.value, language);
    assert.equal(document.image.attributes.alt, catalogs[language].screenshotCaption);
    assert.equal(document.nodes.find(node => node.dataset.i18n === "heroTitle").textContent, catalogs[language].heroTitle);
    assert.match(document.title, /FlowLane/);
  }
  assert.equal(applyLanguage("unsupported", catalogs, document), "en");
  assert.equal(document.documentElement.dir, "ltr");
});

test("language fallback handles regional and script variants", () => {
  for (const [requested, expected] of [["zh-TW", "zh-Hant"], ["zh-HK", "zh-Hant"], ["zh-CN", "zh-Hans"], ["pt_BR", "pt-BR"], ["fr-CA", "fr"], ["de-DE", "de"], ["ar-SA", "ar"], ["it-IT", "en"], [null, "en"]]) {
    assert.equal(resolveLanguage(requested), expected);
  }
});

test("missing individual translations use English text safely", () => {
  const document = fakeDocument();
  const incomplete = {...catalogs, fr: {...catalogs.fr, heroBody: undefined}};
  applyLanguage("fr", incomplete, document);
  assert.equal(document.nodes.find(node => node.dataset.i18n === "heroBody").textContent, catalogs.en.heroBody);
});

test("downloads target both architecture assets and no third-party site assets are loaded", () => {
  assert.ok(markup.includes("releases/latest/download/FlowLane-macos-arm64.zip"));
  assert.ok(markup.includes("releases/latest/download/FlowLane-macos-x86_64.zip"));
  assert.equal([...markup.matchAll(/(?:src|href)="(https?:[^\"]+)"/g)].filter(match => !/https:\/\/(?:github\.com|MRongM\.github\.io|gh\.328064\.xyz)\//i.test(match[1])).length, 0);
  assert.ok(markup.includes('<link rel="canonical" href="https://gh.328064.xyz/FlowLane/">'));
  assert.ok(markup.includes('<meta property="og:url" content="https://gh.328064.xyz/FlowLane/">'));
  assert.ok(markup.includes('<meta property="og:image" content="https://gh.328064.xyz/FlowLane/assets/flowlane.png">'));
  assert.ok(!markup.includes("<!-- UI_SCREENSHOT -->"));
  for (const key of ["scopeHelpers", "scopeUdp", "scopeDns", "scopeIpv6", "scopeLifecycle", "scopeLicense"]) {
    assert.ok(markup.includes(catalogs.en[key].replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")), `static English ${key}`);
  }
});
