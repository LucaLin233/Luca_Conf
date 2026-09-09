/* AWS Lightsail 流量信息面板：展示当月流量使用情况与配额占比。 */

const ARGS = parseArgs($argument || "");
const ACCESS_KEY = ARGS.ak || "";
const SECRET_KEY = ARGS.sk || "";
/* 模块参数用逗号分隔参数名，默认值里的多区域改用竖线或分号 */
const REGIONS = String(ARGS.region || "ap-east-1|ap-northeast-1")
  .split(/[,;|]/)
  .map((item) => item.trim())
  .filter(Boolean);
const PANEL_TITLE = "AWS Lightsail";
const PANEL_ICON = ARGS.icon || "cloud";
const ERROR_ICON = "exclamationmark.triangle.fill";
const ERROR_COLOR = "#EF4444";
const iconColorRaw = String(ARGS["icon-color"] || "").trim();
const PANEL_ICON_COLOR = /^[0-9a-fA-F]{6}$/.test(iconColorRaw) ? `#${iconColorRaw}` : "#FF9900";
const notifyRaw = Number(ARGS["notify-percent"]);
const NOTIFY_PERCENT = Number.isFinite(notifyRaw) ? Math.max(0, Math.min(100, notifyRaw)) : 80;
const IP_MODE = normalizeIpMode(ARGS["ip-mode"]);

const SERVICE = "lightsail";
const TARGET_PREFIX = "Lightsail_20161128.";
const BYTES_PER_GB = 1024 ** 3;
const BUNDLE_CACHE_KEY = "lightsail_bundle_cache";
const BUNDLE_CACHE_TTL = 24 * 3600 * 1000;
const GEO_CACHE_TTL = 24 * 3600 * 1000;

/* Lightsail 区域中文名（未收录的区域回退显示区域代码） */
const REGION_NAMES = {
  "us-east-1": "弗吉尼亚北部",
  "us-east-2": "俄亥俄",
  "us-west-1": "加州北部",
  "us-west-2": "俄勒冈",
  "ca-central-1": "加拿大中部",
  "sa-east-1": "圣保罗",
  "eu-west-1": "爱尔兰",
  "eu-west-2": "伦敦",
  "eu-west-3": "巴黎",
  "eu-central-1": "法兰克福",
  "eu-north-1": "斯德哥尔摩",
  "eu-south-2": "西班牙",
  "ap-east-1": "香港",
  "ap-northeast-1": "东京",
  "ap-northeast-2": "首尔",
  "ap-northeast-3": "大阪",
  "ap-south-1": "孟买",
  "ap-southeast-1": "新加坡",
  "ap-southeast-2": "悉尼",
  "ap-southeast-3": "雅加达",
  "ap-southeast-5": "吉隆坡",
};

function regionLabel(region) {
  const name = REGION_NAMES[region];
  return name ? `${name} ${region}` : region;
}

function safeDecode(value) {
  try { return decodeURIComponent(value); } catch (_) { return value; }
}

function parseArgs(input) {
  const output = {};
  for (const pair of input.split("&")) {
    const index = pair.indexOf("=");
    if (index < 0) continue;
    const key = safeDecode(pair.slice(0, index)).trim();
    if (key) output[key] = safeDecode(pair.slice(index + 1)).trim();
  }
  return output;
}

function normalizeIpMode(raw) {
  const mode = String(raw || "mask").trim().toLowerCase();
  return ["full", "mask", "hide"].includes(mode) ? mode : "mask";
}

function maskIp(ip) {
  const parts = String(ip).split(".");
  return parts.length === 4 ? `${parts[0]}.${parts[1]}.*.*` : ip;
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return "N/A";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  return `${value.toFixed(value >= 100 ? 0 : 2)} ${units[index]}`;
}

function httpGet(url, headers) {
  return new Promise((resolve, reject) => {
    $httpClient.get({ url, headers, timeout: 10000 }, (error, response, data) => {
      if (error) return reject(new Error(error));
      resolve({ status: response.status, body: data });
    });
  });
}

function httpPost(url, headers, body) {
  return new Promise((resolve, reject) => {
    $httpClient.post({ url, headers, body, timeout: 15000 }, (error, response, data) => {
      if (error) return reject(new Error(error));
      resolve({ status: response.status, body: data || "" });
    });
  });
}

function finish(content, icon = PANEL_ICON, iconColor = PANEL_ICON_COLOR) {
  $done({ title: PANEL_TITLE, content, icon, "icon-color": iconColor });
}

