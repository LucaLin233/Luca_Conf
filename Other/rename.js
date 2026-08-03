/**
 * Sub-Store 地区名称规范化脚本
 *
 * 设计参考：Keywos 的 rename.js
 * 原作者：Keywos
 * 原作者仓库：https://github.com/Keywos/rule
 * 参考脚本：https://raw.githubusercontent.com/Keywos/rule/main/rename.js
 *
 * 默认 format=compact，只输出旗帜、机场名、地区和自动识别的服务商。
 * format=full 保留完整节点名，仅规范地区、旗帜、重复地区和序号。
 * number=remove 会清理名称中独立的 01/001 类序号，以及名称末尾的数字序号。
 * 默认 clear=true，会清理流量、到期、官网等信息节点。
 * airport=true 优先读取当前 Sub-Store 订阅的“名称”，并输出为「机场名」；
 * 集合级脚本无法区分每个节点来源时，会回退到 name= 或节点已有的括号名称。
 * 台湾地区统一使用 🇨🇳，避免部分国行设备无法显示 🇹🇼。
 *
 * 用法：在 Sub-Store 的“脚本操作”中填入脚本 URL，并在 URL 后用 # 传参；
 * 多个参数使用 & 连接。布尔参数可用 true/false、on/off 或 1/0。
 * 示例：
 *   script.js#format=compact&name=Viking
 *   script.js#format=full&out=en&flag=true&city=true
 *   script.js#out=code&clear=false
 *   script.js#name=机场A&nf=true&fgf=%20-%20
 *   script.js#include=IPLC+BGP&exclude=测试
 *   script.js#multiplier=max:2&number=region&one=true&sort=region
 *
 * 参数：
 *   format=compact|full         紧凑命名或完整名称，默认 compact
 *   out=zh|en|code              地区输出为中文、英文全称或两位代码，默认 zh
 *   provider=auto|off           自动提取尾部服务商，DP V 类名称会整体保留，默认 auto
 *   providerkey=FXT+JinX+BGP    服务商白名单，命中时优先使用
 *   dropkey=关键词1+关键词2     provider=auto 时额外忽略的线路描述词
 *   airport=true|false          读取 Sub-Store 订阅名称并输出为「机场名」，默认 true
 *   flag=true|false             添加并规范化旗帜，默认 true
 *   city=true|false             识别常见城市和地区别名，默认 true
 *   clear=true|false            清理流量、到期、官网等信息节点，默认 true
 *   clearkey=关键词1+关键词2    追加自定义清理关键词
 *   name=机场名                 手动覆盖 Sub-Store 订阅名称，输出为「机场名」
 *   nf=true|false               true 时前缀位于旗帜前，默认 false
 *   fgf=分隔符                  新增前缀和旗帜的分隔符，默认空格
 *   unknown=keep|drop|mark      未识别地区：保留、删除或标记，默认 keep
 *   include=关键词1+关键词2     至少命中一个关键词才保留
 *   exclude=关键词1+关键词2     命中任意关键词即删除，优先于 include
 *   case=true|false             include/exclude 是否区分大小写，默认 false
 *   multiplier=all|normal|high|max:N
 *                               倍率筛选，默认 all；high 表示 >1 倍
 *   blockquic=keep|on|off       保留、开启或关闭 block-quic，默认 keep
 *   number=off|remove|region    序号处理：保留、移除或按地区重编，默认 remove
 *   one=true|false              number=region 时单节点不添加 01，默认 false
 *   sort=original|region|name   保持原序、按地区或按名称排序，默认 original
 *   debug=true|false            输出匹配、过滤和统计日志，默认 false
 */

const inArg = typeof $arguments === "undefined" ? {} : $arguments;

function decode(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback;
  try {
    return decodeURIComponent(String(value));
  } catch (_) {
    return String(value);
  }
}
function bool(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback;
  if (typeof value === "boolean") return value;
  return !/^(false|off|0|no)$/i.test(String(value));
}
function list(value) {
  const text = decode(value, "");
  return text
    ? text
        .split("+")
        .map((item) => item.trim())
        .filter(Boolean)
    : [];
}

const config = {
  format: /^(compact|full)$/.test(inArg.format) ? inArg.format : "compact",
  out: /^(zh|en|code)$/.test(inArg.out) ? inArg.out : "zh",
  flag: bool(inArg.flag, true),
  city: bool(inArg.city, true),
  clear: bool(inArg.clear, true),
  provider: /^(auto|off)$/.test(inArg.provider) ? inArg.provider : "auto",
  providerKeys: list(inArg.providerkey),
  dropKeys: list(inArg.dropkey),
  airport: bool(inArg.airport, true),
  clearKeys: list(inArg.clearkey),
  name: decode(inArg.name, "").trim(),
  nameFirst: bool(inArg.nf, false),
  separator: decode(inArg.fgf, " "),
  unknown: /^(keep|drop|mark)$/.test(inArg.unknown) ? inArg.unknown : "keep",
  include: list(inArg.include),
  exclude: list(inArg.exclude),
  caseSensitive: bool(inArg.case, false),
  multiplier: decode(inArg.multiplier, "all").toLowerCase(),
  blockQuic: /^(keep|on|off)$/.test(inArg.blockquic) ? inArg.blockquic : "keep",
  number: /^(off|remove|region)$/.test(inArg.number) ? inArg.number : "remove",
  one: bool(inArg.one, false),
  sort: /^(original|region|name)$/.test(inArg.sort) ? inArg.sort : "original",
  debug: bool(inArg.debug, false),
};

