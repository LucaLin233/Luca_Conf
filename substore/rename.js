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
 * number=remove 会清理名称中的 01/001 类零填充序号，以及 #1/节点1 类明确序号。
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
 *   provider=auto|off           自动提取尾部服务商短语，DP V 类名称会整体保留，默认 auto
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
  "套餐", "到期", "有效期", "剩余", "已用", "过期", "失联", "测试",
  "官方", "网址", "客服", "网站", "获取订阅", "流量", "下次", "官址",
  "联系", "邮箱", "工单",
];
const DEFAULT_CLEAR_WORD_RE = /\b(?:USE|USED|TOTAL|EXPIRE|EMAIL)\b/i;
const REGION_ROWS = [
  ["HK","香港","Hong Kong",["Hong Kong","Hongkong","Hong Kong SAR","HKG","港","深港","沪港","呼港","京港","广港","杭港"],["九龙","九龙城","Kowloon"]],
  ["MO","澳门","Macao",["Macao","Macau","Macao SAR"],[]],
  ["TW","台湾","Taiwan",["Taiwan","台灣","Taiwan China"],["台北","新北","高雄","臺北","Taipei","Kaohsiung"]],
  ["JP","日本","Japan",["Japan"],["东京","大阪","大坂","名古屋","Tokyo","Osaka","Nagoya"]],
  ["KR","韩国","South Korea",["Korea","Republic of Korea"],["首尔","首爾","春川","釜山","Seoul","Chuncheon","Busan"]],
  ["SG","新加坡","Singapore",["Singapore"],["狮城","獅城"]],
  ["US","美国","United States",["United States","USA","U.S.A.","America"],["洛杉矶","洛杉磯","纽约","紐約","硅谷","矽谷","西雅图","西雅圖","芝加哥","圣何塞","波特兰","Los Angeles","New York","Silicon Valley","San Jose","Seattle","Chicago","Portland","Michigan"]],
  ["GB","英国","United Kingdom",["United Kingdom","UK","U.K.","Great Britain","Britain"],["伦敦","倫敦","London"]],
  ["FR","法国","France",["France"],["巴黎","Paris"]],
  ["DE","德国","Germany",["Germany"],["法兰克福","法蘭克福","Frankfurt"]],
  ["AU","澳大利亚","Australia",["Australia"],["悉尼","墨尔本","墨爾本","Sydney","Melbourne"]],
  ["AE","阿联酋","United Arab Emirates",["Dubai","UAE","阿拉伯联合酋长国"],["迪拜","Dubai","Abu Dhabi"]],
  ["AF","阿富汗","Afghanistan",["Afghanistan"],[]],
  ["AL","阿尔巴尼亚","Albania",["Albania"],[]],
  ["DZ","阿尔及利亚","Algeria",["Algeria"],[]],
  ["AO","安哥拉","Angola",["Angola"],[]],
  ["AR","阿根廷","Argentina",["Argentina"],[]],
  ["AM","亚美尼亚","Armenia",["Armenia"],[]],
  ["AT","奥地利","Austria",["Austria"],[]],
  ["AZ","阿塞拜疆","Azerbaijan",["Azerbaijan"],[]],
  ["BH","巴林","Bahrain",["Bahrain"],[]],
  ["BD","孟加拉国","Bangladesh",["Bangladesh"],[]],
  ["BY","白俄罗斯","Belarus",["Belarus"],[]],
  ["BE","比利时","Belgium",["Belgium"],[]],
  ["BZ","伯利兹","Belize",["Belize"],[]],
  ["BJ","贝宁","Benin",["Benin"],[]],
  ["BT","不丹","Bhutan",["Bhutan"],[]],
  ["BO","玻利维亚","Bolivia",["Bolivia","Bolivia Plurinational State"],[]],
  ["BA","波斯尼亚和黑塞哥维那","Bosnia and Herzegovina",["Bosnia and Herzegovina"],[]],
  ["BW","博茨瓦纳","Botswana",["Botswana"],[]],
  ["BR","巴西","Brazil",["Brazil"],[]],
  ["VG","英属维京群岛","British Virgin Islands",["British Virgin Islands"],[]],
  ["BN","文莱","Brunei",["Brunei","Brunei Darussalam"],[]],
  ["BG","保加利亚","Bulgaria",["Bulgaria"],[]],
  ["BF","布基纳法索","Burkina Faso",["Burkina-faso"],[]],
  ["BI","布隆迪","Burundi",["Burundi"],[]],
  ["KH","柬埔寨","Cambodia",["Cambodia"],[]],
  ["CM","喀麦隆","Cameroon",["Cameroon"],[]],
  ["CA","加拿大","Canada",["Canada"],["多伦多","多倫多","温哥华","溫哥華","蒙特利尔","Toronto","Vancouver","Montreal"]],
  ["CV","佛得角","Cape Verde",["CapeVerde"],[]],
  ["KY","开曼群岛","Cayman Islands",["CaymanIslands"],[]],
  ["CF","中非共和国","Central African Republic",["Central African Republic"],[]],
  ["TD","乍得","Chad",["Chad"],[]],
  ["CL","智利","Chile",["Chile"],[]],
  ["CO","哥伦比亚","Colombia",["Colombia"],[]],
  ["KM","科摩罗","Comoros",["Comoros"],[]],
  ["CG","刚果(布)","Congo-Brazzaville",["Congo-Brazzaville"],[]],
  ["CD","刚果(金)","Congo-Kinshasa",["Congo-Kinshasa"],[]],
  ["CR","哥斯达黎加","Costa Rica",["CostaRica"],[]],
  ["HR","克罗地亚","Croatia",["Croatia"],[]],
  ["CY","塞浦路斯","Cyprus",["Cyprus"],[]],
  ["CZ","捷克","Czech Republic",["Czech Republic","Czechia"],[]],
  ["DK","丹麦","Denmark",["Denmark"],[]],
  ["DJ","吉布提","Djibouti",["Djibouti"],[]],
  ["DO","多米尼加共和国","Dominican Republic",["Dominican Republic"],[]],
  ["EC","厄瓜多尔","Ecuador",["Ecuador"],[]],
  ["EG","埃及","Egypt",["Egypt"],[]],
  ["SV","萨尔瓦多","El Salvador",["EISalvador"],[]],
  ["GQ","赤道几内亚","Equatorial Guinea",["Equatorial Guinea"],[]],
  ["ER","厄立特里亚","Eritrea",["Eritrea"],[]],
  ["EE","爱沙尼亚","Estonia",["Estonia"],[]],
  ["ET","埃塞俄比亚","Ethiopia",["Ethiopia"],[]],
  ["FJ","斐济","Fiji",["Fiji"],[]],
  ["FI","芬兰","Finland",["Finland"],[]],
  ["GA","加蓬","Gabon",["Gabon"],[]],
  ["GM","冈比亚","Gambia",["Gambia"],[]],
  ["GE","格鲁吉亚","Georgia",["Georgia"],[]],
  ["GH","加纳","Ghana",["Ghana"],[]],
  ["GR","希腊","Greece",["Greece"],[]],
  ["GL","格陵兰","Greenland",["Greenland"],[]],
  ["GT","危地马拉","Guatemala",["Guatemala"],[]],
  ["GN","几内亚","Guinea",["Guinea"],[]],
  ["GY","圭亚那","Guyana",["Guyana"],[]],
  ["HT","海地","Haiti",["Haiti"],[]],
  ["HN","洪都拉斯","Honduras",["Honduras"],[]],
  ["HU","匈牙利","Hungary",["Hungary"],[]],
  ["IS","冰岛","Iceland",["Iceland"],[]],
  ["IN","印度","India",["India"],["孟买","孟買","Mumbai"]],
  ["ID","印尼","Indonesia",["Indonesia"],["雅加达","雅加達","Jakarta"]],
  ["IR","伊朗","Iran",["Iran","Iran Islamic Republic"],[]],
  ["IQ","伊拉克","Iraq",["Iraq"],[]],
  ["IE","爱尔兰","Ireland",["Ireland"],[]],
  ["IM","马恩岛","Isle of Man",["Isle of Man"],[]],
  ["IL","以色列","Israel",["Israel"],[]],
  ["IT","意大利","Italy",["Italy"],[]],
  ["CI","科特迪瓦","Ivory Coast",["Ivory Coast"],[]],
  ["JM","牙买加","Jamaica",["Jamaica"],[]],
  ["JO","约旦","Jordan",["Jordan"],[]],
  ["KZ","哈萨克斯坦","Kazakhstan",["Kazakstan"],[]],
  ["KE","肯尼亚","Kenya",["Kenya"],[]],
  ["KW","科威特","Kuwait",["Kuwait"],[]],
  ["KG","吉尔吉斯斯坦","Kyrgyzstan",["Kyrgyzstan"],[]],
  ["LA","老挝","Laos",["Laos","Lao PDR"],[]],
  ["LV","拉脱维亚","Latvia",["Latvia"],[]],
  ["LB","黎巴嫩","Lebanon",["Lebanon"],[]],
  ["LS","莱索托","Lesotho",["Lesotho"],[]],
  ["LR","利比里亚","Liberia",["Liberia"],[]],
  ["LY","利比亚","Libya",["Libya"],[]],
  ["LT","立陶宛","Lithuania",["Lithuania"],[]],
  ["LU","卢森堡","Luxembourg",["Luxembourg"],[]],
  ["MK","马其顿","North Macedonia",["Macedonia"],[]],
  ["MG","马达加斯加","Madagascar",["Madagascar"],[]],
  ["MW","马拉维","Malawi",["Malawi"],[]],
  ["MY","马来","Malaysia",["Malaysia"],["吉隆坡","Kuala Lumpur"]],
  ["MV","马尔代夫","Maldives",["Maldives"],[]],
  ["ML","马里","Mali",["Mali"],[]],
  ["MT","马耳他","Malta",["Malta"],[]],
  ["MR","毛利塔尼亚","Mauritania",["Mauritania"],[]],
  ["MU","毛里求斯","Mauritius",["Mauritius"],[]],
  ["MX","墨西哥","Mexico",["Mexico"],[]],
  ["MD","摩尔多瓦","Moldova",["Moldova","Moldova Republic"],[]],
  ["MC","摩纳哥","Monaco",["Monaco"],[]],
  ["MN","蒙古","Mongolia",["Mongolia"],[]],
  ["ME","黑山共和国","Montenegro",["Montenegro"],[]],
  ["MA","摩洛哥","Morocco",["Morocco"],[]],
  ["MZ","莫桑比克","Mozambique",["Mozambique"],[]],
  ["MM","缅甸","Myanmar",["Myanmar(Burma)"],[]],
  ["NA","纳米比亚","Namibia",["Namibia"],[]],
  ["NP","尼泊尔","Nepal",["Nepal"],[]],
  ["NL","荷兰","Netherlands",["Netherlands"],["阿姆斯特丹","Amsterdam"]],
  ["NZ","新西兰","New Zealand",["New Zealand"],[]],
  ["NI","尼加拉瓜","Nicaragua",["Nicaragua"],[]],
  ["NE","尼日尔","Niger",["Niger"],[]],
  ["NG","尼日利亚","Nigeria",["Nigeria"],[]],
  ["KP","朝鲜","North Korea",["NorthKorea","DPRK"],[]],
  ["NO","挪威","Norway",["Norway"],[]],
  ["OM","阿曼","Oman",["Oman"],[]],
  ["PK","巴基斯坦","Pakistan",["Pakistan"],[]],
  ["PA","巴拿马","Panama",["Panama"],[]],
  ["PY","巴拉圭","Paraguay",["Paraguay"],[]],
  ["PE","秘鲁","Peru",["Peru"],[]],
  ["PH","菲律宾","Philippines",["Philippines"],["马尼拉","馬尼拉","Manila"]],
  ["PT","葡萄牙","Portugal",["Portugal"],[]],
  ["PR","波多黎各","Puerto Rico",["PuertoRico"],[]],
  ["QA","卡塔尔","Qatar",["Qatar"],[]],
  ["RO","罗马尼亚","Romania",["Romania"],[]],
  ["RU","俄罗斯","Russia",["Russia","Russian Federation"],["莫斯科","Moscow"]],
  ["RW","卢旺达","Rwanda",["Rwanda"],[]],
  ["SM","圣马力诺","San Marino",["SanMarino"],[]],
  ["SA","沙特阿拉伯","Saudi Arabia",["SaudiArabia"],[]],
  ["SN","塞内加尔","Senegal",["Senegal"],[]],
  ["RS","塞尔维亚","Serbia",["Serbia"],[]],
  ["SL","塞拉利昂","Sierra Leone",["SierraLeone"],[]],
  ["SK","斯洛伐克","Slovakia",["Slovakia"],[]],
  ["SI","斯洛文尼亚","Slovenia",["Slovenia"],[]],
  ["SO","索马里","Somalia",["Somalia"],[]],
  ["ZA","南非","South Africa",["SouthAfrica"],[]],
  ["ES","西班牙","Spain",["Spain"],[]],
  ["LK","斯里兰卡","Sri Lanka",["SriLanka"],[]],
  ["SD","苏丹","Sudan",["Sudan"],[]],
  ["SR","苏里南","Suriname",["Suriname"],[]],
  ["SZ","斯威士兰","Swaziland",["Swaziland"],[]],
  ["SE","瑞典","Sweden",["Sweden"],[]],
  ["CH","瑞士","Switzerland",["Switzerland"],["苏黎世","蘇黎世","Zurich"]],
  ["SY","叙利亚","Syria",["Syria","Syrian Arab Republic"],[]],
  ["TJ","塔吉克斯坦","Tajikistan",["Tajikstan"],[]],
  ["TZ","坦桑尼亚","Tanzania",["Tanzania","Tanzania United Republic"],[]],
  ["TH","泰国","Thailand",["Thailand"],["曼谷","Bangkok"]],
  ["TG","多哥","Togo",["Togo"],[]],
  ["TO","汤加","Tonga",["Tonga"],[]],
  ["TT","特立尼达和多巴哥","Trinidad and Tobago",["TrinidadandTobago"],[]],
  ["TN","突尼斯","Tunisia",["Tunisia"],[]],
  ["TR","土耳其","Turkey",["Turkey"],["伊斯坦布尔","伊斯坦堡","Istanbul"]],
  ["TM","土库曼斯坦","Turkmenistan",["Turkmenistan"],[]],
  ["VI","美属维尔京群岛","U.S.Virgin Islands",["U.S.Virgin Islands"],[]],
  ["UG","乌干达","Uganda",["Uganda"],[]],
  ["UA","乌克兰","Ukraine",["Ukraine"],[]],
  ["UY","乌拉圭","Uruguay",["Uruguay"],[]],
  ["UZ","乌兹别克斯坦","Uzbekistan",["Uzbekistan"],[]],
  ["VE","委内瑞拉","Venezuela",["Venezuela","Venezuela Bolivarian Republic"],[]],
  ["VN","越南","Vietnam",["Vietnam","Viet Nam"],["胡志明","河内","河內","Ho Chi Minh","Hanoi"]],
  ["YE","也门","Yemen",["Yemen"],[]],
  ["ZM","赞比亚","Zambia",["Zambia"],[]],
  ["ZW","津巴布韦","Zimbabwe",["Zimbabwe"],[]],
  ["AD","安道尔","Andorra",["Andorra"],[]],
  ["RE","留尼汪","Reunion",["Reunion"],[]],
  ["PL","波兰","Poland",["Poland"],[]],
  ["GU","关岛","Guam",["Guam"],[]],
  ["VA","梵蒂冈","Vatican City",["Vatican"],[]],
  ["LI","列支敦士登","Liechtenstein",["Liechtensteins"],[]],
  ["CW","库拉索","Curacao",["Curacao"],[]],
  ["SC","塞舌尔","Seychelles",["Seychelles"],[]],
  ["AQ","南极","Antarctica",["Antarctica"],[]],
  ["GI","直布罗陀","Gibraltar",["Gibraltar"],[]],
  ["CU","古巴","Cuba",["Cuba"],[]],
  ["FO","法罗群岛","Faroe Islands",["Faroe Islands"],[]],
  ["AX","奥兰群岛","Aland Islands",["Ahvenanmaa"],[]],
  ["BM","百慕达","Bermuda",["Bermuda"],[]],
  ["TL","东帝汶","Timor-Leste",["Timor-Leste"],[]],
  ["CN","中国","China",["中国大陆","大陆","Mainland China","PRC"],["北京","上海","广州","深圳","杭州","成都","重庆","Beijing","Shanghai","Guangzhou","Shenzhen"]],
];
function codeToFlag(code) {
  return [...code].map((char) => String.fromCodePoint(char.charCodeAt(0) + 127397)).join("");
}
function uniqueSorted(values, filterShort = false) {
  return [...new Set(values.filter((value) =>
    value && (!filterShort || value.length > 1 || /^[A-Za-z0-9]{2,}$/.test(value)),
  ))].sort((a, b) => b.length - a.length);
}
const REGIONS = REGION_ROWS.map(([code, zh, en, aliases, cities]) => {
  const inputFlag = codeToFlag(code);
  const core = uniqueSorted([zh, en, code, ...aliases], true);
  const cityAliases = config.city ? cities : [];
  return {
    code, zh, en, inputFlag,
    flag: code === "TW" ? "🇨🇳" : inputFlag,
    coreAliases: core,
    matchAliases: [...new Set([zh, en, code, inputFlag, ...aliases, ...cityAliases])],
  };
});
const FLAG_RE = /(?:[\uD83C][\uDDE6-\uDDFF]){2}/g;