function fail(message) {
  finish(`❌ ${message}`, ERROR_ICON, ERROR_COLOR);
}

/* ===== SigV4 签名：纯 JS 实现 SHA-256 / HMAC-SHA256，无外部依赖 ===== */

const SHA_K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const rotr = (value, bits) => ((value >>> bits) | (value << (32 - bits))) >>> 0;

function utf8(str) {
  if (typeof str !== "string") return str instanceof Uint8Array ? str : Uint8Array.from(str);
  const bytes = [];
  for (let i = 0; i < str.length; i++) {
    let code = str.codePointAt(i);
    if (code > 0xffff) i++;
    if (code < 0x80) bytes.push(code);
    else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 63));
    else if (code < 0x10000) bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
    else bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
  }
  return Uint8Array.from(bytes);
}

function concatBytes(left, right) {
  const merged = new Uint8Array(left.length + right.length);
  merged.set(left);
  merged.set(right, left.length);
  return merged;
}

function toHex(bytes) {
  return Array.from(bytes).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function sha256Bytes(input) {
  const state = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const length = input.length;
  const padded = new Uint8Array((((length + 9) >> 6) + 1) << 6);
  padded.set(input);
  padded[length] = 0x80;
  const bitLength = length * 8;
  padded[padded.length - 8] = Math.floor(bitLength / 0x100000000) & 0xff;
  padded[padded.length - 4] = (bitLength >>> 24) & 0xff;
  padded[padded.length - 3] = (bitLength >>> 16) & 0xff;
  padded[padded.length - 2] = (bitLength >>> 8) & 0xff;
  padded[padded.length - 1] = bitLength & 0xff;

  const view = new DataView(padded.buffer);
  const words = new Uint32Array(64);
  for (let offset = 0; offset < padded.length; offset += 64) {
    for (let t = 0; t < 16; t++) words[t] = view.getUint32(offset + t * 4);
    for (let t = 16; t < 64; t++) {
      const s0 = rotr(words[t - 15], 7) ^ rotr(words[t - 15], 18) ^ (words[t - 15] >>> 3);
      const s1 = rotr(words[t - 2], 17) ^ rotr(words[t - 2], 19) ^ (words[t - 2] >>> 10);
      words[t] = (words[t - 16] + s0 + words[t - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = state;
    for (let t = 0; t < 64; t++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + S1 + ch + SHA_K[t] + words[t]) >>> 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) >>> 0;
      h = g; g = f; f = e; e = (d + temp1) >>> 0;
      d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
    }
    const round = [a, b, c, d, e, f, g, h];
    for (let i = 0; i < 8; i++) state[i] = (state[i] + round[i]) >>> 0;
  }

  const output = new Uint8Array(32);
  const outputView = new DataView(output.buffer);
  state.forEach((value, index) => outputView.setUint32(index * 4, value));
  return output;
}

function sha256Hex(input) {
  return toHex(sha256Bytes(utf8(input)));
}

function hmacSha256(key, message) {
  let normalized = utf8(key);
  if (normalized.length > 64) normalized = sha256Bytes(normalized);
  const block = new Uint8Array(64);
  block.set(normalized);
  const inner = new Uint8Array(64);
  const outer = new Uint8Array(64);
  for (let i = 0; i < 64; i++) {
    inner[i] = block[i] ^ 0x36;
    outer[i] = block[i] ^ 0x5c;
  }
  return sha256Bytes(concatBytes(outer, sha256Bytes(concatBytes(inner, utf8(message)))));
}

function amzDateNow() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "");
}

function buildAuthorization(method, host, target, body, region, accessKey, secretKey, amzDate) {
  const dateStamp = amzDate.slice(0, 8);
  const canonicalHeaders =
    "content-type:application/x-amz-json-1.1\n" +
    `host:${host}\n` +
    `x-amz-date:${amzDate}\n` +
    `x-amz-target:${target}\n`;
  const signedHeaders = "content-type;host;x-amz-date;x-amz-target";
  const canonicalRequest = [
    method,
    "/",
    "",
    canonicalHeaders,
    signedHeaders,
    sha256Hex(body),
  ].join("\n");
  const scope = `${dateStamp}/${region}/${SERVICE}/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    scope,
    sha256Hex(canonicalRequest),
  ].join("\n");
  const signingKey = hmacSha256(
    hmacSha256(hmacSha256(hmacSha256(utf8(`AWS4${secretKey}`), dateStamp), region), SERVICE),
    "aws4_request"
  );
  const signature = toHex(hmacSha256(signingKey, stringToSign));
  return `AWS4-HMAC-SHA256 Credential=${accessKey}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
}

