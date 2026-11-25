import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

// Saturn's theme (saturn-theme.css) is appended to dist/chrome.css behind THEME_MARKER, so the served chrome
// uses SF fonts and Saturn colours. Re-apply to an existing copy with: node scripts/vendor-lavish.mjs --theme <destination>
const THEME_MARKER = "/* saturn-theme */";

function applyTheme(root) {
  const chrome = path.join(root, "dist", "chrome.css");
  const css = fs.readFileSync(chrome, "utf8");
  if (css.includes(THEME_MARKER)) return;
  const theme = fs.readFileSync(path.join(root, "saturn-theme.css"), "utf8");
  fs.writeFileSync(chrome, `${css.trimEnd()}\n\n${THEME_MARKER}\n${theme}`);
}

if (process.argv[2] === "--theme") {
  applyTheme(path.resolve(process.argv[3]));
  process.exit(0);
}

const [version, destination, before] = process.argv.slice(2);
if (!version || !destination || !before) {
  console.error("usage: node scripts/vendor-lavish.mjs <version> <destination> <before-date>");
  process.exit(1);
}

const npmRoot = path.join(execFileSync("npm", ["root", "-g"]).toString().trim(), "npm");
const require = createRequire(path.join(npmRoot, "package.json"));
const pacote = require("pacote");
const semver = require("semver");

const options = { before: new Date(before), fullMetadata: true };
const root = path.resolve(destination);
const keep = ["dist", "package.json", "LICENSE", "THIRD-PARTY-NOTICES.md"];
const placed = new Map();
const lock = {};

const own = new Set(["saturn-json.mjs", "saturn-theme.css"]);
for (const entry of fs.existsSync(root) ? fs.readdirSync(root) : []) {
  if (!own.has(entry)) fs.rmSync(path.join(root, entry), { recursive: true, force: true });
}
const staging = `${root}.staging`;
fs.rmSync(staging, { recursive: true, force: true });
await pacote.extract(`lavish-axi@${version}`, staging, options);
fs.mkdirSync(root, { recursive: true });
for (const name of keep) {
  if (fs.existsSync(path.join(staging, name))) fs.cpSync(path.join(staging, name), path.join(root, name), { recursive: true });
}
fs.rmSync(staging, { recursive: true, force: true });
applyTheme(root);

const top = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
lock["lavish-axi"] = top.version;

function owner(directory, name) {
  let current = directory;
  while (true) {
    const candidate = path.join(current, "node_modules", name);
    if (placed.has(candidate)) return candidate;
    if (current === root) return null;
    current = path.dirname(path.dirname(current));
    if (path.basename(current) === "node_modules") current = path.dirname(current);
  }
}

function slot(directory, name, version) {
  let target = path.join(root, "node_modules", name);
  if (!placed.has(target)) return target;
  if (placed.get(target) === version) return target;
  return path.join(directory, "node_modules", name);
}

const queue = [{ directory: root, deps: top.dependencies || {} }];
while (queue.length) {
  const { directory, deps } = queue.shift();
  for (const [name, range] of Object.entries(deps)) {
    const existing = owner(directory, name);
    if (existing && semver.satisfies(placed.get(existing), range)) continue;
    const manifest = await pacote.manifest(`${name}@${range}`, options);
    const target = slot(directory, name, manifest.version);
    if (placed.has(target)) continue;
    placed.set(target, manifest.version);
    await pacote.extract(`${name}@${manifest.version}`, target, options);
    lock[path.relative(root, target)] = manifest.version;
    queue.push({ directory: target, deps: manifest.dependencies || {} });
  }
}

const sorted = Object.fromEntries(Object.entries(lock).sort(([a], [b]) => a.localeCompare(b)));
fs.writeFileSync(path.join(root, "vendor-lock.json"), JSON.stringify({ before, packages: sorted }, null, 2) + "\n");
console.log(`vendored ${Object.keys(sorted).length} packages into ${root}`);
