/**
* 感谢@congcong大佬提供的js，原文件地址：https://github.com/congcong0806/surge-list/blob/master/Script/ipcheck.js
* 用法
* [Panel]
* #节点检测
* ipcheck = script-name=ipcheck, title="节点信息", content="请刷新", style=info, update-interval=1
* ...
* [Script]
* #节点检测
* ipcheck = type=generic,timeout=3,script-path=https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Surge/ipcheck.js
*/

let url = "http://ip-api.com/json/?lang=zh-CN"
let group = (await httpAPI("/v1/policy_groups/select?group_name=手动选择")).policy;
let name = (await httpAPI("/v1/policy_groups/select?group_name="+group+"")).policy;

$httpClient.get(url, function(error, response, data){
    let jsonData = JSON.parse(data)
    let country = jsonData.country
    let emoji = getFlagEmoji(jsonData.countryCode)
    let city = jsonData.city
    let isp = jsonData.isp
    let org =jsonData.org
  body = {
    title: "节点相关信息",
    content: `地理位置: ${emoji}${country} - ${city}\n运营商家: ${isp}\n数据中心: ${org}`,
    icon: "globe.asia.australia.fill"
  }
  $done(body);
});

function httpAPI(path = "", method = "GET", body = null) {
    return new Promise((resolve) => {
        $httpAPI(method, path, body, (result) => {
            resolve(result);
        });
    });
};

function getFlagEmoji(countryCode) {
    const codePoints = countryCode
      .toUpperCase()
      .split('')
      .map(char =>  127397 + char.charCodeAt());
    return String.fromCodePoint(...codePoints);
}