function escapeRegExp(value) {
  return value.replace(/[.*+?^$(){}|[\]\\]/g, "\\$&");
}
const ALIAS_REGEX_CACHE = new Map();
function aliasRegExp(alias, global = false) {
  const cacheKey = alias + (global ? "\u0000g" : "");
  if (ALIAS_REGEX_CACHE.has(cacheKey)) return ALIAS_REGEX_CACHE.get(cacheKey);
  const escaped = escapeRegExp(alias);
  let pattern;
  if (/^[A-Za-z0-9][A-Za-z0-9 .'-]*$/.test(alias)) {
    pattern = "(^|[^A-Za-z0-9])(" + escaped + ")(?=$|[^A-Za-z0-9])";
  } else if (/^[\u3400-\u9FFF]$/.test(alias)) {
    pattern = "(^|[^A-Za-z0-9\\u3400-\\u9FFF])(" + escaped + ")(?=$|[^A-Za-z\\u3400-\\u9FFF])";
  } else {
    pattern = "(" + escaped + ")";
  }
  const regex = new RegExp(pattern, global ? "gi" : "i");
  ALIAS_REGEX_CACHE.set(cacheKey, regex);
  return regex;
}
function buildMatchers() {
  const matchers = [];
  REGIONS.forEach((region, regionIndex) => {
    region.matchAliases.forEach((alias) => {
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
  region.coreAliases.forEach((alias) => {
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
function contextAirportName(context) {
  const source = context && context.source;
  if (!source || typeof source !== "object") return "";
  const keys = Object.keys(source).filter((key) => key && !key.startsWith("_") && key !== "$file");
  if (keys.length !== 1) return "";
  const sub = source[keys[0]] || {};
  return cleanAirportName(sub.displayName) || cleanAirportName(sub.name) || cleanAirportName(keys[0]);
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
function providerTail(name, region) {
  let lastEnd = -1;
  region.matchAliases.forEach((alias) => {
    const regex = aliasRegExp(alias, true);
    regex.lastIndex = 0;
    let match;
    while ((match = regex.exec(name))) {
      const value = match[2] !== undefined ? match[2] : match[1];
      const prefixLength = match[2] !== undefined ? match[1].length : 0;
      lastEnd = Math.max(lastEnd, match.index + prefixLength + value.length);
    }
  });
  return lastEnd < 0 ? name : name.slice(lastEnd);
}
function extractProvider(name, region, airport) {
  if (config.provider === "off") return "";
  const explicit = config.providerKeys.find((key) =>
    name.toLowerCase().includes(key.toLowerCase()),
  );
  if (explicit) return explicit;

  const text = providerTail(name, region)
    .replace(FLAG_RE, " ")
    .replace(/「[^」]*」|『[^』]*』|【[^】]*】|\[[^\]]*\]/g, " ")
    .replace(/[\-_|/\\,:;·•]+/g, " ");
  const airportLower = airport.toLowerCase();
  const drop = new Set(config.dropKeys.map((key) => key.toLowerCase()));
  const tokens = text.split(/\s+/).map((token) => token.trim()).filter(Boolean).filter((token) => {
    const lower = token.toLowerCase();
    return lower !== airportLower && !PROVIDER_NOISE.has(lower) && !drop.has(lower) &&
      !/^\d{1,4}$/.test(token) && !/^\d+(?:\.\d+)?(?:x|×|倍)$/i.test(token);
  });
  if (tokens.length > 1 && tokens[0].toLowerCase() === "bgp") tokens.shift();
  return tokens.join(" ");
}
function extractSequence(name) {
  const trailing = name.match(/(?:^|[\s\-_|#])(\d{1,3})\s*$/);
  if (trailing) return trailing[1];
  const standalone = name.match(/(?:^|[\s\-_|#])(0\d{1,2})(?=$|[\s\-_|#])/);
  if (standalone) return standalone[1];
  const attached = name.match(/[A-Za-z\u3400-\u9FFF](0\d{1,2})\s*$/);
  return attached ? attached[1] : "";
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
  if (config.number === "off") {
    const sequence = extractSequence(originalName);
    if (sequence) parts.push(sequence);
  }
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
    const key = DEFAULT_CLEAR_KEYS.find((item) => contains(name, item));
    if (key) return "clear:" + key;
    const word = name.match(DEFAULT_CLEAR_WORD_RE);
    if (word) return "clear:" + word[0];
    const custom = config.clearKeys.find((item) => contains(name, item));
    if (custom) return "clear:" + custom;
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
    .replace(/(?:\s*(?:#|节点|Node)\s*)\d{1,3}\s*$/i, "")
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
      const base = removeSequence(item.proxy.name)
        .replace(/(?:\s*[-_|#]\s*|\s+)\d{1,3}\s*$/, "")
        .trim();
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
  const fallbackAirport = contextAirportName(context);
  const stats = {
    input: proxies.length,
    kept: 0,
    dropped: 0,
    matched: 0,
    unknown: 0,
  };
  let items = proxies
    .map((proxy, index) =>
      transformProxy(
        proxy,
        index,
        cleanAirportName(proxy._subDisplayName) || cleanAirportName(proxy._subName) || fallbackAirport,
      ),
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
