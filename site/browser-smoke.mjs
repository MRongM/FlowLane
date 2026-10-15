// Optional local browser QA: Node 22+ and an installed Chrome. No npm packages.
import assert from "node:assert/strict";
import {createServer} from "node:http";
import {spawn} from "node:child_process";
import {mkdtemp, readFile, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {dirname, extname, join, resolve, sep} from "node:path";
import {fileURLToPath} from "node:url";
import {setTimeout as delay} from "node:timers/promises";
import {LANGUAGES} from "./app.mjs";

const repository = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const output = join(repository, "build/site");
const catalogs = JSON.parse(await readFile(join(output, "locales.json"), "utf8"));
const browserPath = process.argv[2] || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = await mkdtemp(join(tmpdir(), "flowlane-site-browser-"));
const types = {".html": "text/html; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".json": "application/json; charset=utf-8", ".png": "image/png"};
const server = createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    const file = resolve(output, "." + (pathname === "/" ? "/index.html" : pathname));
    if (!file.startsWith(output + sep)) throw new Error("Outside static output");
    response.writeHead(200, {"Content-Type": types[extname(file)] || "application/octet-stream"});
    response.end(await readFile(file));
  } catch {
    response.writeHead(404);
    response.end("Not found");
  }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
let browser;
let socket;
const pending = new Map();
const externalRequests = [];
let sequence = 0;

function command(method, params = {}) {
  const id = ++sequence;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timed out: ${method}`)); }, 10000);
    pending.set(id, {resolve, reject, timeout});
    socket.send(JSON.stringify({id, method, params}));
  });
}

async function evaluate(expression) {
  const value = await command("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true});
  assert.ok(!value.exceptionDetails, "Browser evaluation failed");
  return value.result.value;
}

try {
  browser = spawn(browserPath, ["--headless=new", "--disable-gpu", "--disable-background-networking", "--disable-component-update", "--disable-default-apps", "--disable-extensions", "--disable-sync", "--no-first-run", "--no-default-browser-check", "--metrics-recording-only", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank"], {stdio: "ignore"});
  let spawnError;
  browser.on("error", error => { spawnError = error; });
  let port;
  const deadline = Date.now() + 10000;
  while (!port && Date.now() < deadline) {
    if (spawnError) throw spawnError;
    try { port = Number((await readFile(join(profile, "DevToolsActivePort"), "utf8")).split("\n")[0]); } catch { await delay(50); }
  }
  assert.ok(port, "Chrome did not expose its private debugging endpoint");
  const url = `http://127.0.0.1:${server.address().port}/?lang=en`;
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, {method: "PUT"})).json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener("open", resolve, {once: true}); socket.addEventListener("error", reject, {once: true}); });
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    if (message.method === "Network.requestWillBeSent") {
      const requested = message.params.request.url;
      if (/^https?:/.test(requested) && !requested.startsWith(`http://127.0.0.1:${server.address().port}/`)) externalRequests.push(requested);
    }
    if (!message.id || !pending.has(message.id)) return;
    const waiting = pending.get(message.id);
    pending.delete(message.id);
    clearTimeout(waiting.timeout);
    if (message.error) waiting.reject(new Error(message.error.message));
    else waiting.resolve(message.result);
  });
  await command("Page.enable");
  await command("Runtime.enable");
  await command("Network.enable");
  await command("Page.navigate", {url});
  const loadedDeadline = Date.now() + 10000;
  while (!(await evaluate('Boolean(document.querySelector("#language") && !document.querySelector("#language").disabled)'))) {
    assert.ok(Date.now() < loadedDeadline, "Site translations did not load");
    await delay(50);
  }
  const imageState = await evaluate(`(async () => {
    for (const image of document.images) image.loading = "eager";
    await Promise.all([...document.images].map(image => image.decode()));
    const screenshot = document.querySelector(".app-preview img");
    return {loadedImages: document.images.length, screenshotLoaded: Boolean(screenshot && screenshot.naturalWidth > 0)};
  })()`);
  const checks = [];
  for (const [width, height] of [[1440, 1000], [390, 844]]) {
    await command("Emulation.setDeviceMetricsOverride", {width, height, deviceScaleFactor: 1, mobile: width < 500});
    for (const language of LANGUAGES) {
      const state = await evaluate(`(() => {
        const select = document.querySelector("#language");
        select.value = ${JSON.stringify(language)};
        select.dispatchEvent(new Event("change", {bubbles: true}));
        return {lang: document.documentElement.lang, dir: document.documentElement.dir,
          title: document.querySelector("h1").textContent,
          saved: localStorage.getItem("flowlane-language"), query: new URL(location.href).searchParams.get("lang"),
          screenshotAlt: document.querySelector(".app-preview img")?.alt,
          overflow: document.documentElement.scrollWidth > innerWidth + 1,
          brokenImages: [...document.images].some(image => image.complete && image.naturalWidth === 0)};
      })()`);
      assert.equal(state.lang, language);
      assert.equal(state.dir, language === "ar" ? "rtl" : "ltr");
      assert.equal(state.title, catalogs[language].heroTitle);
      assert.equal(state.saved, language);
      assert.equal(state.query, language);
      if (imageState.screenshotLoaded) assert.equal(state.screenshotAlt, catalogs[language].screenshotCaption);
      assert.ok(!state.overflow, `Horizontal overflow: ${language} at ${width}px`);
      assert.ok(!state.brokenImages, `Broken image: ${language}`);
      checks.push(`${language}@${width}`);
      if (language === "en" && width === 1440 || language === "ar" && width === 390) {
        await delay(50);
        const screenshot = await command("Page.captureScreenshot", {format: "png"});
        await writeFile(join(repository, `build/site-preview-${language}-${width}.png`), Buffer.from(screenshot.data, "base64"));
      }
    }
  }
  assert.deepEqual(externalRequests, [], "The site loaded an external dependency");
  console.log(JSON.stringify({passed: true, languageAndViewportChecks: checks.length, checks, rtlVerified: true, selectorPersistenceVerified: true, horizontalOverflow: false, externalSiteDependencies: false, ...imageState}, null, 2));
} finally {
  socket?.close();
  for (const waiting of pending.values()) clearTimeout(waiting.timeout);
  if (browser && browser.exitCode === null) {
    browser.kill("SIGTERM");
    await Promise.race([new Promise(resolve => browser.once("exit", resolve)), delay(2000)]);
    if (browser.exitCode === null) { browser.kill("SIGKILL"); await new Promise(resolve => browser.once("exit", resolve)); }
  }
  await new Promise(resolve => server.close(resolve));
  await rm(profile, {recursive: true, force: true, maxRetries: 5, retryDelay: 200});
}
