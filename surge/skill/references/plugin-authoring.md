# Surge Plugin Authoring Guide

This guide explains how to write, test, and distribute a Surge plugin. Plugins
are JavaScript extensions installed and managed by Surge, independent of the
main configuration profile. Each plugin provides exactly one plugin type; the
only type available today is `ap-controller` (macOS only), which integrates a
Wi-Fi access point controller so Surge's device panel can show wireless details
for LAN devices and reconnect clients.

## 1. Package Layout

A plugin is a directory (during development) or a zip (for distribution) with a
fixed layout:

```
manifest.json    plugin metadata and parameter schema
main.js          the single entry script (≤ 2 MB)
icon.png         256×256 PNG, required
```

- `main.js` is the only script Surge loads. If you develop in multiple files or
  TypeScript, bundle to a single `main.js` with a bundler such as esbuild or
  rollup.
- `icon.png` must be exactly 256×256. Installation and validation fail without
  it.
- Other resource files may be present but are not readable from the script.

## 2. manifest.json

```json
{
  "manifest_version": 1,
  "id": "com.example.myrouter-apc",
  "name": "MyRouter AP Controller",
  "version": "1.0.0",
  "description": "Integrates MyRouter controllers.",
  "author": "Example Inc.",
  "homepage": "https://example.com/surge-plugin",
  "type": "ap-controller",
  "supports_validation": true,
  "parameters": [
    {
      "key": "host",
      "type": "url",
      "label": "Controller URL",
      "description": "The base URL of the controller's management interface.",
      "required": true,
      "placeholder": "https://192.168.1.1"
    },
    {
      "key": "token",
      "type": "string",
      "label": "API Token",
      "required": true
    }
  ]
}
```

Field reference:

| Field | Required | Meaning |
|---|---|---|
| `manifest_version` | yes | Always `1`. |
| `id` | yes | Reverse-DNS identifier (letters, digits, hyphens, at least one dot). Permanent: changing it makes a different plugin. |
| `name` | yes | Display name. String, or a localization object such as `{"en": "...", "zh-Hans": "..."}`. |
| `version` | yes | `x`, `x.y`, or `x.y.z`; each component 0–999. Drives update checks. |
| `type` | yes | The plugin type. Currently only `ap-controller`. |
| `description` | no | Shown in plugin lists. Localizable. |
| `author`, `homepage` | no | Shown in plugin info. |
| `min_core_version` | no | Minimum Surge core version (`x.y.z`). Installation is refused on older cores. |
| `min_api_version` | no | Minimum plugin API version. The current API version is `1` (the default). |
| `supports_validation` | no | Set `true` if `main.js` handles the `system.validate` event; Surge then verifies parameters before saving them. |
| `event_timeout` | no | Per-event timeout in seconds, 1–60. Default 15. |
| `parameters` | no | Parameter schema, see below. |

Unknown fields are ignored, so a manifest written for a newer Surge still loads
where possible. The manifest must stay under 64 KB.

## 3. Parameters

Parameters are how users configure your plugin. Surge renders them natively
(settings UI, and `surge-cli plugin parameters <id>` / `plugin configure`) and
validates values before your script ever runs — your script receives them
already typed via `$plugin.params`.

Each entry supports:

| Key | Meaning |
|---|---|
| `key` | Identifier, ≤ 64 characters. Unique within the plugin. |
| `type` | `string`, `int`, `double`, `bool`, `enum`, `url`, `hostname`. |
| `label` | Short display name. Localizable. |
| `description` | One or two sentences shown under the field. Localizable. |
| `required` | Default `false`. Required parameters must be set before the plugin can be enabled. |
| `default` | Default value; must itself satisfy the schema. |
| `placeholder` | Example text shown in empty inputs. Localizable. |
| `min` / `max` | Numeric bounds for `int` / `double`. |
| `values` | The allowed values of an `enum`. |
| `allow_custom` | For `enum`: also accept values outside `values`. |
| `pattern` | Regular expression the (string-typed) value must match. |

Type notes:

- `url` accepts http(s) URLs only; `hostname` accepts a domain name or an
  IP literal (including IPv6). Both arrive in JavaScript as strings — they
  exist so users get input validation and the right keyboard.
- Parameter values are stored in plain text and are visible to the user in the
  plugin's settings. Do not assume secrecy for tokens beyond that of the
  user's own machine.

## 4. Runtime Model

- Register all event handlers at the top level of `main.js` with
  `$plugin.on(event, handler)`. Registration must happen synchronously during
  load — handlers registered later are not seen.
- The plugin runs event-driven. Surge may stop an idle plugin instance at any
  time and start a fresh one for the next event, so **never rely on in-memory
  state between events**. Persist state with `$persistentStore`.
- A handler may be `async`. Returning a value (an object) completes the event
  successfully; throwing an `Error` fails it, and `error.message` is shown to
  the user.
- Each event has a time budget (`event_timeout`, default 15 s). A handler that
  exceeds it — including one stuck in a loop — is terminated and reported as a
  timeout.

The environment is deliberately minimal: there is no DOM, no `fetch`, no
modules, no file access. The APIs below are everything.

## 5. JavaScript API

### Plugin context

```js
$plugin.id           // "com.example.myrouter-apc"
$plugin.version      // "1.0.0"
$plugin.apiVersion   // 1
$plugin.params       // typed parameter values, e.g. { host: "https://…", token: "…" }

$environment         // { system, "core-version", "surge-version", "surge-build", language }
```

### HTTP

`$httpClient` matches the API of Surge's script environment: one function per
method, callback style.

