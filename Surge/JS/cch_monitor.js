/* CCH 配额与调用监控面板：展示供应商总额度及全站调用概览。 */

const ARGS = parseArgs($argument || "");
const BASE_URL = normalizeBaseUrl(ARGS.cch_url || "");
const API_TOKEN = String(ARGS.cch_admin_token || "").trim();
const PANEL_TITLE = "CCH 配额与监控";
const PANEL_ICON = ARGS.cch_icon || "chart.bar.fill";
const ERROR_ICON = "exclamationmark.triangle.fill";
const NORMAL_COLOR = parseColor(ARGS.cch_icon_color, "#34C759");
const WARNING_COLOR = "#FF9500";
const ERROR_COLOR = "#FF3B30";
const QUOTA_CACHE_SECONDS = clampNumber(ARGS.cch_quota_interval, 300, 60, 3600);

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

function normalizeBaseUrl(value) {
  return String(value).trim().replace(/\/+$/, "");
}

function parseColor(value, fallback) {
  const color = String(value || "").trim();
  return /^[0-9a-fA-F]{6}$/.test(color) ? `#${color}` : fallback;
}

function clampNumber(value, fallback, min, max) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.min(max, Math.max(min, parsed)) : fallback;
}

function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const headers = {
      Accept: "application/json",
      Authorization: `Bearer ${API_TOKEN}`,
    };
    const options = {
      url: `${BASE_URL}${path}`,
      headers,
      timeout: 10,
    };
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      options.body = JSON.stringify(body);
    }

    $httpClient[method](options, (error, response, data) => {
      if (error) return reject(new Error(error));
      const status = Number(response?.status || 0);
      if (status < 200 || status >= 300) {
        return reject(new Error(`HTTP ${status || "未知"}`));
      }
      try { resolve(JSON.parse(data)); }
      catch (_) { reject(new Error("API 响应解析失败")); }
    });
  });
}

function settle(promise) {
  return promise.then(
    (value) => ({ ok: true, value }),
    (error) => ({ ok: false, error })
  );
}

function hashString(value) {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(16);
}

function readQuotaCache() {
  try {
    const raw = $persistentStore.read(`cch_quota_${hashString(BASE_URL)}`);
    if (!raw) return null;
    const cache = JSON.parse(raw);
    return cache?.version === 1 && Array.isArray(cache.providers) ? cache : null;
  } catch (_) {
    return null;
  }
}

function writeQuotaCache(data) {
  const cache = { version: 1, updatedAt: Date.now(), ...data };
  try {
    $persistentStore.write(JSON.stringify(cache), `cch_quota_${hashString(BASE_URL)}`);
  } catch (_) {}
  return cache;
}

async function fetchQuota() {
  const providerResponse = await request("get", "/api/v1/providers");
  const allProviders = Array.isArray(providerResponse?.items) ? providerResponse.items : [];
  const configured = allProviders
    .filter((provider) => Number.isFinite(Number(provider?.limitTotalUsd)) && Number(provider.limitTotalUsd) > 0)
    .sort((a, b) => Number(a.priority || 0) - Number(b.priority || 0));

  if (configured.length === 0) {
    return writeQuotaCache({ totalProviders: allProviders.length, providers: [] });
  }

  const usageResponse = await request("post", "/api/v1/providers/limit-usage:batch", {
    providerIds: configured.map((provider) => Number(provider.id)),
  });
  const usageMap = new Map(
    (Array.isArray(usageResponse?.items) ? usageResponse.items : []).map((item) => [
      Number(item.id),
      item.usage?.limitTotalUsd,
    ])
  );

  const providers = configured.map((provider) => {
    const usage = usageMap.get(Number(provider.id));
    const current = Number(usage?.current);
    const limit = Number(usage?.limit ?? provider.limitTotalUsd);
    return {
      id: Number(provider.id),
      name: String(provider.name || `Provider ${provider.id}`),
      priority: Number(provider.priority || 0),
      current: Number.isFinite(current) ? current : null,
      limit: Number.isFinite(limit) && limit > 0 ? limit : null,
    };
  });

  return writeQuotaCache({ totalProviders: allProviders.length, providers });
}

