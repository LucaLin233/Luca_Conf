# Official source routing for Surge iOS and macOS

Always begin with the user's supplied `llms.txt` when present. It is a routing file, not the full documentation.

## Source order

Choose sources by active platform, then recency:

1. Surge iOS release notes for stable iOS changes:
   https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/surge-ios.md
2. Surge iOS TestFlight notes for beta-only questions:
   https://kb.nssurge.com/surge-knowledge-base/zh/faq/ios-testflight.md
3. Surge Manual for normative syntax and behavior:
   https://manual.nssurge.com/llms.txt
4. Surge Mac release/beta appcast for explicit Mac version questions:
   https://nssurge.com/mac/latest/appcast-signed-beta.xml
5. Surge Knowledge Base for user workflows and troubleshooting:
   https://kb.nssurge.com/llms.txt

The Mac appcast is not authority for an iOS-only capability. Use it only in macOS mode or when another official source confirms that a shared-core change applies to iOS.

## High-value manual pages

- Platform differences: https://manual.nssurge.com/getting-started/platform-differences.md
- Quick start: https://manual.nssurge.com/getting-started/quick-start.md
- Profile format: https://manual.nssurge.com/profile/format.md
- General section: https://manual.nssurge.com/profile/general.md
- Modules: https://manual.nssurge.com/profile/module.md
- Requirements: https://manual.nssurge.com/profile/requirement.md
- Rule overview: https://manual.nssurge.com/rules/overview.md
- Policy overview: https://manual.nssurge.com/policies/overview.md
- Policy groups: https://manual.nssurge.com/policy-groups/overview.md
- DNS: https://manual.nssurge.com/dns/overview.md
- MITM: https://manual.nssurge.com/http/mitm.md
- Scripting: https://manual.nssurge.com/scripting/overview.md
- HTTP API: https://manual.nssurge.com/tools/http-api.md
- URL scheme: https://manual.nssurge.com/tools/url-scheme.md
- Surge CLI: https://manual.nssurge.com/tools/cli.md
- Surge CLI update overview: https://nssurge.com/blog/surge-cli-updates/
- Beta CLI announcements: https://t.me/SurgeTestFlight

## Source discipline

- Fetch only pages needed for the current question.
- Prefer Markdown endpoints.
- Record the source URL for claims that are version-sensitive or easy to misread.
- If a release note conflicts with the manual for the same iOS version, follow the release note and explain the discrepancy.
- If only a Mac release note documents a feature, do not assert iOS support without iOS or shared-core evidence.
