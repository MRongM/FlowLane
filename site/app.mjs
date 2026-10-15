export const LANGUAGES = Object.freeze(["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt-BR", "ru", "ar"]);

export function resolveLanguage(value) {
  if (typeof value !== "string") return "en";
  if (LANGUAGES.includes(value)) return value;
  const lower = value.toLowerCase().replaceAll("_", "-");
  if (lower.startsWith("zh")) return /(?:hant|tw|hk|mo)/.test(lower) ? "zh-Hant" : "zh-Hans";
  if (lower === "pt" || lower.startsWith("pt-")) return "pt-BR";
  return LANGUAGES.find(language => language.toLowerCase() === lower || language === lower.split("-")[0]) || "en";
}

export function applyLanguage(requested, catalogs, document) {
  const language = resolveLanguage(requested);
  const catalog = catalogs[language] || catalogs.en;
  for (const element of document.querySelectorAll("[data-i18n]")) {
    const key = element.dataset.i18n;
    const value = catalog[key] ?? catalogs.en[key];
    if (typeof value === "string") {
      if (language === "ar" && typeof document.createDocumentFragment === "function") {
        // Isolate Latin protocol names and versions without injecting HTML or
        // changing the translated text. In RTL, "macOS 14+" keeps its + suffix.
        const fragment = document.createDocumentFragment();
        const tokens = /macOS 14\+|HTTP CONNECT|Apple silicon|GPL-3\.0-or-later|DoH \/ DoT|SOCKS5|Keychain|FlowLane|sing-box|IPv4|IPv6|macOS|ad-hoc|QUIC|TCP|UDP|TUN|DNS|XPC|DoH|DoT|\.app|1\.14\.3/g;
        let position = 0;
        for (const match of value.matchAll(tokens)) {
          fragment.append(document.createTextNode(value.slice(position, match.index)));
          const isolated = document.createElement("bdi");
          isolated.dir = "ltr";
          isolated.textContent = match[0];
          fragment.append(isolated);
          position = match.index + match[0].length;
        }
        fragment.append(document.createTextNode(value.slice(position)));
        element.replaceChildren(fragment);
      } else element.textContent = value;
    }
  }
  for (const element of document.querySelectorAll("[data-i18n-aria]")) {
    const key = element.dataset.i18nAria;
    element.setAttribute("aria-label", catalog[key] ?? catalogs.en[key]);
  }
  document.documentElement.lang = language;
  document.documentElement.dir = language === "ar" ? "rtl" : "ltr";
  document.title = `${catalog.brand || "FlowLane"} — ${(catalog.heroTitle || catalogs.en.heroTitle).replaceAll("\n", " ")}`;
  const description = document.querySelector('meta[name="description"]');
  if (description) description.setAttribute("content", catalog.heroBody || catalogs.en.heroBody);
  const select = document.querySelector("#language");
  if (select) select.value = language;
  return language;
}

export async function initialize(document, window) {
  const response = await window.fetch(new URL("./locales.json", import.meta.url));
  if (!response.ok) throw new Error("Could not load local language catalogs");
  const catalogs = await response.json();
  let stored;
  try { stored = window.localStorage.getItem("flowlane-language"); } catch { /* Storage can be disabled. */ }
  const parameter = new URL(window.location.href).searchParams.get("lang");
  applyLanguage(parameter || stored || "en", catalogs, document);
  const select = document.querySelector("#language");
  select.disabled = false;
  select.addEventListener("change", () => {
    const language = applyLanguage(select.value, catalogs, document);
    try { window.localStorage.setItem("flowlane-language", language); } catch { /* Translation remains available. */ }
    const url = new URL(window.location.href);
    url.searchParams.set("lang", language);
    window.history.replaceState(null, "", url);
    const announcement = document.querySelector("#language-announcement");
    announcement.textContent = `${catalogs[language].language}: ${select.selectedOptions[0].textContent}`;
  });
}

if (typeof document !== "undefined" && typeof window !== "undefined") {
  initialize(document, window).catch(() => {
    // The complete static English page stays readable without JavaScript/fetch.
    document.documentElement.dataset.languageLoad = "unavailable";
  });
}
