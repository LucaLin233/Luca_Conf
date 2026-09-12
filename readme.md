# Proxy Configs Collection

面向 Surge 与 Quantumult X 的模块、脚本、分流规则与图标集合，纯自用备份。

本仓库只做收集与整合，不维护上游脚本，也不保证可用性。所有文件按“原样”提供，使用前请自行阅读
文件内的说明与参数表。有同步需要请**自行同步，不要 fork**。

## 支持范围

- **Surge（iOS / macOS）**：模块 `surge/modules/*.sgmodule`、脚本 `surge/scripts/*.js`、分流规则 `surge/rules/*.list`；
- **Quantumult X**：重写 `quantumultx/apps_js.conf`、分流规则 `quantumultx/emby.list`；
- **Sub-Store**：`substore/rename.js`，节点名称与地区文案规范化脚本（同目录附测试）；
- **代理服务端**：`systemd/*.service` 单元模板（Snell、Hysteria2，Debian/Ubuntu）；
- **面板脚本**：需要较新的 Surge 版本（模块参数 `#!arguments` 需 Surge 5 及以上）；DeepSeek、CCH、AWS Lightsail、Peekabo 四个面板还需要各自服务的 API Key 或 Token，仅保存在 Surge 本地模块参数中；
- 本仓库**不提供** Quantumult X 的完整配置文件，只提供重写与分流规则；
- 所有文件通过 `raw.githubusercontent.com` 直接引用，仓库不提供额外加速方式。

## 目录结构

```text
Proxy/
├── surge/
│   ├── modules/     Surge 模块（.sgmodule）
│   ├── scripts/     Surge 脚本（.js）
│   ├── rules/       分流规则（.list；legacy/ 为 2022 年遗留版本）
│   └── data/        Telegram MTProto DC 配置
├── quantumultx/     Quantumult X 重写与规则
├── substore/        Sub-Store 脚本
├── icons/           策略组图标
├── docs/            README 引用的教程截图
├── other/           其他文件
├── systemd/         服务端 systemd 单元模板
├── readme.md
├── LICENSE          MIT
└── .gitattributes   统一 LF 换行
```

## 快速开始

### Surge 模块

在 Surge → 模块 → 从 URL 安装，填入对应模块的 raw 地址：

```text
https://raw.githubusercontent.com/LucaLin233/Proxy/main/surge/modules/<模块名>.sgmodule
```

`panels` 模块需要参数（API Key、Token、查询间隔等），安装时按提示填写；参数说明写在模块的
`#!arguments-desc` 中，安装界面可直接看到。需要单独某个面板时，改装对应的独立模块。

### Surge 分流规则

在配置文件的 `[Rule]` 段引用：

```text
RULE-SET,https://raw.githubusercontent.com/LucaLin233/Proxy/main/surge/rules/proxy.list,PROXY
RULE-SET,https://raw.githubusercontent.com/LucaLin233/Proxy/main/surge/rules/direct.list,DIRECT
```

`proxy.list`、`direct.list`、`cdn.list` 由自建合并服务按上游规则定期更新并自动提交，**不要手工
编辑**；其余 `.list` 为手工维护。

### Quantumult X

```text
JS 重写     https://raw.githubusercontent.com/LucaLin233/Proxy/main/quantumultx/apps_js.conf
Emby 分流   https://raw.githubusercontent.com/LucaLin233/Proxy/main/quantumultx/emby.list
```

JS 重写：在“重写 → 引用”中填入链接。

