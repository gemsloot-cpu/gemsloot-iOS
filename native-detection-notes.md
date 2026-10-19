# Phase 1 — Gemsloot Android APK recon

**Source:** `/workspace/Gemsloot-Earn-money_7.5_apkcube.apks`  
**Package:** `com.gemsloot.app` · **versionName:** `7.5` · **versionCode:** `75`  
**Stack:** Capacitor (Android) + SvelteKit web bundle + Adjoe Playtime SDK  
**Tools:** `unzip`, `apktool 2.11.1`, `jadx 1.5.1`, `strings`

---

## Exact start URL

**WebView initial load URL:** `https://localhost`

How derived:
- `assets/capacitor.config.json` has **no** `server.url` / `overrideUserAgent` / `appendUserAgent`.
- Capacitor defaults: `server.hostname = "localhost"`, `server.androidScheme = "https"`.
- `Bridge.initWebView()` sets `appUrl = scheme + "://" + host` → **`https://localhost`**, serving bundled assets from `assets/public/` (index at `assets/public/index.html`).

**Not** a remote `https://gemsloot.com` load on cold start. The remote site is used as API/front origin by the JS inside the local WebView.

| Role | URL |
|------|-----|
| WebView start | `https://localhost` |
| Front / canonical | `https://gemsloot.com` |
| API base | `https://gemsloot.com/_api` |
| Images CDN | `https://img.gemsloot.com` |
| Adjoe offerwall WebView | `https://adjoeofferwallbundle.androidplatform.net/index.html?...` |
| Adjoe API | `https://prod.adjoe.zone/v1` |

Bundled config (baked into JS with `is_android: true`):

```js
{
  api_protocol: "https",
  api_url: "gemsloot.com/_api",
  front_protocol: "https",
  front_url: "gemsloot.com",
  img_url: "https://img.gemsloot.com",
  is_android: true
}
```

---

## User-Agent

**Main Capacitor WebView: no custom UA.**  
`capacitor.config.json` does not set `android.overrideUserAgent` or `android.appendUserAgent`. Runtime uses the **default Android System WebView / Chromium UA**.

Adjoe’s *separate* offerwall WebView can set its own UA string and also sends `Adjoe-BrowserUserAgent` / related headers to Adjoe backends — that is Adjoe-internal, not the gemsloot.com page UA.

**iOS implication:** keep the default **Safari / WKWebView Safari UA** (do not spoof Android Chrome) so App Store / offer partners see iOS Safari.

---

## Custom HTTP headers (gemsloot.com)

On every API `fetch` to `https://gemsloot.com/_api/...` when `is_android` is true:

| Header | Value | Purpose |
|--------|-------|---------|
| `Device` | `android` | Marks client as Android app build |
| `Accept` | `application/json` | On POST JSON helpers |
| `Content-Type` | `application/json` | On POST JSON helpers |

Also: `credentials: "include"` (session cookies).

No other app-authored custom headers to gemsloot.com were found (no GAID/IDFA header on the main WebView traffic).

---

## Native app vs browser detection (JS)

**Source file:** `assets/public/_app/immutable/bundle.CU_rMswQ.js`  
(There is **no** `assets/public/assets/*.js` tree in this APK — only the SvelteKit immutable bundle plus `cordova.js` / `ob.js` / `service-worker.js`.)  
Beautified extracts: [`../internal/phase-1/native-detection-snippets.js`](../internal/phase-1/native-detection-snippets.js)

### Verdict

App feature branches use a **build-time boolean** `Il.is_android`, **not** runtime `Capacitor.isNativePlatform()`.

| Mechanism | In APK bundle | Used by Gemsloot app logic? |
|-----------|---------------|------------------------------|
| `Il.is_android` (config object) | hard-coded `true` | **Yes** — headers, Device/Push/InstallReferrer boot, Playtime, Google login, review CTA, UI |
| `Capacitor.isNativePlatform()` | defined in Capacitor runtime | **No** — **0 call sites** in the app bundle |
| `Capacitor.getPlatform()` | defined (`android` if `window.androidBridge`, else `ios` if WK bridge, else `web`) | **No** — 0 call sites |
| `assets/native-bridge.js` | sets `isNativePlatform = () => true` in the native shell | Used by Capacitor plugin plumbing only |

### 1) Build flag + `Device` header

