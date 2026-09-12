const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const source = fs.readFileSync(path.join(__dirname, "rename.js"), "utf8");

function load(args = {}) {
  const context = { $arguments: args, console: { log() {} } };
  vm.createContext(context);
  vm.runInContext(source + "\nthis.runRename = operator; this.regions = REGIONS;", context);
  return context;
}

function run(args, names, sourceName = "MESL") {
  const context = load(args);
  const proxies = names.map((name) => ({
    name,
    server: "example.com",
    port: 443,
    type: "trojan",
    _subDisplayName: sourceName,
  }));
  return JSON.parse(JSON.stringify(context.runRename(proxies, "ClashMeta", {})));
}

function runWithContext(args, names, sourceName = "MESL") {
  const context = load(args);
  const proxies = names.map((name) => ({ name, server: "example.com", port: 443, type: "trojan" }));
  return JSON.parse(JSON.stringify(context.runRename(proxies, "ClashMeta", {
    source: { [sourceName]: { name: sourceName } },
  })));
}

assert.deepStrictEqual(
  run({}, [
    "trojan HK 香港-Go-FXT",
    "trojan JP 日本-IEPL-JinX",
    "vmess HK 香港-实验线路 BGP",
    "HK 广东-香港 DP V",
  ]).map(({ name }) => name),
  [
    "🇭🇰 「MESL」 香港 FXT",
    "🇯🇵 「MESL」 日本 JinX",
    "🇭🇰 「MESL」 香港 BGP",
    "🇭🇰 「MESL」 香港 DP V",
  ],
);

assert.deepStrictEqual(
  run({ out: "en", airport: false }, ["香港 PCCW 01"]).map(({ name }) => name),
  ["🇭🇰 Hong Kong PCCW"],
);
assert.deepStrictEqual(
  run({ out: "code", flag: false }, ["日本 JinX 01"]).map(({ name }) => name),
  ["「MESL」 JP JinX"],
);
assert.deepStrictEqual(
  run({ provider: "off" }, ["HK Go-FXT 01"]).map(({ name }) => name),
  ["🇭🇰 「MESL」 香港"],
);
assert.deepStrictEqual(
  run({ format: "full", number: "off", airport: false }, ["HK BGP PCCW 01"]).map(({ name }) => name),
  ["🇭🇰 香港 BGP PCCW 01"],
);
assert.strictEqual(run({}, ["剩余流量 100 GB"]).length, 0);
assert.strictEqual(run({ unknown: "drop" }, ["Private Special 01"]).length, 0);

assert.deepStrictEqual(
  runWithContext({}, ["HK Go-FXT"]).map(({ name }) => name),
  ["🇭🇰 「MESL」 香港 FXT"],
);
assert.deepStrictEqual(
  run({}, ["HK Muse 01", "HK User 02", "HK Abuse 03"]).map(({ name }) => name),
  ["🇭🇰 「MESL」 香港 Muse", "🇭🇰 「MESL」 香港 User", "🇭🇰 「MESL」 香港 Abuse"],
);
assert.deepStrictEqual(
  run({}, ["港湾 BGP PCCW 01", "深港 BGP PCCW 01"]).map(({ name }) => name),
  ["「MESL」 港湾 BGP PCCW", "🇭🇰 「MESL」 香港 PCCW"],
);
assert.deepStrictEqual(
  run({ format: "full", airport: false }, ["HK China Telecom 163", "HK PCCW 04", "HK FXT #1"]).map(({ name }) => name),
  ["🇭🇰 香港 China Telecom 163", "🇭🇰 香港 PCCW", "🇭🇰 香港 FXT"],
);
assert.deepStrictEqual(
  run({ number: "off" }, ["HK FXT 01"]).map(({ name }) => name),
  ["🇭🇰 「MESL」 香港 FXT 01"],
);
assert.deepStrictEqual(
  run({ number: "region" }, ["HK FXT 163", "香港 PCCW 04"]).map(({ name }) => name),
  ["🇭🇰 「MESL」 香港 FXT 01", "🇭🇰 「MESL」 香港 PCCW 02"],
);
assert.deepStrictEqual(
  run({}, ["HK China Mobile 01", "HK BGP PCCW 02"]).map(({ name }) => name),
  ["🇭🇰 「MESL」 香港 China Mobile", "🇭🇰 「MESL」 香港 PCCW"],
);
assert.strictEqual(run({}, ["TOTAL 100 GB"]).length, 0);
assert.strictEqual(run({ clearkey: "Muse" }, ["HK Muse 01"]).length, 0);

const context = load();
assert.strictEqual(context.regions.length, 190);
for (const region of context.regions) {
  const [{ name }] = run({}, [`${region.en} Provider 01`]);
  assert.strictEqual(name, `${region.flag} 「MESL」 ${region.zh} Provider`, region.code);
}

console.log("rename.js tests passed");
