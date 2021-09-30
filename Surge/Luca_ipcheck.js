/**
* 感谢@congcong大佬提供的js，原文件地址：https://github.com/congcong0806/surge-list/blob/master/Script/ipcheck.js
* 用法
* [Panel]
* #节点检测
* ipcheck = script-name=ipcheck, title="节点信息", content="请刷新", style=info, update-interval=1
* ...
* [Script]
* #节点检测
* ipcheck = type=generic,timeout=5,script-path=https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Surge/Luca_ipcheck.js
*/

let url = "http://ip-api.com/json/?lang=zh-CN"

$httpClient.get(url, function(error, response, data){
    let jsonData = JSON.parse(data)
    let ip = jsonData.query
    let country = jsonData.country
    let emoji = getFlagEmoji(jsonData.countryCode)
    let city = jsonData.city
    let isp = jsonData.isp
  body = {
    title: "节点信息",
    content: `IP: ${ip}\n服务商: ${isp}\n位置: ${emoji}${country}-${city}`,
    icon: "network"
  }
  $done(body);
});


function getFlagEmoji(countryCode) {
    const codePoints = countryCode
      .toUpperCase()
      .split('')
      .map(char =>  127397 + char.charCodeAt());
    return String.fromCodePoint(...codePoints);
}