```js
Il = {
  api_protocol: "https",
  api_url: "gemsloot.com/_api",
  front_protocol: "https",
  front_url: "gemsloot.com",
  img_url: "https://img.gemsloot.com",
  is_android: true, // baked into this APK’s JS
};

Gl = `${Il.api_protocol}://${Il.api_url}`; // https://gemsloot.com/_api
ql = Il.is_android ? { Device: "android" } : {};
// every API fetch spreads ...ql into headers
```

- **Android APK build:** `Device: android` on all `_api` requests.  
- **Non-android build / browser dist:** empty extra headers (`{}`).

### 2) Capacitor runtime (present but unused by app if/else)

```js
// platform id probe
getPlatformId = (win) =>
  win?.androidBridge ? "android"
  : win?.webkit?.messageHandlers?.bridge ? "ios"
  : "web";

// assigned onto window.Capacitor:
//   getPlatform = () => customPlatform?.name ?? getPlatformId(win)
//   isNativePlatform = () => getPlatform() !== "web"
```

`Device` is registered as `registerPlugin("Device", { web: () => DeviceWeb })`. On native, methods hit the Android plugin; on web, `DeviceWeb.getId()` / `getInfo()` use a local UUID + `navigator.userAgent`.

### 3) Startup branch: Capacitor stack vs browser fingerprint

Minified as one `if (` … comma expressions … `, Il.is_android) { … } else { … }`:

```js
if (
  /* Facebook pixel script inject + 1s probe via comma operators */,
  Il.is_android
) {
  // ----- ANDROID / NATIVE APP BRANCH -----
  // load Capacitor plugins: App, Device, PushNotifications, StatusBar
  // StatusBar → --safe-area CSS var
  // App.addListener("appUrlOpen") → _api deep links / in-app routes
  // Device.getId() → UUID `s`  (NOT GAID)
  // Device.getInfo() + getLanguageTag() → $.user_device
  // POST _api/ff { hash: s, data, formated_data }
  // PushNotifications → android/add_sub/ | android/rm_sub with { aid: s }
  // registerPlugin("InstallReferrer").getReferrer()  (checks `ref` query; result unused)
} else {
  // ----- BROWSER BRANCH -----
  // getFingerprint(true) → browser fingerprint hash + UA metadata
  // POST _api/ff { hash, data, formated_data }  (no push / no InstallReferrer)
}
```

### 4) `PlaytimePlugin` (Adjoe) — gated by `Il.is_android`

```js
Playtime = registerPlugin("PlaytimePlugin");

// Earn page mount:
if (Il.is_android) {
  // Playtime.init({ apiKey, userId, applicationProcessName: "com.gemsloot.app", ... })
  // retries while user.id === -5 (up to 5 times)
}

async function openCatalog() {
  if (!Il.is_android) return;          // web: no-op
  if ($.user.id == -5) { /* login toast */; return; }
  // init if needed, then Playtime.showCatalog({ uaNetwork, uaChannel, ... })
}
```

Adjoe UI on Earn is also shown only when `Il.is_android && ["US","DE","FR"].includes(loc)`.

### 5) Other `Il.is_android` differences

| Area | `is_android === true` | else (browser) |
|------|----------------------|----------------|
| Google login | `GET auth/google/login/tz:…` then `window.open(url, "_system")` | OAuth popup + `postMessage` `oauth_done` |
| Review CTA | `market://details?id=com.gemsloot.app` + `trk/401` | Trustpilot URL + `trk/400` |
| Casino offers | Hidden if `user.xp < 500` | Shown normally |
| Pull-to-refresh / safe-area | Enabled in native boot | N/A |

### iOS takeaway

Loading the **live website** in WKWebView without an iOS build of this bundle will take the **`else` (browser fingerprint)** path and **won’t** send `Device: android`, init Playtime, or use InstallReferrer — unless the remote web build has its own `is_ios` / Capacitor iOS flag. A native iOS shell needs either an iOS-flavored web build (`is_android: false` + Capacitor iOS plugins) or explicit bridging that mirrors the Android branch.

---

## JS bridges / plugins / injected interfaces

### Capacitor `@JavascriptInterface` (main WebView)

| Interface name | Class | Methods / role |
|----------------|-------|----------------|
| `androidBridge` | `com.getcapacitor.MessageHandler` | `postMessage(String)` — Capacitor/Cordova plugin RPC |
| `CapacitorHttpAndroidInterface` | `com.getcapacitor.plugin.CapacitorHttp` | `isEnabled()` — native HTTP plugin gate (`plugins.CapacitorHttp.enabled: true`) |
| `CapacitorCookiesAndroidInterface` | `com.getcapacitor.plugin.CapacitorCookies` | `isEnabled()`, `setCookie(url, cookie)` |
| `CapacitorSystemBarsAndroidInterface` | `com.getcapacitor.plugin.SystemBars` | `onDOMReady()` — safe-area / insets |

### Capacitor plugins used by the app