```js
$httpClient.get({
  url: "https://192.168.1.1/api/...",
  headers: { "Authorization": "Bearer …" },
  body: "…",                 // string, or an object (sent as JSON)
  timeout: 10,               // seconds, default 30
  insecure: true,            // accept self-signed / mismatched TLS certificates
  "auto-redirect": true,     // default true
  "binary-body-mode": false  // when true, data is a Uint8Array
}, function(error, response, data) {
  // error:    string or null
  // response: { status, headers }
  // data:     body string (or Uint8Array in binary-body-mode)
});
// Also: post / put / delete / head / options / patch
```

Notes:

- There is no `policy` option to direct a request through a specific proxy
  policy.
- Request and response bodies are limited to 8 MB; at most 20 requests may be
  in flight at once.
- Cookies are not stored between requests.

### Persistent storage

```js
$persistentStore.write(value, key);   // value: string; returns true/false
$persistentStore.read(key);           // returns string or null
$persistentStore.write(null, key);    // removes the key
```

- Synchronous, string-valued, private to your plugin. Keys are limited to
  letters, digits, `._-` (≤ 128 characters); total storage is limited to 4 MB.
- Storage survives plugin restarts and updates, and is removed on uninstall.

### Miscellaneous

```js
console.log("...")        // goes to Surge's log, prefixed with your plugin id
setTimeout(fn, ms)        // returns an id
clearTimeout(id)
```

## 6. The `ap-controller` Contract

Implement these events:

```js
$plugin.on("apc.fetchClients", async () => {
  return {
    clients: [{
      macAddress: "aa:bb:cc:dd:ee:ff",   // required; any common format is accepted
      accessPointName: "Office AP",       // all other fields optional
      ssid: "MyWiFi",
      connectionType: "Wi-Fi (5G)",       // free text shown in the device panel
      radioTechnology: "Wi-Fi 6 (ax)",
      canReconnect: true                  // whether apc.reconnect works for this client
    }]
  };
});

$plugin.on("apc.reconnect", async ({ client }) => {
  // client carries the same fields you returned from apc.fetchClients.
  // Kick the client on your controller; return normally on success.
});

// Recommended (with "supports_validation": true): called when the user saves
// parameters. Verify connectivity/credentials and report the result.
$plugin.on("system.validate", async () => {
  try {
    // e.g. fetch the client list once
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message };
  }
});
```

Surge calls `apc.fetchClients` whenever it needs fresh data for the device
panel and merges the result into its LAN device list by MAC address. Return
every client your controller knows about; Surge does the matching. Wired
clients may be included (set `canReconnect: false` for them).

A complete reference implementation ships with Surge — the official UniFi AP
Controller plugin at:

```
/Applications/Surge.app/Contents/Resources/Plugins/com.nssurge.plugin.ap-controller.unifi/
```

Its `manifest.json` and `main.js` demonstrate the full contract (parameter
schema, request wrapper with error handling, all three events); use it as the
starting point for your own implementation.

## 7. Developing and Testing

Work against a local directory ("load unpacked"):

```bash
surge-cli plugin load-unpacked ~/dev/my-plugin      # register / re-register
surge-cli plugin parameters <id>                    # see what needs configuring
surge-cli plugin configure <id> host=https://… token=…
surge-cli plugin list                               # state should be "enabled"
```

- `plugin configure` runs your `system.validate` (when declared) and refuses to
  save parameters that fail — a quick end-to-end test of your request code.
- After editing files, run `plugin load-unpacked` again to reload.
- When you change the parameter schema, re-running `plugin load-unpacked`
  revalidates the stored values against the new schema. Compatible changes
  (new optional parameters, label/description edits) keep the existing
  configuration; incompatible ones (a new required parameter, a removed
  parameter, tightened constraints) reset the plugin to unconfigured — check
  `plugin parameters` and run a full `plugin configure` again.
- `console.log` output and plugin errors appear in Surge's log
  (`surge-cli log`), prefixed with the plugin id.
- Check the result in Surge's device panel: Wi-Fi columns populate from your
  `apc.fetchClients` data.
- `surge-cli plugin validate <dir>` checks the manifest, `main.js`, and
  `icon.png` offline at any time.

## 8. Distributing

Distribution follows a hosted-manifest model: the zip is a pure asset, and a
manifest hosted at a stable HTTPS URL is the plugin's identity and update feed.

```bash
surge-cli plugin pack ~/dev/my-plugin https://example.com/releases/my-plugin-1.0.0.zip
```

`pack` produces:

- `<id>-<version>.zip` — the package (manifest.json is intentionally not
  inside).
- `<id>-<version>.manifest.json` — your manifest with an added `asset` block
  (the zip URL and its sha256).

Upload the zip to the asset URL (use a version-specific URL, never overwrite an
old version in place) and publish the emitted manifest at a **stable** HTTPS
URL — the manifest URL is your plugin's permanent identity.

> **Note:** installing from a manifest URL (`plugin install`) is not available
> in the current Surge version; it will be enabled in a later release. Until
> then, distribute to testers as a directory loaded with
> `plugin load-unpacked`. Preparing the hosted manifest and zip now means your
> release is ready the moment remote installation ships.

To release an update, bump `version`, re-run `pack`, upload the new zip, and
replace the hosted manifest; user parameters and persistent storage are kept
across updates.

## 9. Limits Summary

| Item | Limit |
|---|---|
| manifest.json | ≤ 64 KB |
| main.js | ≤ 2 MB |
| zip / unpacked package | ≤ 10 MB / ≤ 30 MB, ≤ 200 files |
| icon.png | exactly 256×256 |
| Event timeout | 1–60 s (default 15) |
| HTTP body (request and response) | ≤ 8 MB |
| Concurrent HTTP requests | 20 |
| `$persistentStore` | 4 MB total; keys ≤ 128 chars |