const DEFAULT_CLEAR_KEYS = [
  "套餐",
  "到期",
  "有效期",
  "剩余",
  "已用",
  "过期",
  "失联",
  "测试",
  "官方",
  "网址",
  "客服",
  "网站",
  "获取订阅",
  "流量",
  "下次",
  "官址",
  "联系",
  "邮箱",
  "工单",
  "USE",
  "USED",
  "TOTAL",
  "EXPIRE",
  "EMAIL",
];
const REGIONS = [
  {
    code: "HK",
    zh: "香港",
    en: "Hong Kong",
    flag: "🇭🇰",
    aliases: ["Hong Kong", "Hongkong", "Hong Kong SAR", "HKG", "港"],
    inputFlag: "🇭🇰",
    cities: ["九龙", "九龙城", "Kowloon"],
  },
  {
    code: "MO",
    zh: "澳门",
    en: "Macao",
    flag: "🇲🇴",
    aliases: ["Macao", "Macau", "Macao SAR"],
    inputFlag: "🇲🇴",
    cities: [],
  },
  {
    code: "TW",
    zh: "台湾",
    en: "Taiwan",
    flag: "🇨🇳",
    aliases: ["Taiwan", "台灣", "Taiwan China"],
    inputFlag: "🇹🇼",
    cities: ["台北", "新北", "高雄", "臺北", "Taipei", "Kaohsiung"],
  },
  {
    code: "JP",
    zh: "日本",
    en: "Japan",
    flag: "🇯🇵",
    aliases: ["Japan"],
    inputFlag: "🇯🇵",
    cities: ["东京", "大阪", "大坂", "名古屋", "Tokyo", "Osaka", "Nagoya"],
  },
  {
    code: "KR",
    zh: "韩国",
    en: "South Korea",
    flag: "🇰🇷",
    aliases: ["Korea", "Republic of Korea"],
    inputFlag: "🇰🇷",
    cities: ["首尔", "首爾", "春川", "釜山", "Seoul", "Chuncheon", "Busan"],
  },
  {
    code: "SG",
    zh: "新加坡",
    en: "Singapore",
    flag: "🇸🇬",
    aliases: ["Singapore"],
    inputFlag: "🇸🇬",
    cities: ["狮城", "獅城"],
  },
  {
    code: "US",
    zh: "美国",
    en: "United States",
    flag: "🇺🇸",
    aliases: ["United States", "USA", "U.S.A.", "America"],
    inputFlag: "🇺🇸",
    cities: [
      "洛杉矶",
      "洛杉磯",
      "纽约",
      "紐約",
      "硅谷",
      "矽谷",
      "西雅图",
      "西雅圖",
      "芝加哥",
      "圣何塞",
      "波特兰",
      "Los Angeles",
      "New York",
      "Silicon Valley",
      "San Jose",
      "Seattle",
      "Chicago",
      "Portland",
      "Michigan",
    ],
  },
  {
    code: "GB",
    zh: "英国",
    en: "United Kingdom",
    flag: "🇬🇧",
    aliases: ["United Kingdom", "UK", "U.K.", "Great Britain", "Britain"],
    inputFlag: "🇬🇧",
    cities: ["伦敦", "倫敦", "London"],
  },
  {
    code: "FR",
    zh: "法国",
    en: "France",
    flag: "🇫🇷",
    aliases: ["France"],
    inputFlag: "🇫🇷",
    cities: ["巴黎", "Paris"],
  },
  {
    code: "DE",
    zh: "德国",
    en: "Germany",
    flag: "🇩🇪",
    aliases: ["Germany"],
    inputFlag: "🇩🇪",
    cities: ["法兰克福", "法蘭克福", "Frankfurt"],
  },
  {
    code: "AU",
    zh: "澳大利亚",
    en: "Australia",
    flag: "🇦🇺",
    aliases: ["Australia"],
    inputFlag: "🇦🇺",
    cities: ["悉尼", "墨尔本", "墨爾本", "Sydney", "Melbourne"],
  },
  {
    code: "AE",
    zh: "阿联酋",
    en: "United Arab Emirates",
    flag: "🇦🇪",
    aliases: ["Dubai", "UAE", "阿拉伯联合酋长国"],
    inputFlag: "🇦🇪",
    cities: ["迪拜", "Dubai", "Abu Dhabi"],
  },
  {
    code: "AF",
    zh: "阿富汗",
    en: "Afghanistan",
    flag: "🇦🇫",
    aliases: ["Afghanistan"],
    inputFlag: "🇦🇫",
    cities: [],
  },
  {
    code: "AL",
    zh: "阿尔巴尼亚",
    en: "Albania",
    flag: "🇦🇱",
    aliases: ["Albania"],
    inputFlag: "🇦🇱",
    cities: [],
  },
  {
    code: "DZ",
    zh: "阿尔及利亚",
    en: "Algeria",
    flag: "🇩🇿",
    aliases: ["Algeria"],
    inputFlag: "🇩🇿",
    cities: [],
  },
  {
    code: "AO",
    zh: "安哥拉",
    en: "Angola",
    flag: "🇦🇴",
    aliases: ["Angola"],
    inputFlag: "🇦🇴",
    cities: [],
  },
  {
    code: "AR",
    zh: "阿根廷",
    en: "Argentina",
    flag: "🇦🇷",
    aliases: ["Argentina"],
    inputFlag: "🇦🇷",
    cities: [],
  },
  {
    code: "AM",
    zh: "亚美尼亚",
    en: "Armenia",
    flag: "🇦🇲",
    aliases: ["Armenia"],
    inputFlag: "🇦🇲",
    cities: [],
  },
  {
    code: "AT",
    zh: "奥地利",
    en: "Austria",
    flag: "🇦🇹",
    aliases: ["Austria"],
    inputFlag: "🇦🇹",
    cities: [],
  },
  {
    code: "AZ",
    zh: "阿塞拜疆",
    en: "Azerbaijan",
    flag: "🇦🇿",
    aliases: ["Azerbaijan"],
    inputFlag: "🇦🇿",
    cities: [],
  },
  {
    code: "BH",
    zh: "巴林",
    en: "Bahrain",
    flag: "🇧🇭",
    aliases: ["Bahrain"],
    inputFlag: "🇧🇭",
    cities: [],
  },
  {
    code: "BD",
    zh: "孟加拉国",
    en: "Bangladesh",
    flag: "🇧🇩",
    aliases: ["Bangladesh"],
    inputFlag: "🇧🇩",
    cities: [],
  },
  {
    code: "BY",
    zh: "白俄罗斯",
    en: "Belarus",
    flag: "🇧🇾",
    aliases: ["Belarus"],
    inputFlag: "🇧🇾",
    cities: [],
  },
  {
    code: "BE",
    zh: "比利时",
    en: "Belgium",
    flag: "🇧🇪",
    aliases: ["Belgium"],
    inputFlag: "🇧🇪",
    cities: [],
  },
  {
    code: "BZ",
    zh: "伯利兹",
    en: "Belize",
    flag: "🇧🇿",
    aliases: ["Belize"],
    inputFlag: "🇧🇿",
    cities: [],
  },
  {
    code: "BJ",
    zh: "贝宁",
    en: "Benin",
    flag: "🇧🇯",
    aliases: ["Benin"],
    inputFlag: "🇧🇯",
    cities: [],
  },
  {
    code: "BT",
    zh: "不丹",
    en: "Bhutan",
    flag: "🇧🇹",
    aliases: ["Bhutan"],
    inputFlag: "🇧🇹",
    cities: [],
  },
  {
    code: "BO",
    zh: "玻利维亚",
    en: "Bolivia",
    flag: "🇧🇴",
    aliases: ["Bolivia", "Bolivia Plurinational State"],
    inputFlag: "🇧🇴",
    cities: [],
  },
  {
    code: "BA",
    zh: "波斯尼亚和黑塞哥维那",
    en: "Bosnia and Herzegovina",
    flag: "🇧🇦",
    aliases: ["Bosnia and Herzegovina"],
    inputFlag: "🇧🇦",
    cities: [],
  },
  {
    code: "BW",
    zh: "博茨瓦纳",
    en: "Botswana",
    flag: "🇧🇼",
    aliases: ["Botswana"],
    inputFlag: "🇧🇼",
    cities: [],
  },
  {
    code: "BR",
    zh: "巴西",
    en: "Brazil",
    flag: "🇧🇷",
    aliases: ["Brazil"],
    inputFlag: "🇧🇷",
    cities: [],
  },
  {
    code: "VG",
    zh: "英属维京群岛",
    en: "British Virgin Islands",
    flag: "🇻🇬",
    aliases: ["British Virgin Islands"],
    inputFlag: "🇻🇬",
    cities: [],
  },
  {
    code: "BN",
    zh: "文莱",
    en: "Brunei",
    flag: "🇧🇳",
    aliases: ["Brunei", "Brunei Darussalam"],
    inputFlag: "🇧🇳",
    cities: [],
  },
  {
    code: "BG",
    zh: "保加利亚",
    en: "Bulgaria",
    flag: "🇧🇬",
    aliases: ["Bulgaria"],
    inputFlag: "🇧🇬",
    cities: [],
  },
  {
    code: "BF",
    zh: "布基纳法索",
    en: "Burkina Faso",
    flag: "🇧🇫",
    aliases: ["Burkina-faso"],
    inputFlag: "🇧🇫",
    cities: [],
  },
  {
    code: "BI",
    zh: "布隆迪",
    en: "Burundi",
    flag: "🇧🇮",
    aliases: ["Burundi"],
    inputFlag: "🇧🇮",
    cities: [],
  },
  {
    code: "KH",
    zh: "柬埔寨",
    en: "Cambodia",
    flag: "🇰🇭",
    aliases: ["Cambodia"],
    inputFlag: "🇰🇭",
    cities: [],
  },
  {
    code: "CM",
    zh: "喀麦隆",
    en: "Cameroon",
    flag: "🇨🇲",
    aliases: ["Cameroon"],
    inputFlag: "🇨🇲",
    cities: [],
  },
  {
    code: "CA",
    zh: "加拿大",
    en: "Canada",
    flag: "🇨🇦",
    aliases: ["Canada"],
    inputFlag: "🇨🇦",
    cities: [
      "多伦多",
      "多倫多",
      "温哥华",
      "溫哥華",
      "蒙特利尔",
      "Toronto",
      "Vancouver",
      "Montreal",
    ],
  },
  {
    code: "CV",
    zh: "佛得角",
    en: "Cape Verde",
    flag: "🇨🇻",
    aliases: ["CapeVerde"],
    inputFlag: "🇨🇻",
    cities: [],
  },
  {
    code: "KY",
    zh: "开曼群岛",
    en: "Cayman Islands",
    flag: "🇰🇾",
    aliases: ["CaymanIslands"],
    inputFlag: "🇰🇾",
    cities: [],
  },
  {
    code: "CF",
    zh: "中非共和国",
    en: "Central African Republic",
    flag: "🇨🇫",
    aliases: ["Central African Republic"],
    inputFlag: "🇨🇫",
    cities: [],
  },
  {
    code: "TD",
    zh: "乍得",
    en: "Chad",
    flag: "🇹🇩",
    aliases: ["Chad"],
    inputFlag: "🇹🇩",
    cities: [],
  },
  {
    code: "CL",
    zh: "智利",
    en: "Chile",
    flag: "🇨🇱",
    aliases: ["Chile"],
    inputFlag: "🇨🇱",
    cities: [],
  },
  {
    code: "CO",
    zh: "哥伦比亚",
    en: "Colombia",
    flag: "🇨🇴",
    aliases: ["Colombia"],
    inputFlag: "🇨🇴",
    cities: [],
  },
  {
    code: "KM",
    zh: "科摩罗",
    en: "Comoros",
    flag: "🇰🇲",
    aliases: ["Comoros"],
    inputFlag: "🇰🇲",
    cities: [],
  },
  {
    code: "CG",
    zh: "刚果(布)",
    en: "Congo-Brazzaville",
    flag: "🇨🇬",
    aliases: ["Congo-Brazzaville"],
    inputFlag: "🇨🇬",
    cities: [],
  },
  {
    code: "CD",
    zh: "刚果(金)",
    en: "Congo-Kinshasa",
    flag: "🇨🇩",
    aliases: ["Congo-Kinshasa"],
    inputFlag: "🇨🇩",
    cities: [],
  },
  {
    code: "CR",
    zh: "哥斯达黎加",
    en: "Costa Rica",
    flag: "🇨🇷",
    aliases: ["CostaRica"],
    inputFlag: "🇨🇷",
    cities: [],
  },
  {
    code: "HR",
    zh: "克罗地亚",
    en: "Croatia",
    flag: "🇭🇷",
    aliases: ["Croatia"],
    inputFlag: "🇭🇷",
    cities: [],
  },
  {
    code: "CY",
    zh: "塞浦路斯",
    en: "Cyprus",
    flag: "🇨🇾",
    aliases: ["Cyprus"],
    inputFlag: "🇨🇾",
    cities: [],
  },
  {
    code: "CZ",
    zh: "捷克",
    en: "Czech Republic",
    flag: "🇨🇿",
    aliases: ["Czech Republic", "Czechia"],
    inputFlag: "🇨🇿",
    cities: [],
  },
  {
    code: "DK",
    zh: "丹麦",
    en: "Denmark",
    flag: "🇩🇰",
    aliases: ["Denmark"],
    inputFlag: "🇩🇰",
    cities: [],
  },
  {
    code: "DJ",
    zh: "吉布提",
    en: "Djibouti",
    flag: "🇩🇯",
    aliases: ["Djibouti"],
    inputFlag: "🇩🇯",
    cities: [],
  },
  {
    code: "DO",
    zh: "多米尼加共和国",
    en: "Dominican Republic",
    flag: "🇩🇴",
    aliases: ["Dominican Republic"],
    inputFlag: "🇩🇴",
    cities: [],
  },
  {
    code: "EC",
    zh: "厄瓜多尔",
    en: "Ecuador",
    flag: "🇪🇨",
    aliases: ["Ecuador"],
    inputFlag: "🇪🇨",
    cities: [],
  },
  {
    code: "EG",
    zh: "埃及",
    en: "Egypt",
    flag: "🇪🇬",
    aliases: ["Egypt"],
    inputFlag: "🇪🇬",
    cities: [],
  },
  {
    code: "SV",
    zh: "萨尔瓦多",
    en: "El Salvador",
    flag: "🇸🇻",
    aliases: ["EISalvador"],
    inputFlag: "🇸🇻",
    cities: [],
  },
  {
    code: "GQ",
    zh: "赤道几内亚",
    en: "Equatorial Guinea",
    flag: "🇬🇶",
    aliases: ["Equatorial Guinea"],
    inputFlag: "🇬🇶",
    cities: [],
  },
  {
    code: "ER",
    zh: "厄立特里亚",
    en: "Eritrea",
    flag: "🇪🇷",
    aliases: ["Eritrea"],
    inputFlag: "🇪🇷",
    cities: [],
  },
  {
    code: "EE",
    zh: "爱沙尼亚",
    en: "Estonia",
    flag: "🇪🇪",
    aliases: ["Estonia"],
    inputFlag: "🇪🇪",
    cities: [],
  },
  {
    code: "ET",
    zh: "埃塞俄比亚",
    en: "Ethiopia",
    flag: "🇪🇹",
    aliases: ["Ethiopia"],
    inputFlag: "🇪🇹",
    cities: [],
  },
  {
    code: "FJ",
    zh: "斐济",
    en: "Fiji",
    flag: "🇫🇯",
    aliases: ["Fiji"],
    inputFlag: "🇫🇯",
    cities: [],
  },
  {
    code: "FI",
    zh: "芬兰",
    en: "Finland",
    flag: "🇫🇮",
    aliases: ["Finland"],
    inputFlag: "🇫🇮",
    cities: [],
  },
  {
    code: "GA",
    zh: "加蓬",
    en: "Gabon",
    flag: "🇬🇦",
    aliases: ["Gabon"],
    inputFlag: "🇬🇦",
    cities: [],
  },
  {
    code: "GM",
    zh: "冈比亚",
    en: "Gambia",
    flag: "🇬🇲",
    aliases: ["Gambia"],
    inputFlag: "🇬🇲",
    cities: [],
  },
  {
    code: "GE",
    zh: "格鲁吉亚",
    en: "Georgia",
    flag: "🇬🇪",
    aliases: ["Georgia"],
    inputFlag: "🇬🇪",
    cities: [],
  },
  {
    code: "GH",
    zh: "加纳",
    en: "Ghana",
    flag: "🇬🇭",
    aliases: ["Ghana"],
    inputFlag: "🇬🇭",
    cities: [],
  },
  {
    code: "GR",
    zh: "希腊",
    en: "Greece",
    flag: "🇬🇷",
    aliases: ["Greece"],
    inputFlag: "🇬🇷",
    cities: [],
  },
  {
    code: "GL",
    zh: "格陵兰",
    en: "Greenland",
    flag: "🇬🇱",
    aliases: ["Greenland"],
    inputFlag: "🇬🇱",
    cities: [],
  },
  {
    code: "GT",
    zh: "危地马拉",
    en: "Guatemala",
    flag: "🇬🇹",
    aliases: ["Guatemala"],
    inputFlag: "🇬🇹",
    cities: [],
  },
  {
    code: "GN",
    zh: "几内亚",
    en: "Guinea",
    flag: "🇬🇳",
    aliases: ["Guinea"],
    inputFlag: "🇬🇳",
    cities: [],
  },
  {
    code: "GY",
    zh: "圭亚那",
    en: "Guyana",
    flag: "🇬🇾",
    aliases: ["Guyana"],
    inputFlag: "🇬🇾",
    cities: [],
  },
  {
    code: "HT",
    zh: "海地",
    en: "Haiti",
    flag: "🇭🇹",
    aliases: ["Haiti"],
    inputFlag: "🇭🇹",
    cities: [],
  },
  {
    code: "HN",
    zh: "洪都拉斯",
    en: "Honduras",
    flag: "🇭🇳",
    aliases: ["Honduras"],
    inputFlag: "🇭🇳",
    cities: [],
  },
  {
    code: "HU",
    zh: "匈牙利",
    en: "Hungary",
    flag: "🇭🇺",
    aliases: ["Hungary"],
    inputFlag: "🇭🇺",
    cities: [],
  },
  {
    code: "IS",
    zh: "冰岛",
    en: "Iceland",
    flag: "🇮🇸",
    aliases: ["Iceland"],
    inputFlag: "🇮🇸",
    cities: [],
  },
  {
    code: "IN",
    zh: "印度",
    en: "India",
    flag: "🇮🇳",
    aliases: ["India"],
    inputFlag: "🇮🇳",
    cities: ["孟买", "孟買", "Mumbai"],
  },
  {
    code: "ID",
    zh: "印尼",
    en: "Indonesia",
    flag: "🇮🇩",
    aliases: ["Indonesia"],
    inputFlag: "🇮🇩",
    cities: ["雅加达", "雅加達", "Jakarta"],
  },
  {
    code: "IR",
    zh: "伊朗",
    en: "Iran",
    flag: "🇮🇷",
    aliases: ["Iran", "Iran Islamic Republic"],
    inputFlag: "🇮🇷",
    cities: [],
  },
  {
    code: "IQ",
    zh: "伊拉克",
    en: "Iraq",
    flag: "🇮🇶",
    aliases: ["Iraq"],
    inputFlag: "🇮🇶",
    cities: [],
  },
  {
    code: "IE",
    zh: "爱尔兰",
    en: "Ireland",
    flag: "🇮🇪",
    aliases: ["Ireland"],
    inputFlag: "🇮🇪",
    cities: [],
  },
  {
    code: "IM",
    zh: "马恩岛",
    en: "Isle of Man",
    flag: "🇮🇲",
    aliases: ["Isle of Man"],
    inputFlag: "🇮🇲",
    cities: [],
  },
  {
    code: "IL",
    zh: "以色列",
    en: "Israel",
    flag: "🇮🇱",
    aliases: ["Israel"],
    inputFlag: "🇮🇱",
    cities: [],
  },
  {
    code: "IT",
    zh: "意大利",
    en: "Italy",
    flag: "🇮🇹",
    aliases: ["Italy"],
    inputFlag: "🇮🇹",
    cities: [],
  },
  {
    code: "CI",
    zh: "科特迪瓦",
    en: "Ivory Coast",
    flag: "🇨🇮",
    aliases: ["Ivory Coast"],
    inputFlag: "🇨🇮",
    cities: [],
  },
  {
    code: "JM",
    zh: "牙买加",
    en: "Jamaica",
    flag: "🇯🇲",
    aliases: ["Jamaica"],
    inputFlag: "🇯🇲",
    cities: [],
  },
  {
    code: "JO",
    zh: "约旦",
    en: "Jordan",
    flag: "🇯🇴",
    aliases: ["Jordan"],
    inputFlag: "🇯🇴",
    cities: [],
  },
  {
    code: "KZ",
    zh: "哈萨克斯坦",
    en: "Kazakhstan",
    flag: "🇰🇿",
    aliases: ["Kazakstan"],
    inputFlag: "🇰🇿",
    cities: [],
  },
  {
    code: "KE",
    zh: "肯尼亚",
    en: "Kenya",
    flag: "🇰🇪",
    aliases: ["Kenya"],
    inputFlag: "🇰🇪",
    cities: [],
  },
  {
    code: "KW",
    zh: "科威特",
    en: "Kuwait",
    flag: "🇰🇼",
    aliases: ["Kuwait"],
    inputFlag: "🇰🇼",
    cities: [],
  },
  {
    code: "KG",
    zh: "吉尔吉斯斯坦",
    en: "Kyrgyzstan",
    flag: "🇰🇬",
    aliases: ["Kyrgyzstan"],
    inputFlag: "🇰🇬",
    cities: [],
  },
  {
    code: "LA",
    zh: "老挝",
    en: "Laos",
    flag: "🇱🇦",
    aliases: ["Laos", "Lao PDR"],
    inputFlag: "🇱🇦",
    cities: [],
  },
  {
    code: "LV",
    zh: "拉脱维亚",
    en: "Latvia",
    flag: "🇱🇻",
    aliases: ["Latvia"],
    inputFlag: "🇱🇻",
    cities: [],
  },
  {
    code: "LB",
    zh: "黎巴嫩",
    en: "Lebanon",
    flag: "🇱🇧",
    aliases: ["Lebanon"],
    inputFlag: "🇱🇧",
    cities: [],
  },
  {
    code: "LS",
    zh: "莱索托",
    en: "Lesotho",
    flag: "🇱🇸",
    aliases: ["Lesotho"],
    inputFlag: "🇱🇸",
    cities: [],
  },
  {
    code: "LR",
    zh: "利比里亚",
    en: "Liberia",
    flag: "🇱🇷",
    aliases: ["Liberia"],
    inputFlag: "🇱🇷",
    cities: [],
  },
  {
    code: "LY",
    zh: "利比亚",
    en: "Libya",
    flag: "🇱🇾",
    aliases: ["Libya"],
    inputFlag: "🇱🇾",
    cities: [],
  },
  {
    code: "LT",
    zh: "立陶宛",
    en: "Lithuania",
    flag: "🇱🇹",
    aliases: ["Lithuania"],
    inputFlag: "🇱🇹",
    cities: [],
  },
  {
    code: "LU",
    zh: "卢森堡",
    en: "Luxembourg",
    flag: "🇱🇺",
    aliases: ["Luxembourg"],
    inputFlag: "🇱🇺",
    cities: [],
  },
  {
    code: "MK",
    zh: "马其顿",
    en: "North Macedonia",
    flag: "🇲🇰",
    aliases: ["Macedonia"],
    inputFlag: "🇲🇰",
    cities: [],
  },
  {
    code: "MG",
    zh: "马达加斯加",
    en: "Madagascar",
    flag: "🇲🇬",
    aliases: ["Madagascar"],
    inputFlag: "🇲🇬",
    cities: [],
  },
  {
    code: "MW",
    zh: "马拉维",
    en: "Malawi",
    flag: "🇲🇼",
    aliases: ["Malawi"],
    inputFlag: "🇲🇼",
    cities: [],
  },
  {
    code: "MY",
    zh: "马来",
    en: "Malaysia",
    flag: "🇲🇾",
    aliases: ["Malaysia"],
    inputFlag: "🇲🇾",
    cities: ["吉隆坡", "Kuala Lumpur"],
  },
  {
    code: "MV",
    zh: "马尔代夫",
    en: "Maldives",
    flag: "🇲🇻",
    aliases: ["Maldives"],
    inputFlag: "🇲🇻",
    cities: [],
  },
  {
    code: "ML",
    zh: "马里",
    en: "Mali",
    flag: "🇲🇱",
    aliases: ["Mali"],
    inputFlag: "🇲🇱",
    cities: [],
  },
  {
    code: "MT",
    zh: "马耳他",
    en: "Malta",
    flag: "🇲🇹",
    aliases: ["Malta"],
    inputFlag: "🇲🇹",
    cities: [],
  },
  {
    code: "MR",
    zh: "毛利塔尼亚",
    en: "Mauritania",
    flag: "🇲🇷",
    aliases: ["Mauritania"],
    inputFlag: "🇲🇷",
    cities: [],
  },
  {
    code: "MU",
    zh: "毛里求斯",
    en: "Mauritius",
    flag: "🇲🇺",
    aliases: ["Mauritius"],
    inputFlag: "🇲🇺",
    cities: [],
  },
  {
    code: "MX",
    zh: "墨西哥",
    en: "Mexico",
    flag: "🇲🇽",
    aliases: ["Mexico"],
    inputFlag: "🇲🇽",
    cities: [],
  },
  {
    code: "MD",
    zh: "摩尔多瓦",
    en: "Moldova",
    flag: "🇲🇩",
    aliases: ["Moldova", "Moldova Republic"],
    inputFlag: "🇲🇩",
    cities: [],
  },
  {
    code: "MC",
    zh: "摩纳哥",
    en: "Monaco",
    flag: "🇲🇨",
    aliases: ["Monaco"],
    inputFlag: "🇲🇨",
    cities: [],
  },
  {
    code: "MN",
    zh: "蒙古",
    en: "Mongolia",
    flag: "🇲🇳",
    aliases: ["Mongolia"],
    inputFlag: "🇲🇳",
    cities: [],
  },
  {
    code: "ME",
    zh: "黑山共和国",
    en: "Montenegro",
    flag: "🇲🇪",
    aliases: ["Montenegro"],
    inputFlag: "🇲🇪",
    cities: [],
  },
  {
    code: "MA",
    zh: "摩洛哥",
    en: "Morocco",
    flag: "🇲🇦",
    aliases: ["Morocco"],
    inputFlag: "🇲🇦",
    cities: [],
  },
  {
    code: "MZ",
    zh: "莫桑比克",
    en: "Mozambique",
    flag: "🇲🇿",
    aliases: ["Mozambique"],
    inputFlag: "🇲🇿",
    cities: [],
  },
  {
    code: "MM",
    zh: "缅甸",
    en: "Myanmar",
    flag: "🇲🇲",
    aliases: ["Myanmar(Burma)"],
    inputFlag: "🇲🇲",
    cities: [],
  },
  {
    code: "NA",
    zh: "纳米比亚",
    en: "Namibia",
    flag: "🇳🇦",
    aliases: ["Namibia"],
    inputFlag: "🇳🇦",
    cities: [],
  },
  {
    code: "NP",
    zh: "尼泊尔",
    en: "Nepal",
    flag: "🇳🇵",
    aliases: ["Nepal"],
    inputFlag: "🇳🇵",
    cities: [],
  },
  {
    code: "NL",
    zh: "荷兰",
    en: "Netherlands",
    flag: "🇳🇱",
    aliases: ["Netherlands"],
    inputFlag: "🇳🇱",
    cities: ["阿姆斯特丹", "Amsterdam"],
  },
  {
    code: "NZ",
    zh: "新西兰",
    en: "New Zealand",
    flag: "🇳🇿",
    aliases: ["New Zealand"],
    inputFlag: "🇳🇿",
    cities: [],
  },
  {
    code: "NI",
    zh: "尼加拉瓜",
    en: "Nicaragua",
    flag: "🇳🇮",
    aliases: ["Nicaragua"],
    inputFlag: "🇳🇮",
    cities: [],
  },
  {
    code: "NE",
    zh: "尼日尔",
    en: "Niger",
    flag: "🇳🇪",
    aliases: ["Niger"],
    inputFlag: "🇳🇪",
    cities: [],
  },
  {
    code: "NG",
    zh: "尼日利亚",
    en: "Nigeria",
    flag: "🇳🇬",
    aliases: ["Nigeria"],
    inputFlag: "🇳🇬",
    cities: [],
  },
  {
    code: "KP",
    zh: "朝鲜",
    en: "North Korea",
    flag: "🇰🇵",
    aliases: ["NorthKorea", "DPRK"],
    inputFlag: "🇰🇵",
    cities: [],
  },
  {
    code: "NO",
    zh: "挪威",
    en: "Norway",
    flag: "🇳🇴",
    aliases: ["Norway"],
    inputFlag: "🇳🇴",
    cities: [],
  },
  {
    code: "OM",
    zh: "阿曼",
    en: "Oman",
    flag: "🇴🇲",
    aliases: ["Oman"],
    inputFlag: "🇴🇲",
    cities: [],
  },
  {
    code: "PK",
    zh: "巴基斯坦",
    en: "Pakistan",
    flag: "🇵🇰",
    aliases: ["Pakistan"],
    inputFlag: "🇵🇰",
    cities: [],
  },
  {
    code: "PA",
    zh: "巴拿马",
    en: "Panama",
    flag: "🇵🇦",
    aliases: ["Panama"],
    inputFlag: "🇵🇦",
    cities: [],
  },
  {
    code: "PY",
    zh: "巴拉圭",
    en: "Paraguay",
    flag: "🇵🇾",
    aliases: ["Paraguay"],
    inputFlag: "🇵🇾",
    cities: [],
  },
  {
    code: "PE",
    zh: "秘鲁",
    en: "Peru",
    flag: "🇵🇪",
    aliases: ["Peru"],
    inputFlag: "🇵🇪",
    cities: [],
  },
  {
    code: "PH",
    zh: "菲律宾",
    en: "Philippines",
    flag: "🇵🇭",
    aliases: ["Philippines"],
    inputFlag: "🇵🇭",
    cities: ["马尼拉", "馬尼拉", "Manila"],
  },
  {
    code: "PT",
    zh: "葡萄牙",
    en: "Portugal",
    flag: "🇵🇹",
    aliases: ["Portugal"],
    inputFlag: "🇵🇹",
    cities: [],
  },
  {
    code: "PR",
    zh: "波多黎各",
    en: "Puerto Rico",
    flag: "🇵🇷",
    aliases: ["PuertoRico"],
    inputFlag: "🇵🇷",
    cities: [],
  },
  {
    code: "QA",
    zh: "卡塔尔",
    en: "Qatar",
    flag: "🇶🇦",
    aliases: ["Qatar"],
    inputFlag: "🇶🇦",
    cities: [],
  },
  {
    code: "RO",
    zh: "罗马尼亚",
    en: "Romania",
    flag: "🇷🇴",
    aliases: ["Romania"],
    inputFlag: "🇷🇴",
    cities: [],
  },
  {
    code: "RU",
    zh: "俄罗斯",
    en: "Russia",
    flag: "🇷🇺",
    aliases: ["Russia", "Russian Federation"],
    inputFlag: "🇷🇺",
    cities: ["莫斯科", "Moscow"],
  },
  {
    code: "RW",
    zh: "卢旺达",
    en: "Rwanda",
    flag: "🇷🇼",
    aliases: ["Rwanda"],
    inputFlag: "🇷🇼",
    cities: [],
  },
  {
    code: "SM",
    zh: "圣马力诺",
    en: "San Marino",
    flag: "🇸🇲",
    aliases: ["SanMarino"],
    inputFlag: "🇸🇲",
    cities: [],
  },
  {
    code: "SA",
    zh: "沙特阿拉伯",
    en: "Saudi Arabia",
    flag: "🇸🇦",
    aliases: ["SaudiArabia"],
    inputFlag: "🇸🇦",
    cities: [],
  },
  {
    code: "SN",
    zh: "塞内加尔",
    en: "Senegal",
    flag: "🇸🇳",
    aliases: ["Senegal"],
    inputFlag: "🇸🇳",
    cities: [],
  },
  {
    code: "RS",
    zh: "塞尔维亚",
    en: "Serbia",
    flag: "🇷🇸",
    aliases: ["Serbia"],
    inputFlag: "🇷🇸",
    cities: [],
  },
  {
    code: "SL",
    zh: "塞拉利昂",
    en: "Sierra Leone",
    flag: "🇸🇱",
    aliases: ["SierraLeone"],
    inputFlag: "🇸🇱",
    cities: [],
  },
  {
    code: "SK",
    zh: "斯洛伐克",
    en: "Slovakia",
    flag: "🇸🇰",
    aliases: ["Slovakia"],
    inputFlag: "🇸🇰",
    cities: [],
  },
  {
    code: "SI",
    zh: "斯洛文尼亚",
    en: "Slovenia",
    flag: "🇸🇮",
    aliases: ["Slovenia"],
    inputFlag: "🇸🇮",
    cities: [],
  },
  {
    code: "SO",
    zh: "索马里",
    en: "Somalia",
    flag: "🇸🇴",
    aliases: ["Somalia"],
    inputFlag: "🇸🇴",
    cities: [],
  },
  {
    code: "ZA",
    zh: "南非",
    en: "South Africa",
    flag: "🇿🇦",
    aliases: ["SouthAfrica"],
    inputFlag: "🇿🇦",
    cities: [],
  },
  {
    code: "ES",
    zh: "西班牙",
    en: "Spain",
    flag: "🇪🇸",
    aliases: ["Spain"],
    inputFlag: "🇪🇸",
    cities: [],
  },
  {
    code: "LK",
    zh: "斯里兰卡",
    en: "Sri Lanka",
    flag: "🇱🇰",
    aliases: ["SriLanka"],
    inputFlag: "🇱🇰",
    cities: [],
  },
  {
    code: "SD",
    zh: "苏丹",
    en: "Sudan",
    flag: "🇸🇩",
    aliases: ["Sudan"],
    inputFlag: "🇸🇩",
    cities: [],
  },
  {
    code: "SR",
    zh: "苏里南",
    en: "Suriname",
    flag: "🇸🇷",
    aliases: ["Suriname"],
    inputFlag: "🇸🇷",
    cities: [],
  },
  {
    code: "SZ",
    zh: "斯威士兰",
    en: "Swaziland",
    flag: "🇸🇿",
    aliases: ["Swaziland"],
    inputFlag: "🇸🇿",
    cities: [],
  },
  {
    code: "SE",
    zh: "瑞典",
    en: "Sweden",
    flag: "🇸🇪",
    aliases: ["Sweden"],
    inputFlag: "🇸🇪",
    cities: [],
  },
  {
    code: "CH",
    zh: "瑞士",
    en: "Switzerland",
    flag: "🇨🇭",
    aliases: ["Switzerland"],
    inputFlag: "🇨🇭",
    cities: ["苏黎世", "蘇黎世", "Zurich"],
  },
  {
    code: "SY",
    zh: "叙利亚",
    en: "Syria",
    flag: "🇸🇾",
    aliases: ["Syria", "Syrian Arab Republic"],
    inputFlag: "🇸🇾",
    cities: [],
  },
  {
    code: "TJ",
    zh: "塔吉克斯坦",
    en: "Tajikistan",
    flag: "🇹🇯",
    aliases: ["Tajikstan"],
    inputFlag: "🇹🇯",
    cities: [],
  },
  {
    code: "TZ",
    zh: "坦桑尼亚",
    en: "Tanzania",
    flag: "🇹🇿",
    aliases: ["Tanzania", "Tanzania United Republic"],
    inputFlag: "🇹🇿",
    cities: [],
  },
  {
    code: "TH",
    zh: "泰国",
    en: "Thailand",
    flag: "🇹🇭",
    aliases: ["Thailand"],
    inputFlag: "🇹🇭",
    cities: ["曼谷", "Bangkok"],
  },
  {
    code: "TG",
    zh: "多哥",
    en: "Togo",
    flag: "🇹🇬",
    aliases: ["Togo"],
    inputFlag: "🇹🇬",
    cities: [],
  },
  {
    code: "TO",
    zh: "汤加",
    en: "Tonga",
    flag: "🇹🇴",
    aliases: ["Tonga"],
    inputFlag: "🇹🇴",
    cities: [],
  },
  {
    code: "TT",
    zh: "特立尼达和多巴哥",
    en: "Trinidad and Tobago",
    flag: "🇹🇹",
    aliases: ["TrinidadandTobago"],
    inputFlag: "🇹🇹",
    cities: [],
  },
  {
    code: "TN",
    zh: "突尼斯",
    en: "Tunisia",
    flag: "🇹🇳",
    aliases: ["Tunisia"],
    inputFlag: "🇹🇳",
    cities: [],
  },
  {
    code: "TR",
    zh: "土耳其",
    en: "Turkey",
    flag: "🇹🇷",
    aliases: ["Turkey"],
    inputFlag: "🇹🇷",
    cities: ["伊斯坦布尔", "伊斯坦堡", "Istanbul"],
  },
  {
    code: "TM",
    zh: "土库曼斯坦",
    en: "Turkmenistan",
    flag: "🇹🇲",
    aliases: ["Turkmenistan"],
    inputFlag: "🇹🇲",
    cities: [],
  },
  {
    code: "VI",
    zh: "美属维尔京群岛",
    en: "U.S.Virgin Islands",
    flag: "🇻🇮",
    aliases: ["U.S.Virgin Islands"],
    inputFlag: "🇻🇮",
    cities: [],
  },
  {
    code: "UG",
    zh: "乌干达",
    en: "Uganda",
    flag: "🇺🇬",
    aliases: ["Uganda"],
    inputFlag: "🇺🇬",
    cities: [],
  },
  {
    code: "UA",
    zh: "乌克兰",
    en: "Ukraine",
    flag: "🇺🇦",
    aliases: ["Ukraine"],
    inputFlag: "🇺🇦",
    cities: [],
  },
  {
    code: "UY",
    zh: "乌拉圭",
    en: "Uruguay",
    flag: "🇺🇾",
    aliases: ["Uruguay"],
    inputFlag: "🇺🇾",
    cities: [],
  },
  {
    code: "UZ",
    zh: "乌兹别克斯坦",
    en: "Uzbekistan",
    flag: "🇺🇿",
    aliases: ["Uzbekistan"],
    inputFlag: "🇺🇿",
    cities: [],
  },
  {
    code: "VE",
    zh: "委内瑞拉",
    en: "Venezuela",
    flag: "🇻🇪",
    aliases: ["Venezuela", "Venezuela Bolivarian Republic"],
    inputFlag: "🇻🇪",
    cities: [],
  },
  {
    code: "VN",
    zh: "越南",
    en: "Vietnam",
    flag: "🇻🇳",
    aliases: ["Vietnam", "Viet Nam"],
    inputFlag: "🇻🇳",
    cities: ["胡志明", "河内", "河內", "Ho Chi Minh", "Hanoi"],
  },
  {
    code: "YE",
    zh: "也门",
    en: "Yemen",
    flag: "🇾🇪",
    aliases: ["Yemen"],
    inputFlag: "🇾🇪",
    cities: [],
  },
  {
    code: "ZM",
    zh: "赞比亚",
    en: "Zambia",
    flag: "🇿🇲",
    aliases: ["Zambia"],
    inputFlag: "🇿🇲",
    cities: [],
  },
  {
    code: "ZW",
    zh: "津巴布韦",
    en: "Zimbabwe",
    flag: "🇿🇼",
    aliases: ["Zimbabwe"],
    inputFlag: "🇿🇼",
    cities: [],
  },
  {
    code: "AD",
    zh: "安道尔",
    en: "Andorra",
    flag: "🇦🇩",
    aliases: ["Andorra"],
    inputFlag: "🇦🇩",
    cities: [],
  },
  {
    code: "RE",
    zh: "留尼汪",
    en: "Reunion",
    flag: "🇷🇪",
    aliases: ["Reunion"],
    inputFlag: "🇷🇪",
    cities: [],
  },
  {
    code: "PL",
    zh: "波兰",
    en: "Poland",
    flag: "🇵🇱",
    aliases: ["Poland"],
    inputFlag: "🇵🇱",
    cities: [],
  },
  {
    code: "GU",
    zh: "关岛",
    en: "Guam",
    flag: "🇬🇺",
    aliases: ["Guam"],
    inputFlag: "🇬🇺",
    cities: [],
  },
  {
    code: "VA",
    zh: "梵蒂冈",
    en: "Vatican City",
    flag: "🇻🇦",
    aliases: ["Vatican"],
    inputFlag: "🇻🇦",
    cities: [],
  },
  {
    code: "LI",
    zh: "列支敦士登",
    en: "Liechtenstein",
    flag: "🇱🇮",
    aliases: ["Liechtensteins"],
    inputFlag: "🇱🇮",
    cities: [],
  },
  {
    code: "CW",
    zh: "库拉索",
    en: "Curacao",
    flag: "🇨🇼",
    aliases: ["Curacao"],
    inputFlag: "🇨🇼",
    cities: [],
  },
  {
    code: "SC",
    zh: "塞舌尔",
    en: "Seychelles",
    flag: "🇸🇨",
    aliases: ["Seychelles"],
    inputFlag: "🇸🇨",
    cities: [],
  },
  {
    code: "AQ",
    zh: "南极",
    en: "Antarctica",
    flag: "🇦🇶",
    aliases: ["Antarctica"],
    inputFlag: "🇦🇶",
    cities: [],
  },
  {
    code: "GI",
    zh: "直布罗陀",
    en: "Gibraltar",
    flag: "🇬🇮",
    aliases: ["Gibraltar"],
    inputFlag: "🇬🇮",
    cities: [],
  },
  {
    code: "CU",
    zh: "古巴",
    en: "Cuba",
    flag: "🇨🇺",
    aliases: ["Cuba"],
    inputFlag: "🇨🇺",
    cities: [],
  },
  {
    code: "FO",
    zh: "法罗群岛",
    en: "Faroe Islands",
    flag: "🇫🇴",
    aliases: ["Faroe Islands"],
    inputFlag: "🇫🇴",
    cities: [],
  },
  {
    code: "AX",
    zh: "奥兰群岛",
    en: "Aland Islands",
    flag: "🇦🇽",
    aliases: ["Ahvenanmaa"],
    inputFlag: "🇦🇽",
    cities: [],
  },
  {
    code: "BM",
    zh: "百慕达",
    en: "Bermuda",
    flag: "🇧🇲",
    aliases: ["Bermuda"],
    inputFlag: "🇧🇲",
    cities: [],
  },
  {
    code: "TL",
    zh: "东帝汶",
    en: "Timor-Leste",
    flag: "🇹🇱",
    aliases: ["Timor-Leste"],
    inputFlag: "🇹🇱",
    cities: [],
  },
  {
    code: "CN",
    zh: "中国",
    en: "China",
    flag: "🇨🇳",
    inputFlag: "🇨🇳",
    aliases: ["中国大陆", "大陆", "Mainland China", "PRC"],
    cities: [
      "北京",
      "上海",
      "广州",
      "深圳",
      "杭州",
      "成都",
      "重庆",
      "Beijing",
      "Shanghai",
      "Guangzhou",
      "Shenzhen",
    ],
  },
];
const FLAG_RE = /(?:[\uD83C][\uDDE6-\uDDFF]){2}/g;

