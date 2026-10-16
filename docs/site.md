# FlowLane product site

The static product introduction is prepared for
`https://gh.328064.xyz/FlowLane/`, the HTTPS address reported by Pages for the
account's existing custom domain. Preparing these files does not publish the
site, create a Pages project, change repository visibility, or run network routing.

Build and check from the repository root:

```sh
python3 scripts/build-site.py
node --test site/test.mjs
python3 scripts/build-site.py --check
```

Python uses only the standard library. The website is vanilla HTML/CSS/JavaScript,
with system fonts and local assets; it has no npm install, tracking, cookies,
external CDN, signup, or application backend. The language preference is saved
only in the visitor's browser local storage. If storage is blocked, selection
still works. If JavaScript or the language file is unavailable, the generated
HTML contains the complete English content and working download/source links.

## Content and assets

- `site/index.html`, `style.css`, and `app.mjs` define the responsive page and
  language selector. `site/copy.json` contains native site-specific copy for all
  eleven app languages. English is the default and the fallback. `?lang=ar`, for
  example, opens Arabic with RTL layout; the selector updates the URL and saved
  preference. Latin protocol names and version strings are isolated for RTL
  display without inserting translated HTML.
- The build reads the corresponding app `Interface.strings` files for the brand,
  step descriptions, credential storage, and all detailed networking limits.
  Changes to those limits remain shared with the app instead of drifting into
  separate marketing promises. App resource files are not modified by the build.
- `Resources/Brand/FlowLane.png` is copied to the output as
  `assets/flowlane.png`; there is no duplicate logo PNG in the site source.
- A real, sanitized English app screenshot may be supplied at
  `site/assets/flowlane-ui-en.png`. The build includes its figure and translated
  English-interface caption only when that exact file exists. It checks the PNG
  signature and dimensions. The supplied real screenshot is now included, with
  its alt text and caption translated by the language selector. Without it, the
  section is omitted. The hero is
  explicitly labeled as a routing concept, rather than presented as an app
  screenshot.
- The download links use the real repository's latest release assets:
  `FlowLane-macos-arm64.zip` and `FlowLane-macos-x86_64.zip`. Their availability
  depends on the separate release workflow successfully publishing a release.
  The site makes no claim that an asset has already been published or that Intel
  hardware has passed live TUN acceptance.

The page describes macOS 14+, existing SOCKS5/HTTP CONNECT TCP proxies, explicit
administrator approval at network start, eleven interface languages, Keychain,
and local ad-hoc signing without notarization or an Apple Developer account.
Unmatched/unknown traffic goes direct, selected UDP is rejected, and DNS stays
direct. A TUN acceptance pending notice appears beside the hero download actions
and above the detailed limits. It does not claim a leak-prevention guarantee or
verified transparent interception/restoration.

The build writes only ignored `build/site/`, including `.nojekyll`. Inputs are
explicitly allowlisted, symbolic links are refused, and runtime configs, downloaded
cores, private files, build tests, and source-only copy files are not copied to
the public output. Validation checks every relative HTML reference and section
anchor, all translated elements and language options, and deployable regular files
without symbolic/hard links.

## Browser verification

Optional local browser smoke test, using Node 22+ and an installed Chrome:

```sh
node site/browser-smoke.mjs
# On another machine, pass the Chrome executable path as the first argument.
```

It serves only `build/site/` on an ephemeral loopback port and launches a separate
temporary headless profile. It uses native Node WebSocket/CDP support; no browser
packages or downloads are needed. It switches every language through the real
selector at 1440 and 390 CSS pixels, checking text, `lang`, RTL direction,
local-storage preference, URL query, broken images, horizontal overflow, and
external page resource requests. It stops its browser/server and removes its
profile. Preview screenshots remain under ignored `build/`, outside the public
site directory.

Verified locally on 2026-10-15: the Python build/integrity check passed, all five
Node tests passed, and Chrome passed all 22 language/viewport combinations with
the real screenshot loaded, translated alt text, and zero horizontal overflow,
broken images, or external page dependencies. The
desktop English and mobile Arabic previews were visually inspected. These checks
cover the local website, not GitHub hosting, releases, or TUN networking.

## Pages workflow

`.github/workflows/pages.yml` builds on relevant pushes to `main` or manual
dispatch. The build job has `contents: read`, performs the static build and Node
tests, and uploads only `build/site`. The dependent deployment job uses the
`github-pages` environment, with `pages: write` and `id-token: write`. Configure
the repository's Pages source as GitHub Actions before dispatching it. Environment
protection rules, if configured, still apply.

The official action major tags were resolved directly from their GitHub
repositories on 2026-10-15 and pinned to commits:

| Official action | Tag | Commit |
| --- | --- | --- |
| [checkout](https://github.com/actions/checkout) | v4 | `11d5960a326750d5838078e36cf38b85af677262` |
| [configure-pages](https://github.com/actions/configure-pages) | v5 | `983d7736d9b0ae728b81ab479565c72886d7745b` |
| [upload-pages-artifact](https://github.com/actions/upload-pages-artifact) | v4 | `7b1f4a764d45c48632c6b24a0339c27f5614fb0b` |
| [deploy-pages](https://github.com/actions/deploy-pages) | v4 | `d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e` |

Local builds and tests do not change repository visibility or publish a site.
GitHub Pages workflow results establish the deployed revision and hosting status;
the local verification above does not assert that the latest source is deployed.
