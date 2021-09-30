$httpClient.get("http://ip-api.com/json", function(error, response, data){
    let jsonData = JSON.parse(data)
    let ip = jsonData.query
    let country = jsonData.country
    let emoji = getFlagEmoji(jsonData.countryCode)
    let city = jsonData.city
    let isp = jsonData.isp
	$done({
		title: "网络信息",
		content: `IP: ${ip}\nISP: ${isp}\n位置: ${emoji}${country} - ${city}`,
        icon: "network"
	});
});

function getFlagEmoji(countryCode) {
    const codePoints = countryCode
      .toUpperCase()
      .split('')
      .map(char =>  127397 + char.charCodeAt());
    return String.fromCodePoint(...codePoints);
}