![](https://github.com/LucaLin233/Proxy/blob/main/docs/qx_rewrite_guide.png)

使用前建议先掌握 Quantumult X 的配置导入方式：

- [Quantumult X 教程](https://www.notion.so/Quantumult-X-1d32ddc6e61c4892ad2ec5ea47f00917)（懒人可直接看第五大点的配置导入）；
- [@KOP-XIAO 的懒人配置](https://raw.githubusercontent.com/KOP-XIAO/QuantumultX/master/QuantumultX_Profiles.conf)；
- [@limbopro 的节点筛选正则](https://limbopro.xyz/archives/11131.html)；
- 分流规则推荐 [@blackmatrix7 的规则仓库](https://github.com/blackmatrix7/ios_rule_script)。

上述 Cookie 类重写只用于自用抓取，请勿用于商业化或批量使用。

### Sub-Store

```text
https://raw.githubusercontent.com/LucaLin233/Proxy/main/substore/rename.js
```

脚本按国家/地区字典把节点名称统一为中文或英文短称，作为 Sub-Store 的“节点名称处理”脚本使用。

### 服务端 unit 模板

```bash
sudo cp systemd/snell.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now snell
```

`snell-tun.service` 与 `hysteria2-tun.service` 以 `tun` 用户运行，适合已配置好 TUN 转发的机器；
`snell.service` 以 `nobody` 运行。ExecStart 中的二进制与配置文件路径请按实际部署修改。

## 模块一览

| 模块 | 功能 | 参数 |
| --- | --- | --- |
| `panels.sgmodule` | 汇总面板：功能开关检测、DeepSeek 余额、CCH 配额与调用、AWS Lightsail 流量、Peekabo 流量 | 需要，见模块内 `#!arguments-desc` |
| `deepseek_balance.sgmodule` | DeepSeek API 余额、赠送金额与查询时间；支持查询间隔、低余额提醒、每日日报 | 需要 |
| `cch_monitor.sgmodule` | CCH 供应商额度与今日调用、消费、RPM、并发、错误率、平均响应时间 | 需要 |
| `lightsail_traffic.sgmodule` | AWS Lightsail 当月流量、配额占比与中文地区；支持多区域多实例、用量提醒、每日日报 | 需要 |
| `peekabo_traffic.sgmodule` | Peekabo 已用/总流量、到期日期与剩余时间；支持查询间隔与到期提醒 | 需要 |
| `app_js.sgmodule` | APP JS 重写合集：Netflix 评分与单集评分、淘票票豆瓣评分、TestFlight 账户管理、彩云天气 SVIP | 不需要 |
| `bilibili_cdn.sgmodule` | 哔哩哔哩 CDN 优化 | 不需要 |
| `block_startup.sgmodule` | 开屏与启动广告拦截 | 不需要 |
| `fuck_ad.sgmodule` | 常见 App 广告拦截（by ocd0711） | 不需要 |
| `get_wskey.sgmodule` | 京东 wskey 抓取；使用时先杀掉京东 App 后台再打开 | 不需要 |
| `tun_only.sgmodule` | 仅开启 TUN，便于配合其它工具调试 | 不需要 |

## 脚本一览

| 脚本 | 用途 | 来源 |
| --- | --- | --- |
| `cch_monitor.js` | CCH 配额与调用监控面板 | 自建 |
| `deepseek_balance.js` | DeepSeek 余额信息面板 | 自建 |
| `lightsail_traffic.js` | AWS Lightsail 流量信息面板 | 自建 |
| `peekabo_traffic.js` | Peekabo 流量信息面板 | 自建 |
| `function.js` | Surge 功能开关与运行状态检测面板 | 参考 chaizia/Profiles |
| `ip_check.js` | 当前节点详情面板 | 感谢 @congcong |
| `sub_info.js` | 订阅流量与到期信息面板 | 模板来自 @mieqq |
| `reload.js` | 配置重载面板 | Author: Pysta |
| `rename.js` | 节点名称按地区字典规范化 | 感谢 @bluman / @qwerzl |
| `stream_check.js` | 奈飞、油管解锁检测 | 上游通用脚本 |
| `stream_all.js` | 流媒体全量解锁检测 | 上游通用脚本 |
| `covid19.js` | 疫情数据查询面板（数据源为腾讯新闻接口，可能已停更） | 上游通用脚本 |

`panels` 与四个独立面板模块引用的就是前四个脚本，单独引用脚本时请注意与模块二选一。

## 分流规则一览

| 规则 | 用途 | 维护方 |
| --- | --- | --- |
| `proxy.list` | 需要代理的域名合集（约 2 万条） | 合并服务自动提交 |
| `direct.list` | 直连域名合集（约 14 万条） | 合并服务自动提交 |
| `cdn.list` | CDN 优化分组 | 合并服务自动提交 |
| `telegram.list`、`telegram_ip.list`、`telegram_asn.list` | Telegram 分流（域名、IP、ASN） | 手工维护 |
| `apple_proxy.list`、`apple_proxy_rough.list`、`apple_download.list` | Apple 服务代理与下载直连 | 手工维护 |
| `emby_filter.list` | Emby 服务器分流（Surge 语法） | 手工维护 |
| `uahp_allinone.list` | 去广告与跟踪域名合集（Unbreak 等上游） | 手工维护 |
| `stream.list` | 流媒体域名 | 手工维护 |
| `lan.list`、`stun.list` | 局域网直连、STUN 协议 | 手工维护 |
| `legacy/proxy.list`、`legacy/direct.list` | 2022 年遗留版本，仅存档 | 不再维护 |

`quantumultx/emby.list` 为同一批 Emby 服务器在 Quantumult X 下的版本，覆盖：普拉斯 AGA
（中国电信可直连）、CF 公益服（需挂代理）、普拉斯备用服（4 个）、Exflux、Nexitally/AmyTelecom
（共用，仅限美国特定节点）、Skicat、Godetia（猫熊和 3DM）。

## 图标与文档

- `icons/`：策略组图标，可直接作为 `icon-url` 引用；
- `docs/`：README 引用的 Quantumult X 操作截图，`other/` 内为其它图片。

## 功能重叠与选择

| 想要的 | 用 | 不要同时用 |
| --- | --- | --- |
| 全部面板 | `panels.sgmodule` | 四个独立面板模块 |
| 单个面板 | 对应的独立模块 | `panels.sgmodule` |
| 只做 APP 重写 | `app_js.sgmodule` | 与本仓库其它重写模块重复的部分 |
| Surge 分流 | `surge/rules/*.list` | `quantumultx/emby.list`（语法不同，仅 QX 使用） |

## 高风险与注意事项

- 本仓库只搬运和整合，**不负责维护**上游脚本，也不保证任何脚本的可用性；
- 面板脚本需要填写自己的 API Key / Token，这些参数仅保存在本地模块中，请勿提交到公开仓库；
- 在 App 内抓取 Cookie 的重写仅限自用；账号、Cookie、Token、私钥一律不要粘贴到 issue 或仓库；
- 规则由合并服务自动写回，手工编辑会被下次更新覆盖；
- 部分脚本依赖 Surge 的 HTTP API 或系统版本，升级 Surge 后如有失效请以官方文档为准。

## 反馈与致谢

发现编写错误或有建议欢迎提 issue；**因个人使用方式不当导致的脚本不可用，不予处理**。

脚本引用与整合过程中参考过以下作者的工作：[@sunert](https://github.com/Sunert)、
[@age174](https://github.com/age174)（招招试药）、[@NobyDa](https://github.com/NobyDa)（京东多合一签到）、
[@blackmatrix7](https://github.com/blackmatrix7)（滴滴出行系列）。京东系列脚本可配合
[Hello World 的仓库](https://github.com/JDHelloWorld/jd_scripts) 使用。

特别感谢以下脚本作者，以及整合时参考的作者（排名不分先后，如有遗漏万分抱歉，请联系我加上）：

- **脚本**：[@NobyDa](https://github.com/NobyDa)、[@chavyleung](https://github.com/chavyleung)、[@Sunert](https://github.com/Sunert)、[@lxk0301](https://github.com/lxk0301)、[@blackmatrix7](https://github.com/blackmatrix7)、[@WowYiJiu](https://github.com/WowYiJiu)、[@zhiyi](https://github.com/Ariszy)、@ziye（防止大佬再被封，故不贴出）、[@age174](https://github.com/age174)、[@yangtingxiao](https://github.com/yangtingxiao)、[@ChuheGit](https://github.com/ChuheGit)、[@zZPiglet](https://github.com/zZPiglet)、[@whyour](https://github.com/whyour)、[@mieqq](https://github.com/mieqq)、@bluman / @qwerzl；
- **配置文件**：[@KOP-XIAO](https://github.com/KOP-XIAO)；
- **分流规则**：[@blackmatrix7](https://github.com/blackmatrix7)；
- **图标**：[@shoujiqiyuan](https://github.com/shoujiqiyuan)、[@erdongchanyo](https://github.com/erdongchanyo)、[@Orz-3](https://github.com/Orz-3)、[@ChuheGit](https://github.com/ChuheGit)、@ziye（防止大佬再被封，故不贴出）。

如果这里的说明和整合的脚本对你的使用有帮助，欢迎点个 Star，感激不尽 :gift_heart:

## 许可证与免责声明

本仓库采用 [MIT License](LICENSE)。

- LucaLin233 发布的本仓库中涉及的任何解锁和解密分析脚本仅用于资源共享和学习研究，不能保证其合法性、准确性、完整性和有效性，请根据情况自行判断；
- 间接使用脚本的任何用户，包括但不限于建立 VPS 或在某些行为违反国家/地区法律或相关法规的情况下进行传播，LucaLin233 对于由此引起的任何隐私泄漏或其他后果概不负责；
- 请勿将本仓库内的任何内容用于商业或非法目的，否则后果自负；
- 如果任何单位或个人认为该项目的脚本可能涉嫌侵犯其权利，则应及时通知并提供身份证明、所有权证明，我将在收到认证文件后删除相关脚本；
- LucaLin233 对任何本仓库中包含的脚本在使用中可能出现的问题概不负责，包括但不限于由任何脚本错误导致的任何损失或损害；
- 您必须在下载后的 24 小时内从计算机或手机中完全删除以上内容；
- 任何以任何方式查看此项目的人，或直接或间接使用该项目的任何脚本的使用者，都应仔细阅读此声明。LucaLin233 保留随时更改或补充此免责声明的权利。一旦使用并复制了本仓库相关脚本或其他内容，则视为您已接受此免责声明。