/* ===== Lightsail API 调用 ===== */

function lightsail(region, action, params) {
  const host = `lightsail.${region}.amazonaws.com`;
  const target = `${TARGET_PREFIX}${action}`;
  const body = JSON.stringify(params || {});
  const amzDate = amzDateNow();
  const authorization = buildAuthorization("POST", host, target, body, region, ACCESS_KEY, SECRET_KEY, amzDate);
  return httpPost(`https://${host}/`, {
    "Content-Type": "application/x-amz-json-1.1",
    "X-Amz-Date": amzDate,
    "X-Amz-Target": target,
    "Authorization": authorization,
  }, body).then((response) => {
    if (response.status !== 200) {
      let message = `HTTP ${response.status}`;
      try {
        const error = JSON.parse(response.body);
        message = error.__type || message;
        if (error.Message || error.message) message += `：${error.Message || error.message}`;
      } catch (_) {}
      throw new Error(message);
    }
    return JSON.parse(response.body);
  });
}

function monthStartEpoch() {
  const now = new Date();
  return Math.floor(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1) / 1000);
}

/* 今日按北京时间日切 */
function todayStartEpoch() {
  const now = new Date();
  const beijing = new Date(now.getTime() + 8 * 3600 * 1000);
  const dayStart = Date.UTC(beijing.getUTCFullYear(), beijing.getUTCMonth(), beijing.getUTCDate());
  return Math.floor((dayStart - 8 * 3600 * 1000) / 1000);
}

/* period 不能大于查询窗口，月初窗口不足一天时按窗口收缩 */
function metricPeriod(startEpoch, endEpoch) {
  const window = endEpoch - startEpoch;
  if (window >= 86400) return 86400;
  return Math.max(60, Math.floor(window / 60) * 60);
}

function getInstances(region) {
  return lightsail(region, "GetInstances", {}).then((response) => response.instances || []);
}

function getMetricSum(region, instanceName, metricName, startEpoch) {
  const endEpoch = Math.floor(Date.now() / 1000);
  return lightsail(region, "GetInstanceMetricData", {
    instanceName,
    metricName,
    period: metricPeriod(startEpoch, endEpoch),
    startTime: startEpoch,
    endTime: endEpoch,
    unit: "Bytes",
    statistics: ["Sum"],
  }).then((response) => (response.metricData || []).reduce((total, point) => total + (point.sum || 0), 0));
}

function readCache(key) {
  try { return JSON.parse($persistentStore.read(key) || "null"); } catch (_) { return null; }
}

function getBundleMap(region) {
  const cached = readCache(BUNDLE_CACHE_KEY);
  if (cached && Date.now() - cached.ts < BUNDLE_CACHE_TTL) return Promise.resolve(cached.map);

  return lightsail(region, "GetBundles", { includeInactive: true }).then((response) => {
    const map = {};
    (response.bundles || []).forEach((bundle) => {
      map[bundle.bundleId] = bundle.transferPerMonthInGb || 0;
    });
    try { $persistentStore.write(JSON.stringify({ ts: Date.now(), map }), BUNDLE_CACHE_KEY); } catch (_) {}
    return map;
  });
}

/* ===== 流量采集与分组 ===== */

function ownQuotaGb(instance) {
  const transfer = (instance.networking || {}).monthlyTransfer || {};
  const allocated = Number(transfer.gbPerMonthAllocated);
  return Number.isFinite(allocated) && allocated > 0 ? allocated : 0;
}

function buildGroups(entries, bundleMap) {
  const groups = new Map();
  entries.forEach((entry) => {
    const { region, instance } = entry;
    const key = `${region} · ${instance.bundleId}`;
    if (!groups.has(key)) {
      groups.set(key, {
        region,
        bundleId: instance.bundleId,
        quotaBytes: 0,
        inBytes: 0,
        outBytes: 0,
        todayBytes: 0,
        instances: [],
      });
    }
    const group = groups.get(key);
    const quotaGb = ownQuotaGb(instance) || Number(bundleMap[instance.bundleId]) || 0;
    group.quotaBytes += quotaGb * BYTES_PER_GB;
    group.inBytes += entry.inBytes;
    group.outBytes += entry.outBytes;
    group.todayBytes += entry.todayBytes || 0;
    group.instances.push({
      name: instance.name,
      ip: String(instance.publicIpAddress || "").trim(),
      geo: null,
      usedBytes: entry.inBytes + entry.outBytes,
    });
  });

  return Array.from(groups.values()).map((group) => {
    group.usedBytes = group.inBytes + group.outBytes;
    group.percent = group.quotaBytes > 0 ? (group.usedBytes / group.quotaBytes) * 100 : 0;
    return group;
  });
}