async function getQuota() {
  const cache = readQuotaCache();
  const maxAge = QUOTA_CACHE_SECONDS * 1000;
  if (cache && Date.now() - Number(cache.updatedAt || 0) < maxAge) {
    return { data: cache, stale: false };
  }
  try {
    return { data: await fetchQuota(), stale: false };
  } catch (error) {
    if (cache) return { data: cache, stale: true };
    throw error;
  }
}

function formatInteger(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "N/A";
  return String(Math.round(number)).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function formatUsd(value) {
  if (value === null || value === undefined || value === "") return "N/A";
  const number = Number(value);
  return Number.isFinite(number) ? `$${number.toFixed(2)}` : "N/A";
}

function formatPercent(value) {
  const number = Number(value);
  return Number.isFinite(number) ? `${number.toFixed(number >= 10 ? 0 : 1)}%` : "N/A";
}

function formatDuration(milliseconds) {
  const number = Number(milliseconds);
  if (!Number.isFinite(number)) return "N/A";
  return number >= 1000 ? `${(number / 1000).toFixed(2)}s` : `${Math.round(number)}ms`;
}

function formatTime(timestamp) {
  const date = new Date(timestamp);
  const pad = (number) => String(number).padStart(2, "0");
  return `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function quotaPercent(provider) {
  return provider?.limit > 0 && Number.isFinite(provider?.current)
    ? (provider.current / provider.limit) * 100
    : NaN;
}

function finish(content, icon = PANEL_ICON, iconColor = NORMAL_COLOR) {
  $done({ title: PANEL_TITLE, content, icon, "icon-color": iconColor });
}

function fail(message) {
  finish(`❌ ${message}`, ERROR_ICON, ERROR_COLOR);
}

(async () => {
  try {
    if (!BASE_URL || !API_TOKEN) return fail("请配置 cch_url 和 cch_admin_token");
    if (!/^https:\/\//i.test(BASE_URL)) return fail("cch_url 必须使用 HTTPS");

    const [quotaResult, overviewResult] = await Promise.all([
      settle(getQuota()),
      settle(request("get", "/api/v1/dashboard/overview")),
    ]);
    if (!quotaResult.ok && !overviewResult.ok) return fail("CCH API 请求失败");

    const lines = [];
    let maxQuotaPercent = 0;
    if (quotaResult.ok) {
      const quota = quotaResult.value.data;
      const providers = quota.providers;
      lines.push(`供应商总额度（${providers.length}/${quota.totalProviders}）`);
      if (providers.length === 0) {
        lines.push("未设置供应商总限额");
      } else {
        for (const provider of providers) {
          const percent = quotaPercent(provider);
          if (Number.isFinite(percent)) maxQuotaPercent = Math.max(maxQuotaPercent, percent);
          lines.push(
            `${provider.name}：${formatUsd(provider.current)} / ${formatUsd(provider.limit)} · ${formatPercent(percent)}`
          );
        }
      }
      if (quotaResult.value.stale) lines.push("⚠️ 额度数据来自缓存");
    } else {
      lines.push(`⚠️ 供应商额度获取失败（${String(quotaResult.error?.message || "未知错误")}）`);
    }

    lines.push("");
    let errorRate = 0;
    if (overviewResult.ok) {
      const overview = overviewResult.value;
      errorRate = Number(overview.todayErrorRate || 0);
      lines.push(
        `今日调用：${formatInteger(overview.todayRequests)} 次 · ${formatUsd(overview.todayCost)}`,
        `RPM：${formatInteger(overview.recentMinuteRequests)} · 并发：${formatInteger(overview.concurrentSessions)}`,
        `错误率：${formatPercent(errorRate)} · 平均响应：${formatDuration(overview.avgResponseTime)}`
      );
    } else {
      lines.push("⚠️ 调用监控获取失败");
    }
    lines.push(`更新：${formatTime(Date.now())}`);

    const partialFailure = !quotaResult.ok || !overviewResult.ok || quotaResult.value?.stale;
    const critical = maxQuotaPercent >= 95 || errorRate >= 10;
    const warning = maxQuotaPercent >= 80 || errorRate >= 5 || partialFailure;
    finish(lines.join("\n"), PANEL_ICON, critical ? ERROR_COLOR : warning ? WARNING_COLOR : NORMAL_COLOR);
  } catch (error) {
    fail(String(error?.message || error));
  }
})();