Registered via `capacitor.plugins.json` + `MainActivity.registerPlugin(InstallReferrerPlugin)`:

| Plugin id | Class | Notable methods | Purpose |
|-----------|-------|-----------------|---------|
| `InstallReferrer` | `gemsloot.com.InstallReferrerPlugin` | `getReferrer()` → `{ referrer }` | Play Install Referrer API |
| `App` | `com.capacitorjs.plugins.app.AppPlugin` | `getLaunchUrl`, `getInfo`, `getState`, events `appUrlOpen`, … | Lifecycle + App Links |
| `Device` | `com.capacitorjs.plugins.device.DevicePlugin` | `getId()` → `{ identifier }` (app UUID, **not GAID**), `getInfo`, `getLanguageTag`, … | Device fingerprint / push `aid` |
| `PushNotifications` | `…PushNotificationsPlugin` | `requestPermissions`, `register`, `registration` listener | FCM token → `android/add_sub/` |
| `StatusBar` | `…StatusBarPlugin` | `getInfo`, style/color | Status bar; config DARK / `#101012` |
| `PlaytimePlugin` | `io.adjoe.sdk.capacitor.PlaytimePlugin` | `init`, `showCatalog`, `getUserId`, `isInitialized`, `setUAParams`, `hasAcceptedTOS`, `hasAcceptedUsagePermission`, `sendEvent`, `getVersion`, `getVersionName` | Adjoe Playtime offerwall |

### Custom Install Referrer plugin (app-specific)

```java
@CapacitorPlugin(name = "InstallReferrer")
public class InstallReferrerPlugin extends Plugin {
  @PluginMethod
  public void getReferrer(PluginCall call) {
    // InstallReferrerClient → resolve { "referrer": <installReferrer string> }
  }
}
```

JS (Android path) calls `InstallReferrer.getReferrer()` and checks whether the referrer query string contains `ref`. The boolean result appears unused in the minified bundle (possible dead/incomplete affiliate wiring).

### Adjoe offerwall WebView bridge (secondary WebView)

| Interface | Class | Purpose |
|-----------|-------|---------|
| `Adjoe` | `io.adjoe.sdk.internal.c` | Large `@JavascriptInterface` surface for offerwall UI (TOS, install clicks, device context, `{gaid}` URL substitution, notifications, etc.) |

GAID is read via `AdvertisingIdClient` **inside Adjoe**, stored/used for Adjoe attribution and `{gaid}` replacement in tracking links — **not** injected into the main gemsloot WebView as a JS variable.

### Device / push identity sent to gemsloot API

On Android startup (Capacitor path):

1. `Device.getId()` → app UUID `s`
2. `Device.getInfo()` + language → `user_device` object
3. `POST https://gemsloot.com/_api/ff` with `{ hash: s, data: deviceInfo, formated_data: user_device }`
4. Push: `android/add_sub/` with `{ aid: s, token }` / `android/rm_sub` with `{ aid: s }`

So the primary “device id” to gemsloot is Capacitor’s **app UUID**, not GAID.

### Adjoe init (from bundled JS)

```js
Playtime.init({
  apiKey: "a6698ec14175efdf38d3c9aabcee9803",
  userId: `${userId}`,
  applicationProcessName: "com.gemsloot.app",
  playtimeParams: {
    uaNetwork: "Organic",
    uaChannel: "incentivized",
    uaSubPublisherCleartext: "com.gemsloot.app",
    uaSubPublisherEncrypted: "",
    placement: "Earn Page"
  },
  playtimeExtension: { subId1: `${userId}` },
  playtimeUserProfile: /* from API init_data.adjoe */
})
// later: Playtime.showCatalog({ ...same ua* params... })
```

---

## Manifest schemes / deep links

**App Links (verified):**

```xml
<intent-filter android:autoVerify="true">
  <action android:name="android.intent.action.VIEW"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <category android:name="android.intent.category.BROWSABLE"/>
  <data android:scheme="https"/>
  <data android:host="gemsloot.com"/>
</intent-filter>
```

- Host: `gemsloot.com` (no path restriction → all `https://gemsloot.com/*`)
- Digital Asset Links: `asset_statements` → `https://gemsloot.com/.well-known/assetlinks.json`
- Filter is duplicated twice identically on `MainActivity`
- `launchMode="singleTask"`, portrait lock

**Custom scheme:** `strings.xml` has `custom_url_scheme = com.gemsloot.app` (Capacitor/Cordova leftover). **No** `android:scheme="com.gemsloot.app"` intent-filter in the manifest.

**Deep-link JS handling** (`App` → `appUrlOpen`):
- If URL contains `_api` → `GET` that API path (strip `/_api` prefix) with cookies; reload if `auth` in URL
- Else → in-app navigate to `"/" + pathname`