async function collectGroups(withToday) {
  const entries = [];
  for (const region of REGIONS) {
    const instances = await getInstances(region);
    instances.forEach((instance) => entries.push({ region, instance }));
  }
  if (!entries.length) return [];

  let bundleMap = {};
  if (entries.some(({ instance }) => !ownQuotaGb(instance))) {
    try { bundleMap = await getBundleMap(REGIONS[0]); } catch (_) { bundleMap = {}; }
  }

  const monthStart = monthStartEpoch();
  const todayStart = todayStartEpoch();
  await Promise.all(entries.map(async (entry) => {
    const [inBytes, outBytes] = await Promise.all([
      getMetricSum(entry.region, entry.instance.name, "NetworkIn", monthStart),
      getMetricSum(entry.region, entry.instance.name, "NetworkOut", monthStart),
    ]);
    entry.inBytes = inBytes;
    entry.outBytes = outBytes;
    if (!withToday) return;
    try {
      const [todayIn, todayOut] = await Promise.all([
        getMetricSum(entry.region, entry.instance.name, "NetworkIn", todayStart),
        getMetricSum(entry.region, entry.instance.name, "NetworkOut", todayStart),
      ]);
      entry.todayBytes = todayIn + todayOut;
    } catch (_) {
      entry.todayBytes = 0;
    }
  }));

  return buildGroups(entries, bundleMap);
}

/* ===== 面板渲染与提醒 ===== */

function renderPanel(groups) {
  if (!groups.length) return "未找到 Lightsail 实例";

  const lines = [];
  groups.forEach((group, index) => {
    if (index > 0) lines.push("");
    const countSuffix = group.instances.length > 1 ? `（${group.instances.length} 个实例）` : "";
    lines.push(`配额组：${regionLabel(group.region)} · ${group.bundleId}${countSuffix}`);
    const quotaText = group.quotaBytes > 0 ? formatBytes(group.quotaBytes) : "未知";
    const percentText = group.quotaBytes > 0 ? `${group.percent.toFixed(2)}%` : "--";
    lines.push(`流量情况：${formatBytes(group.usedBytes)} / ${quotaText}（${percentText}）`);
    lines.push(`入站流量：${formatBytes(group.inBytes)}`);
    lines.push(`出站流量：${formatBytes(group.outBytes)}`);

    if (group.instances.length === 1) {
      const instance = group.instances[0];
      if (instance.ip && IP_MODE !== "hide") {
        lines.push(`公网 IP：${IP_MODE === "mask" ? maskIp(instance.ip) : instance.ip}`);
      }
      if (instance.geo) lines.push(`地区：${instance.geo}`);
      return;
    }

    group.instances.forEach((instance, position) => {
      const branch = position === group.instances.length - 1 ? "└" : "├";
      const parts = [instance.name, formatBytes(instance.usedBytes)];
      if (instance.ip && IP_MODE !== "hide") {
        parts.push(IP_MODE === "mask" ? maskIp(instance.ip) : instance.ip);
      }
      if (instance.geo) parts.push(instance.geo);
      lines.push(`    ${branch} ${parts.join(" · ")}`);
    });
  });
  return lines.join("\n");
}

/* ===== 每日日报 ===== */

function dailySubtitle(groups) {
  const used = groups.reduce((total, group) => total + group.usedBytes, 0);
  const quota = groups.reduce((total, group) => total + group.quotaBytes, 0);
  const percent = quota > 0 ? `（${((used / quota) * 100).toFixed(2)}%）` : "";
  return `当月 ${formatBytes(used)} / ${formatBytes(quota)}${percent}`;
}

function renderDaily(groups) {
  if (!groups.length) return "未找到 Lightsail 实例";

  const lines = [];
  groups.forEach((group, index) => {
    if (index > 0) lines.push("");
    const countSuffix = group.instances.length > 1 ? `（${group.instances.length} 个实例）` : "";
    lines.push(`${regionLabel(group.region)} · ${group.bundleId}${countSuffix}`);
    const quotaText = group.quotaBytes > 0 ? formatBytes(group.quotaBytes) : "未知";
    const percentText = group.quotaBytes > 0 ? `${group.percent.toFixed(2)}%` : "--";
    lines.push(`当月：${formatBytes(group.usedBytes)} / ${quotaText}（${percentText}）`);
    lines.push(`今日：${formatBytes(group.todayBytes)}`);
  });
  return lines.join("\n");
}

