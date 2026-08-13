/* Peekabo 流量信息面板：仅展示已用流量、到期日期、剩余时间。 */

const ARGS = parseArgs($argument || "");
const API_TOKEN = ARGS.token;
const SERVER_ID = ARGS.id;
const PANEL_TITLE = "Peekabo Server";
const PANEL_ICON = ARGS.icon || "xserve";
const ERROR_ICON = "exclamationmark.triangle.fill";
const ERROR_COLOR = "#EF4444";
const color = String(ARGS["icon-color"] || "").trim();
const PANEL_ICON_COLOR = /^[0-9a-fA-F]{6}$/.test(color) ? `#${color}` : "#3B82F6";
const notifyDaysRaw = Number(ARGS["notify-days"]);
const NOTIFY_DAYS = Number.isFinite(notifyDaysRaw)
  ? Math.max(0, Math.floor(notifyDaysRaw))
  : 5;

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

function httpGet(url, headers) {
  return new Promise((resolve, reject) => {
    $httpClient.get({ url, headers, timeout: 10000 }, (error, response, data) => {
      if (error) return reject(new Error(error));
      resolve({ status: response.status, body: data });
    });
  });
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

function formatDate(timestamp) {
  const date = new Date(timestamp);
  const pad = (number) => String(number).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function formatRemaining(milliseconds) {
  if (milliseconds <= 0) return "已到期";
  const totalMinutes = Math.floor(milliseconds / 60000);
  const days = Math.floor(totalMinutes / 1440);
  const hours = Math.floor((totalMinutes % 1440) / 60);
  const minutes = totalMinutes % 60;
  if (days > 0) return `${days} 天 ${hours} 小时`;
  if (hours > 0) return `${hours} 小时 ${minutes} 分钟`;
  return `${Math.max(1, minutes)} 分钟`;
}

function notifyExpiring(daysLeft, expireTimestamp) {
  if (NOTIFY_DAYS === 0 || daysLeft > NOTIFY_DAYS) return;
  const today = formatDate(Date.now());
  const expiry = formatDate(expireTimestamp);
  const key = `peekabo_expiry_notice_${SERVER_ID}_${expiry}_${today}`;
  try {
    if ($persistentStore.read(key)) return;
    const remaining = expireTimestamp <= Date.now() ? "已到期" : `剩余 ${daysLeft} 天`;
    $notification.post("Peekabo 到期提醒", remaining, `到期日期：${expiry}`);
    $persistentStore.write("1", key);
  } catch (_) {}
}

function finish(content, icon = PANEL_ICON, iconColor = PANEL_ICON_COLOR) {
  $done({ title: PANEL_TITLE, content, icon, "icon-color": iconColor });
}

function fail(message) {
  finish(`❌ ${message}`, ERROR_ICON, ERROR_COLOR);
}

(async () => {
  try {
    if (!API_TOKEN || !SERVER_ID) return fail("缺少 id / token 参数");

    const response = await httpGet(
      `https://vf-hk.peekabo.io/api/server/${encodeURIComponent(SERVER_ID)}?state=true`,
      { Accept: "application/json", Authorization: `Bearer ${API_TOKEN}` }
    );
    if (response.status !== 200) return fail(`API 请求失败 (HTTP ${response.status})`);

    let json;
    try { json = JSON.parse(response.body); }
    catch (_) { return fail("API 响应解析失败"); }

    const used = Number(json?.data?.state?.network?.primary?.traffic?.tx);
    const expireTimestamp = Date.parse(json?.data?.currentMonthlyPeriod?.end);
    if (!Number.isFinite(used) || used < 0 || !Number.isFinite(expireTimestamp)) {
      return fail("API 返回的流量或到期信息不完整");
    }

    const remainingMs = expireTimestamp - Date.now();
    const daysLeft = Math.max(0, Math.ceil(remainingMs / 86400000));
    notifyExpiring(daysLeft, expireTimestamp);

    finish([
      `已用流量：${formatBytes(used)}`,
      `到期日期：${formatDate(expireTimestamp)}`,
      `剩余时间：${formatRemaining(remainingMs)}`,
    ].join("\n"));
  } catch (error) {
    fail(String(error?.message || error));
  }
})();