function escapeRegExp(value) {
  return value.replace(/[.*+?^$(){}|[\]\\]/g, "\\$&");
}
function aliasRegExp(alias) {
  const escaped = escapeRegExp(alias);
  if (/^[A-Za-z0-9][A-Za-z0-9 .'-]*$/.test(alias)) {
    return new RegExp(
      "(^|[^A-Za-z0-9])(" + escaped + ")(?=$|[^A-Za-z0-9])",
      "i",
    );
  }
  return new RegExp("(" + escaped + ")", "i");
}
function buildMatchers() {
  const matchers = [];
  REGIONS.forEach((region, regionIndex) => {
    const aliases = [region.zh, region.en, region.code, region.inputFlag]
      .concat(region.aliases || [])
      .concat(config.city ? region.cities || [] : []);
    [...new Set(aliases.filter(Boolean))].forEach((alias) => {
      matchers.push({
        region,
        regionIndex,
        alias,
        isFlag: alias === region.inputFlag,
        regex: aliasRegExp(alias),
      });
    });
  });
  return matchers.sort((a, b) => b.alias.length - a.alias.length);
}
const MATCHERS = buildMatchers();

function findRegion(name) {
  let bestText = null,
    bestFlag = null;
  MATCHERS.forEach((matcher) => {
    const match = matcher.regex.exec(name);
    if (!match) return;
    const value = match[2] !== undefined ? match[2] : match[1];
    const index = match.index + (match[2] !== undefined ? match[1].length : 0);
    const current = matcher.isFlag ? bestFlag : bestText;
    if (
      !current ||
      index < current.index ||
      (index === current.index && value.length > current.value.length)
    ) {
      const candidate = { ...matcher, index, value };
      if (matcher.isFlag) bestFlag = candidate;
      else bestText = candidate;
    }
  });
  return bestText || bestFlag;
}
function outputRegion(region) {
  if (config.out === "en") return region.en;
  if (config.out === "code") return region.code;
  return region.zh;
}
function removeAllAlias(name, alias) {
  let match;
  while ((match = aliasRegExp(alias).exec(name))) {
    const value = match[2] !== undefined ? match[2] : match[1];
    const index = match.index + (match[2] !== undefined ? match[1].length : 0);
    name = name.slice(0, index) + name.slice(index + value.length);
  }
  return name;
}
function normalizeRegionAliases(name, region, canonical, canonicalIndex) {
  const marker = "\uE000REGION\uE001";
  name =
    name.slice(0, canonicalIndex) +
    marker +
    name.slice(canonicalIndex + canonical.length);
  const aliases = [region.zh, region.en, region.code]
    .concat(region.aliases || [])
    .filter(
      (alias) => alias && (alias.length > 1 || /^[A-Za-z0-9]{2,}$/.test(alias)),
    )
    .sort((a, b) => b.length - a.length);
  [...new Set(aliases)].forEach((alias) => {
    name = removeAllAlias(name, alias);
  });
  return name
    .replace(marker, canonical)
    .replace(/\s{2,}/g, " ")
    .trim();
}
function cleanAirportName(value) {
  const text = String(value || "").trim();
  const match = text.match(
    /^(?:「([^」]+)」|『([^』]+)』|【([^】]+)】|\[([^\]]+)\])$/,
  );
  return match ? match.slice(1).find(Boolean).trim() : text;
}
function formatAirportName(value) {
  const airport = cleanAirportName(value);
  return airport ? "「" + airport + "」" : "";
}
function extractAirport(name, sourceAirport) {
  if (!config.airport) return "";
  if (config.name) return cleanAirportName(config.name);
  if (sourceAirport) return cleanAirportName(sourceAirport);
  const match = name.match(
    /「([^」]+)」|『([^』]+)』|【([^】]+)】|\[([^\]]+)\]/,
  );
  return match ? match.slice(1).find(Boolean).trim() : "";
}
const PROVIDER_NOISE = new Set([
  "trojan",
  "vmess",
  "vless",
  "ss",
  "ssr",
  "hysteria",
  "hysteria2",
  "hy2",
  "tuic",
  "anytls",
  "socks",
  "socks5",
  "http",
  "https",
  "quic",
  "grpc",
  "ws",
  "iplc",
  "iepl",
  "ipsec",
  "premium",
  "pro",
  "standard",
  "std",
  "direct",
  "relay",
  "go",
  "实验线路",
  "實驗線路",
  "实验",
  "實驗",
  "线路",
  "線路",
  "专线",
  "專線",
  "直连",
  "直連",
  "中转",
  "中轉",
  "入口",
  "出口",
  "落地",
  "高级",
  "高級",
  "标准",
  "標準",
  "优化",
  "優化",
  "节点",
  "節點",
]);
function extractProvider(name, region, airport) {
  if (config.provider === "off") return "";
  const explicit = config.providerKeys.find((key) =>
    name.toLowerCase().includes(key.toLowerCase()),
  );
  if (explicit) return explicit;

  let text = name
    .replace(FLAG_RE, " ")
    .replace(/「[^」]*」|『[^』]*』|【[^】]*】|\[[^\]]*\]/g, " ");
  const aliases = [region.zh, region.en, region.code]
    .concat(region.aliases || [])
    .concat(config.city ? region.cities || [] : [])
    .filter(
      (alias) => alias && (alias.length > 1 || /^[A-Za-z0-9]{2,}$/.test(alias)),
    )
    .sort((a, b) => b.length - a.length);
  [...new Set(aliases)].forEach((alias) => {
    text = removeAllAlias(text, alias);
  });
  text = text.replace(/[\-_|/\\,:;·•]+/g, " ");

  const airportLower = airport.toLowerCase();
  const drop = new Set(config.dropKeys.map((key) => key.toLowerCase()));
  const tokens = text
    .split(/\s+/)
    .map((token) => token.trim())
    .filter(Boolean)
    .filter((token) => {
      const lower = token.toLowerCase();
      return (
        lower !== airportLower &&
        !PROVIDER_NOISE.has(lower) &&
        !drop.has(lower) &&
        !/^\d{1,4}$/.test(token) &&
        !/^\d+(?:\.\d+)?(?:x|×|倍)$/i.test(token)
      );
    });
  if (!tokens.length) return "";
  const last = tokens[tokens.length - 1];
  if (tokens.length > 1 && /^[A-Z]$/.test(last)) {
    return tokens[tokens.length - 2] + " " + last;
  }
  return last;
}
function compactName(originalName, region, sourceAirport) {
  const airport = extractAirport(originalName, sourceAirport);
  const provider = extractProvider(originalName, region, airport);
  const airportLabel = formatAirportName(airport);
  const parts = [];
  if (airportLabel && config.nameFirst) parts.push(airportLabel);
  if (config.flag) parts.push(region.flag);
  if (airportLabel && !config.nameFirst) parts.push(airportLabel);
  parts.push(outputRegion(region));
  if (provider) parts.push(provider);
  return parts.join(config.separator);
}
function stripFlags(name) {
  return name.replace(FLAG_RE, "").replace(/^\s+|\s+$/g, "");
}
function addPrefix(name, region, sourceAirport) {
  const airport = config.name
    ? formatAirportName(config.name)
    : config.airport
      ? formatAirportName(sourceAirport)
      : "";
  const parts = [];
  if (airport && config.nameFirst) parts.push(airport);
  if (config.flag && region) parts.push(region.flag);
  if (airport && !config.nameFirst) parts.push(airport);
  if (!parts.length) return name;
  return parts.join(config.separator) + config.separator + name;
}
function contains(name, keyword) {
  return config.caseSensitive
    ? name.includes(keyword)
    : name.toLowerCase().includes(keyword.toLowerCase());
}
function clearReason(name) {
  if (config.clear) {
    const key = DEFAULT_CLEAR_KEYS.concat(config.clearKeys).find((item) =>
      contains(name, item),
    );
    if (key) return "clear:" + key;
  }
  const excluded = config.exclude.find((item) => contains(name, item));
  if (excluded) return "exclude:" + excluded;
  if (
    config.include.length &&
    !config.include.some((item) => contains(name, item))
  )
    return "include:no-match";
  return "";
}
function multiplierValue(name) {
  let match = name.match(
    /(?:^|[^\d.])(\d+(?:\.\d+)?)\s*(?:x|×|倍)(?:$|[^A-Za-z])/i,
  );
  if (!match) match = name.match(/(?:x|×)\s*(\d+(?:\.\d+)?)/i);
  if (match) return Number(match[1]);
  const superscript = name.match(/ˣ([²³⁴⁵⁶⁷⁸⁹]|¹⁰|²⁰|³⁰|⁴⁰|⁵⁰)/);
  if (!superscript) return 1;
  const map = {
    "²": 2,
    "³": 3,
    "⁴": 4,
    "⁵": 5,
    "⁶": 6,
    "⁷": 7,
    "⁸": 8,
    "⁹": 9,
    "¹⁰": 10,
    "²⁰": 20,
    "³⁰": 30,
    "⁴⁰": 40,
    "⁵⁰": 50,
  };
  return map[superscript[1]] || 1;
}
function multiplierAllowed(name) {
  const mode = config.multiplier;
  if (mode === "all") return true;
  const value = multiplierValue(name);
  if (mode === "normal") return value <= 1;
  if (mode === "high") return value > 1;
  const max = mode.match(/^max:(\d+(?:\.\d+)?)$/);
  return !max || value <= Number(max[1]);
}
function log(message) {
  if (config.debug && typeof console !== "undefined" && console.log)
    console.log("[region-rename] " + message);
}
function transformProxy(proxy, index, sourceAirport) {
  const originalName = String(proxy.name || "");
  const reason = clearReason(originalName);
  if (reason) {
    log("DROP " + JSON.stringify(originalName) + " (" + reason + ")");
    return null;
  }
  if (!multiplierAllowed(originalName)) {
    log(
      "DROP " +
        JSON.stringify(originalName) +
        " (multiplier:" +
        config.multiplier +
        ")",
    );
    return null;
  }
  const found = findRegion(originalName);
  if (!found && config.unknown === "drop") {
    log("DROP " + JSON.stringify(originalName) + " (unknown)");
    return null;
  }

  let name = originalName;
  if (found) {
    if (config.format === "compact") {
      name = compactName(originalName, found.region, sourceAirport);
    } else {
      const canonical = outputRegion(found.region);
      name =
        name.slice(0, found.index) +
        canonical +
        name.slice(found.index + found.value.length);
      name = normalizeRegionAliases(name, found.region, canonical, found.index);
      if (config.flag) name = stripFlags(name);
    }
  } else if (config.unknown === "mark") {
    const mark =
      config.out === "en"
        ? "Unknown Region"
        : config.out === "code"
          ? "UN"
          : "未知地区";
    name = mark + config.separator + name;
  }
  if (!(found && config.format === "compact")) {
    name = addPrefix(name, found ? found.region : null, sourceAirport);
  }
  const result = { ...proxy, name };
  if (config.blockQuic === "on") result["block-quic"] = "on";
  if (config.blockQuic === "off") result["block-quic"] = "off";
  log(
    "KEEP " +
      JSON.stringify(originalName) +
      " -> " +
      JSON.stringify(name) +
      (found
        ? " [" + found.alias + " => " + found.region.code + "]"
        : " [unknown]"),
  );
  return {
    proxy: result,
    region: found ? found.region : null,
    regionIndex: found ? found.regionIndex : Number.MAX_SAFE_INTEGER,
    index,
  };
}
function removeSequence(name) {
  return name
    .replace(/(?:\s*[-_|#]\s*|\s+)0\d{1,2}(?=$|[\s\-_|#])/g, "")
    .replace(/(?:\s*[-_|#]\s*|\s+)\d{1,3}\s*$/, "")
    .replace(/([A-Za-z\u4E00-\u9FFF])0\d{1,2}\s*$/, "$1")
    .replace(/\s{2,}/g, " ")
    .trim();
}
function renumber(items) {
  if (config.number === "remove") {
    items.forEach((item) => {
      item.proxy.name = removeSequence(item.proxy.name);
    });
    return items;
  }
  if (config.number !== "region") return items;
  const groups = {};
  items.forEach((item) => {
    const key = item.region ? item.region.code : "__UNKNOWN__";
    (groups[key] || (groups[key] = [])).push(item);
  });
  Object.keys(groups).forEach((key) => {
    const group = groups[key];
    group.forEach((item, index) => {
      const base = removeSequence(item.proxy.name);
      item.proxy.name =
        config.one && group.length === 1
          ? base
          : base + config.separator + String(index + 1).padStart(2, "0");
    });
  });
  return items;
}
function sortItems(items) {
  if (config.sort === "region")
    items.sort((a, b) => a.regionIndex - b.regionIndex || a.index - b.index);
  else if (config.sort === "name") {
    items.sort(
      (a, b) =>
        a.proxy.name.localeCompare(b.proxy.name, "zh-CN") || a.index - b.index,
    );
  }
  return items;
}
function operator(proxies, targetPlatform, context) {
  const stats = {
    input: proxies.length,
    kept: 0,
    dropped: 0,
    matched: 0,
    unknown: 0,
  };
  let items = proxies
    .map((proxy, index) =>
      transformProxy(proxy, index, proxy._subDisplayName || proxy._subName),
    )
    .filter((item) => {
      if (!item) {
        stats.dropped++;
        return false;
      }
      stats.kept++;
      if (item.region) stats.matched++;
      else stats.unknown++;
      return true;
    });
  items = sortItems(renumber(items));
  log("SUMMARY " + JSON.stringify(stats));
  return items.map((item) => item.proxy);
}