function composeRegion(country, regionName, city) {
  const parts = [];
  if (country) parts.push(country);
  if (regionName && regionName !== country && !parts.includes(regionName)) parts.push(regionName);
  if (city && !parts.includes(city)) parts.push(city);
  return parts.join(" ") || null;
}

/* zxinc 返回「国家–省州–城市」，取前两段并统一为空格分隔 */
function cleanGeo(text) {
  const parts = String(text || "")
    .split(/[–—]|-(?=\S)/)
    .map((item) => item.trim())
    .filter(Boolean);
  return parts.slice(0, 2).join(" ") || null;
}

async function getGeo(ip) {
  const key = `lightsail_geo_${ip}`;
  const cached = readCache(key);
  if (cached && Date.now() - cached.ts < GEO_CACHE_TTL) return cached.region;

  let region = null;

  /* 主接口: zxinc（中文，对 AWS 机房 IP 较准） */
  try {
    const response = await httpGet(
      `https://ip.zxinc.org/api.php?type=json&ip=${encodeURIComponent(ip)}`,
      { Accept: "application/json" }
    );
    if (response.status === 200) {
      const geo = JSON.parse(response.body);
      if (geo && geo.code === 0 && geo.data) region = cleanGeo(geo.data.country);
    }
  } catch (_) {}

  /* 备接口: ip-api.com 中文（国家/城市中文，州省可能为英文） */
  if (!region) {
    try {
      const response = await httpGet(
        `http://ip-api.com/json/${encodeURIComponent(ip)}?lang=zh-CN&fields=status,country,regionName,city`,
        { Accept: "application/json" }
      );
      if (response.status === 200) {
        const geo = JSON.parse(response.body);
        if (geo && geo.status === "success") region = composeRegion(geo.country, geo.regionName, geo.city);
      }
    } catch (_) {}
  }

  /* 末接口: ipwho.is（英文兜底） */
  if (!region) {
    try {
      const response = await httpGet(`https://ipwho.is/${encodeURIComponent(ip)}`, { Accept: "application/json" });
      if (response.status === 200) {
        const geo = JSON.parse(response.body);
        if (geo && geo.success) region = composeRegion(geo.country, geo.region, geo.city);
      }
    } catch (_) {}
  }

  try { $persistentStore.write(JSON.stringify({ region, ts: Date.now() }), key); } catch (_) {}
  return region;
}

async function fillGeo(groups) {
  await Promise.all(groups.map((group) => Promise.all(group.instances.map(async (instance) => {
    if (!instance.ip) return;
    try { instance.geo = await getGeo(instance.ip); } catch (_) { instance.geo = null; }
  }))));
}

function notifyOveruse(groups) {
  if (NOTIFY_PERCENT === 0) return;
  const today = new Date().toISOString().slice(0, 10);
  groups.forEach((group) => {
    if (group.percent < NOTIFY_PERCENT) return;
    const key = `lightsail_notice_${group.region}_${group.bundleId}_${today}`;
    try {
      if ($persistentStore.read(key)) return;
      $notification.post(
        "Lightsail 流量提醒",
        `${group.region} · ${group.bundleId} 已用 ${group.percent.toFixed(2)}%`,
        `流量情况：${formatBytes(group.usedBytes)} / ${formatBytes(group.quotaBytes)}`
      );
      $persistentStore.write("1", key);
    } catch (_) {}
  });
}

(async () => {
  const mode = String(ARGS.mode || "panel").trim().toLowerCase();
  const isDaily = mode === "daily";
  try {
    if (!ACCESS_KEY || !SECRET_KEY) {
      if (isDaily) return $done(); // 未配置密钥时日报静默跳过，避免每日骚扰
      return fail("缺少 ak / sk 参数");
    }
    if (isDaily && String(ARGS["daily-notify"] || "true").trim().toLowerCase() === "false") {
      return $done();
    }

    const groups = await collectGroups(isDaily);

    if (isDaily) {
      $notification.post("AWS Lightsail 流量日报", dailySubtitle(groups), renderDaily(groups));
      return $done();
    }

    if (IP_MODE !== "hide") await fillGeo(groups);
    notifyOveruse(groups);
    finish(renderPanel(groups));
  } catch (error) {
    const message = String((error && error.message) || error);
    if (isDaily) {
      $notification.post("AWS Lightsail 流量日报", "查询失败", message);
      return $done();
    }
    fail(message);
  }
})();
