/**
* Surge 网络信息面板
* 更改自https://github.com/Nebulosa-Cat/Surge/blob/main/Panel/Network-Info/networkCheck.js
* Net Info 面板模块原始作者 @author: Peng-YM
* 感谢聪聪(@congcong)、Pysta(@mieqq)、野比(@NobyDa)、皮乐(@Hiraku)的技术支持
* 以及Z佬(@zZPiglet)精简化code
* 使用方法如下
* [Panel]
* net-info-panel = title="网络状态",content="请刷新",style=info,script-name=net-info-panel, update-interval=1
* [Script]
* net-info-panel = script-path = https://raw.githubusercontent.com/Nebulosa-Cat/Surge/main/Panel/Network-Info/networkCheck.js,type=generic
*/
const { wifi, v4, v6 } = $network;

// No network connection
if (!v4.primaryAddress && !v6.primaryAddress) {
    $done({
      title: '沒有网络',
      content: '尚未连接到网络\n请检查网络状态后重试',
      icon: 'wifi.exclamationmark',
      'icon-color': '#CB1B45',
    });
  }
else{
  $httpClient.get('http://ip-api.com/json', function (error, response, data) {
    const jsonData = JSON.parse(data);
    $done({
      title: wifi.ssid ? wifi.ssid : '移动数据',
      content:
        (v4.primaryAddress ? `IPv4 : ${v4.primaryAddress} \n` : '') +
        (v6.primaryAddress ? `IPv6 : ${v6.primaryAddress}\n`: '') +
        (v4.primaryRouter && wifi.ssid ? `Router IPv4 : ${v4.primaryRouter}\n` : '') +
        (v6.primaryRouter && wifi.ssid ? `Router IPv6 : ${v6.primaryRouter}\n` : '') +
        `节点 IP : ${jsonData.query}\n` +
        `节点 ISP : ${jsonData.isp}\n` +
        `节点位置 : ${getFlagEmoji(jsonData.countryCode)} | ${jsonData.country} - ${jsonData.city}`,
      icon: wifi.ssid ? 'wifi' : 'simcard',
      'icon-color': wifi.ssid ? '#005CAF' : '#F9BF45',
    });
  });
};

function getFlagEmoji(countryCode) {
  const codePoints = countryCode
    .toUpperCase()
    .split('')
    .map((char) => 127397 + char.charCodeAt());
  return String.fromCodePoint(...codePoints);
}
