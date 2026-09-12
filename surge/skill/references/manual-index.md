# Surge 官方配置手册索引

本参考补充官方 Surge Skill 仅附带 CLI/Controller 命令参考、未附带完整配置语法手册的问题。

## 权威来源与查阅顺序

1. 配置文件、模块、规则、代理协议和策略组语法：查阅 [Surge Manual](https://manual.nssurge.com/)。
2. `surge-cli` / Controller 命令、参数和响应：查阅本 Skill 的 [Command Reference](command-reference.md)。
3. 若保存的具体页面失效，从手册首页或侧栏目录重新定位；不要猜测 URL，也不要先用搜索引擎摘要代替官方正文。
- If local validation with the bundled Surge parser is unavailable (for example iSH), the Minis `surge-cli --check <path>` implementation uses Surge's official beta HTTPS validation service. This uploads the explicitly named file; use a redacted copy when the profile contains credentials, subscription URLs, or private server details.
- To validate locally without uploading and an installed Mac is available, use the official parser:

```sh
/Applications/Surge.app/Contents/Applications/surge-cli --check /path/to/profile.conf
```

校验副本时不得把真实密码、PSK、订阅 URL、API Key 或其他凭据复制到不受控位置；优先使用占位值验证结构。

## 常用配置入口

### Profile

- [Profile Format](https://manual.nssurge.com/profile/format.html)
- [Requirement Expressions](https://manual.nssurge.com/profile/requirement.html) — iOS 5.22.0 / Mac 6.9.0 起支持 `DEVICE_NAME`
- [General Section Options](https://manual.nssurge.com/profile/general.html)
- [Module](https://manual.nssurge.com/profile/module.html)
- [Managed Profile](https://manual.nssurge.com/profile/managed-profile.html)
- [Keystore](https://manual.nssurge.com/profile/keystore.html)

### 正式版 5.22.0 Profile 变化

- `#!REQUIREMENT` 官方变量现包括 `DEVICE_NAME`（iOS 5.22.0+ / Mac 6.9.0+）；它是用户设置的设备名称，Privacy Mode 下读取结果可能被遮蔽。
- `#include` 可与 section 内普通内容混排；多个或混合 include 因写回目标不明确会在 UI 中只读。
- `[Ruleset *]`、`[WireGuard *]`、`[Tailscale *]` detached sections 支持通配 include。
- inline Ruleset 可引用其他 inline Ruleset，也可引用外部 `RULE-SET` / `DOMAIN-SET`；循环引用会被拒绝并给出引用链。
- Event scripts 新增 `engine-started` 与 `profile-reloaded` 事件。

具体语法以相应官方手册正文和 `surge-cli --check` 结果为准，不根据发布说明猜测配置格式。

### 规则

- [Rule System Overview](https://manual.nssurge.com/rules/overview.html)
- [Domain Rules](https://manual.nssurge.com/rules/domain.html)
- [IP Rules](https://manual.nssurge.com/rules/ip.html)
- [Protocol and Network Rules](https://manual.nssurge.com/rules/protocol-and-network.html)
- [Logical Rules](https://manual.nssurge.com/rules/logical.html)
- [Rule Sets](https://manual.nssurge.com/rules/ruleset.html)

### 代理策略与协议

- [Policy Overview](https://manual.nssurge.com/policies/overview.html)
- [Common Policy Parameters](https://manual.nssurge.com/policies/parameters.html) — 包含 `underlying-proxy` 代理链
- [TLS and Shadow TLS](https://manual.nssurge.com/policies/tls.html)
- [UDP Relay](https://manual.nssurge.com/policies/udp.html)
- [HTTP and HTTP/2](https://manual.nssurge.com/policies/http.html)
- [SOCKS5](https://manual.nssurge.com/policies/socks5.html)
- [Shadowsocks](https://manual.nssurge.com/policies/shadowsocks.html)
- [Snell](https://manual.nssurge.com/policies/snell.html)
- [VMess](https://manual.nssurge.com/policies/vmess.html)
- [Trojan](https://manual.nssurge.com/policies/trojan.html)
- [TUIC](https://manual.nssurge.com/policies/tuic.html)
- [Hysteria 2](https://manual.nssurge.com/policies/hysteria2.html)
- [WireGuard](https://manual.nssurge.com/policies/wireguard.html)
- [Tailscale](https://manual.nssurge.com/policies/tailscale.html)

### 策略组

- [Policy Group Overview](https://manual.nssurge.com/policy-groups/overview.html)
- [Manual Selection Group](https://manual.nssurge.com/policy-groups/select.html)
- [Automatic Testing Group](https://manual.nssurge.com/policy-groups/url-test.html)
- [Smart Group](https://manual.nssurge.com/policy-groups/smart.html)
- [Policy Including](https://manual.nssurge.com/policy-groups/policy-including.html)
- [Common Group Parameters](https://manual.nssurge.com/policy-groups/parameters.html)

### DNS、HTTP 与脚本

- [DNS Overview](https://manual.nssurge.com/dns/overview.html)
- [HTTP Processing Overview](https://manual.nssurge.com/http/overview.html)
- [HTTPS Decryption (MITM)](https://manual.nssurge.com/http/mitm.html)
- [URL Rewrite](https://manual.nssurge.com/http/url-rewrite.html)
- [Scripting Overview](https://manual.nssurge.com/scripting/overview.html)
- [JavaScript API Reference](https://manual.nssurge.com/scripting/api.html)

### 工具与远程控制

- [Surge Mac CLI](https://manual.nssurge.com/tools/cli.html)
- [HTTP API](https://manual.nssurge.com/tools/http-api.html)
- [Dashboard and Remote Access](https://manual.nssurge.com/tools/dashboard.html)
- [Testing](https://manual.nssurge.com/tools/testing.html)
