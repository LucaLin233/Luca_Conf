/* DeepSeek 余额信息面板：展示账户余额、赠送金额与查询时间，支持低余额提醒。 */

const ARGS = parseArgs($argument || "");
const API_KEY = ARGS.deepseek_key || "";
const PANEL_TITLE = "DeepSeek";
const PANEL_ICON = ARGS.deepseek_icon || "yensign.circle";
const ERROR_ICON = "exclamationmark.triangle.fill";
const ERROR_COLOR = "#EF4444";
const iconColorRaw = String(ARGS.deepseek_icon_color || "").trim();
const PANEL_ICON_COLOR = /^[0-9a-fA-F]{6}$/.test(iconColorRaw) ? `#${iconColorRaw}` : "#4D6BFE";
/* 参数留空时 Number("") 为 0，会静默关闭提醒，故空值按未配置处理 */
const notifyText = String(ARGS.deepseek_notify_balance || "").trim();
const notifyRaw = notifyText === "" ? NaN : Number(notifyText);
const NOTIFY_BALANCE = Number.isFinite(notifyRaw) ? Math.max(0, notifyRaw) : 10;
const warnText = String(ARGS.deepseek_warn_balance || "").trim();
const warnRaw = warnText === "" ? NaN : Number(warnText);
const WARN_BALANCE = Number.isFinite(warnRaw) ? Math.max(0, warnRaw) : 5;

const API_URL = "https://api.deepseek.com/user/balance";
const CURRENCY_SYMBOLS = { CNY: "¥", USD: "$" };

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

function currencySymbol(currency) {
  return CURRENCY_SYMBOLS[String(currency || "").toUpperCase()] || "";
}

function formatAmount(value) {
  const amount = Number(value);
  return Number.isFinite(amount) ? amount.toFixed(2) : String(value);
}

function money(currency, value) {
  return `${currencySymbol(currency)}${formatAmount(value)}`;
}

/* 通知去重按本地日期，避免 UTC 与北京时间的日期错位 */
function todayLocal() {
  const date = new Date();
  const pad = (number) => String(number).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function finish(content, icon = PANEL_ICON, iconColor = PANEL_ICON_COLOR) {
  $done({ title: PANEL_TITLE, content, icon, "icon-color": iconColor });
}

function fail(message) {
  finish(`❌ ${message}`, ERROR_ICON, ERROR_COLOR);
}

/* 12 小时制查询时间，手动格式化以兼容 JSCore */
function formatTime() {
  const date = new Date();
  const pad = (number) => String(number).padStart(2, "0");
  const hours = date.getHours();
  const period = hours < 12 ? "AM" : "PM";
  const hour12 = hours % 12 === 0 ? 12 : hours % 12;
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
    `${pad(hour12)}:${pad(date.getMinutes())}:${pad(date.getSeconds())} ${period}`;
}

function renderPanel(json, infos) {
  const lines = [];
  if (json.is_available === false) lines.push("⚠️ 余额不足，API 调用已不可用");
  if (infos.length === 1) {
    const info = infos[0];
    lines.push(`当前余额：${money(info.currency, info.total_balance)}`);
    lines.push(`赠送金额：${money(info.currency, info.granted_balance)}`);
  } else {
    infos.forEach((info) => {
      lines.push(
        `${info.currency}：当前余额 ${money(info.currency, info.total_balance)}` +
        `（赠送金额 ${money(info.currency, info.granted_balance)}）`
      );
    });
  }
  lines.push(`查询时间：${formatTime()}`);
  if (WARN_BALANCE > 0) {
    infos.forEach((info) => {
      const amount = Number(info.total_balance);
      if (Number.isFinite(amount) && amount < WARN_BALANCE) {
        lines.push(`⚠️ 余额低于 ${currencySymbol(info.currency)}${WARN_BALANCE}，请及时充值`);
      }
    });
  }
  return lines.join("\n");
}

function notifyLowBalance(infos) {
  if (NOTIFY_BALANCE === 0) return;
  const today = todayLocal();
  infos.forEach((info) => {
    const amount = Number(info.total_balance);
    if (!Number.isFinite(amount) || amount >= NOTIFY_BALANCE) return;
    const key = `deepseek_notice_${String(info.currency || "").toUpperCase()}_${today}`;
    try {
      if ($persistentStore.read(key)) return;
      $notification.post(
        "DeepSeek 余额提醒",
        `${info.currency} 余额 ${money(info.currency, info.total_balance)}，低于 ${money(info.currency, NOTIFY_BALANCE)}`,
        `充值余额：${money(info.currency, info.topped_up_balance)}\n赠送余额：${money(info.currency, info.granted_balance)}`
      );
      $persistentStore.write("1", key);
    } catch (_) {}
  });
}

/* 拉取余额；失败时抛出可直接展示的错误信息 */
async function fetchBalance() {
  const response = await httpGet(API_URL, {
    Accept: "application/json",
    Authorization: `Bearer ${API_KEY}`,
  });
  if (response.status === 401 || response.status === 403) throw new Error("API Key 无效或已失效");
  if (response.status !== 200) throw new Error(`API 请求失败 (HTTP ${response.status})`);

  let json;
  try { json = JSON.parse(response.body); }
  catch (_) { throw new Error("API 响应解析失败"); }

  const infos = Array.isArray(json && json.balance_infos) ? json.balance_infos : [];
  if (!infos.length) throw new Error("API 未返回余额信息");
  return { json, infos };
}

function dailySubtitle(json, infos) {
  const prefix = json.is_available === false ? "⚠️ 余额不足 · " : "";
  return prefix + infos.map((info) => money(info.currency, info.total_balance)).join(" · ");
}

function renderDaily(infos) {
  return infos.map((info) => (
    `${info.currency}：当前余额 ${money(info.currency, info.total_balance)}` +
    `（赠送金额 ${money(info.currency, info.granted_balance)}）`
  )).join("\n");
}

(async () => {
  const mode = String(ARGS.mode || "panel").trim().toLowerCase();
  const isDaily = mode === "daily";
  try {
    if (!API_KEY) {
      if (isDaily) return $done(); // 未配置密钥时日报静默跳过，避免每日骚扰
      return fail("缺少 deepseek_key 参数");
    }
    if (isDaily && String(ARGS.deepseek_daily_notify || "true").trim().toLowerCase() === "false") {
      return $done();
    }

    const { json, infos } = await fetchBalance();

    if (isDaily) {
      $notification.post("DeepSeek 余额日报", dailySubtitle(json, infos), renderDaily(infos));
      return $done();
    }

    notifyLowBalance(infos);
    finish(renderPanel(json, infos));
  } catch (error) {
    const message = String((error && error.message) || error);
    if (isDaily) {
      $notification.post("DeepSeek 余额日报", "查询失败", message);
      return $done();
    }
    fail(message);
  }
})();