**Permissions of note:** `INTERNET`, `AD_ID`, `POST_NOTIFICATIONS`, `PACKAGE_USAGE_STATS` (Adjoe), Install Referrer, FCM.

---

## Other replication-relevant behavior

### WebView settings (Capacitor defaults + config)

- JS enabled, DOM storage, geolocation, media autoplay without gesture
- `allowMixedContent: true`, `usesCleartextTraffic: true`, `webContentsDebuggingEnabled: true`
- `server.allowNavigation`: only `127.0.0.1`, `localhost` → other hosts leave the WebView via `Bridge.launchIntent` (external browser / VIEW intent)
- Offline fallback asset: `assets/no_internet.html`
- CapacitorHttp plugin enabled (native HTTP path available to JS)

### Cookies / auth

- API calls use `credentials: "include"` against `gemsloot.com`
- Google Sign-In via `accounts.google.com/gsi/client` + `window.open(..., "_system")` / oauth popup URLs under `/_api/auth/google/login/...`
- Facebook Pixel `1072393244826229`, GA `G-W1EKFJV65N` in `index.html`

### Offerwall / partner surface

- **Adjoe Playtime** (native SDK + secondary WebView) — primary Android playtime wall
- Web offer providers referenced in bundle include lootably, torox, bitlabs, ayet, adgate, adgem, adscend, theoremreach, pollfish (images/API snippets; not all are native bridges)

### Analytics / attribution stack

| Mechanism | What |
|-----------|------|
| Play Install Referrer | Custom Capacitor plugin |
| Capacitor Device UUID | Sent as `hash` / push `aid` |
| Adjoe GAID | Inside Adjoe SDK only |
| Firebase Messaging | Push |
| Meta Pixel + gtag | Fastened into local HTML |

---

## iOS replication notes

1. **Start URL choice**
   - Faithful Capacitor clone would load a local bundle at an app-origin equivalent of `https://localhost`.
   - A thin **WKWebView wrapper of the live site** should load **`https://gemsloot.com`** (front_url). Confirm with product whether Phase 2 is local shell vs remote wrapper.

2. **GAID → IDFA**
   - Main gemsloot API does **not** appear to receive GAID.
   - GAID matters for **Adjoe**. On iOS, use Adjoe’s iOS SDK + **IDFA** (ATT) in place of GAID; do not invent a `gaid` query/header on gemsloot.com unless backend requires it.
   - Keep sending a stable app/device identifier analogous to Capacitor `Device.getId()` if the backend `ff` / push endpoints expect it.

3. **User-Agent**
   - Do **not** override WKWebView UA to Android/Chrome.
   - Keep **iOS Safari UA** so App Store offer traffic attributes correctly.

4. **Headers**
   - Mirror `Device: android` with something like **`Device: ios`** (only if backend accepts it; Android build hardcodes `Device: android` when `is_android`).
   - Preserve cookie jar / `credentials: include` behavior for `gemsloot.com`.

5. **Deep links**
   - Universal Links for `https://gemsloot.com/*` (same host as Android App Links).
   - Handle `_api` OAuth return URLs inside the app (reload after auth) the same way as `appUrlOpen`.

6. **Install referrer**
   - No Play Install Referrer on iOS; use Apple Ads / ASA token / clipboard or server-side attribution as the counterpart to `InstallReferrer.getReferrer()`.

7. **Adjoe**
   - Port Playtime init params (`apiKey`, `userId`, `placement`, `uaNetwork`/`uaChannel`, `subId1`).
   - Expect ATT + usage-permission analogues per Adjoe iOS docs.

8. **Out-of-scope for a pure WKWebView**
   - Full Capacitor plugin surface (`androidBridge`, push, status bar, CapacitorHttp) unless you embed Capacitor iOS or reimplement bridges.

---

## Evidence index

| Artifact | Location (analysis host) |
|----------|---------------------------|
| APKS | `/workspace/Gemsloot-Earn-money_7.5_apkcube.apks` |
| base.apk | unpacked under `/tmp/gemsloot-apk/apks-unpacked/` |
| Capacitor config | `assets/capacitor.config.json` |
| Manifest | apktool `AndroidManifest.xml` |
| MainActivity | `com.gemsloot.app.MainActivity` |
| InstallReferrer | `gemsloot.com.InstallReferrerPlugin` |
| Bundled web | `assets/public/` + `_app/immutable/bundle.CU_rMswQ.js` |
| Machine dump | [`../internal/phase-1/recon-dump.json`](../internal/phase-1/recon-dump.json) |
