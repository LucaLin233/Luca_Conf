/*
[Script]
flushDNS = type=generic,timeout=10,script-path=https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Surge/flushDNS-zZPiglet.js
// use "icon" and "color" in "argument":
// flushDNS = type=generic,timeout=10,script-path=https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Surge/flushDNS-zZPiglet.js,argument=icon=arrow.clockwise&color=#34C759
[Panel]
flushDNS = script-name=flushDNS,update-interval=-1
*/

!(async () => {
    let dnsCache = ""
    await httpAPI("/v1/dns/flush");
    let delay = ((await httpAPI("/v1/test/dns_delay")).delay * 1000).toFixed(0);
    let panel = {
        title: "刷新DNS缓存",
        content: `delay: ${delay}ms${dnsCache ? `\nserver:\n${dnsCache}` : ""}`,
    };
    if (typeof $argument != "undefined") {
        let arg = Object.fromEntries($argument.split("&").map((item) => item.split("=")));
        panel.icon = arg.icon;
        panel["icon-color"] = arg.color;
    }
    $done(panel);
})();

function httpAPI(path = "", method = "POST", body = null) {
    return new Promise((resolve) => {
        $httpAPI(method, path, body, (result) => {
            resolve(result);
        });
    });
}
