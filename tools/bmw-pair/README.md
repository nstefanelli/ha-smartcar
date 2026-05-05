# BMW Pair

Native macOS app that pairs your BMW with your Smartcar application using Smartcar's mobile-SDK flow — necessary for BMW vehicles in the US since 2025-09 because Smartcar's web OAuth flow is captcha-blocked for BMW. Outputs an authorization code you paste into Home Assistant.

Companion to the [`ha-smartcar` BMW fork](https://github.com/nstefanelli/ha-smartcar).

## How it works

The app loads Smartcar Connect inside a `WKWebView` with the same JavaScript bridge Smartcar's iOS SDK provides (`window.SmartcarSDK.sendMessage` → JSON-RPC handler that opens an inner `ASWebAuthenticationSession` for the OEM login). When you select BMW and sign in, BMW's auth provider treats the flow as a native-app OAuth (custom-scheme redirect URI `sc<clientId>://exchange`) and lets you through — no captcha.

The redirect callback is captured by the WKWebView's navigation delegate, the auth code is extracted and copied to your clipboard, and you paste it into Home Assistant's Smartcar reauth/setup flow.

## Prerequisites

1. **Smartcar developer account.** Sign up free at [dashboard.smartcar.com](https://dashboard.smartcar.com). Free tier is 500 API calls/month/vehicle.
2. **Smartcar application.** Create one in the dashboard. Note the **Client ID** (a UUID).
3. **Register the mobile redirect URI.** In your Smartcar application's Configuration tab, add this redirect URI exactly:
   ```
   sc<your-client-id>://exchange
   ```
   For example, if your client ID is `abc12345-...-...`, the URI is `scabc12345-...-...://exchange`.
4. **Set mode = `live`** in your application settings.
5. **Enable scopes** the integration uses: `read_vehicle_info`, `read_vin`, `read_battery`, `read_charge`, `read_engine_oil`, `read_fuel`, `read_location`, `read_odometer`, `read_security`, `read_tires`, `control_charge`, `control_security`.

## Install

Pre-built `BMWPair.app` is attached to each `ha-smartcar` GitHub release. Download, drag to `/Applications`, then:

```bash
xattr -dr com.apple.quarantine /Applications/BMWPair.app
```

(macOS Gatekeeper quarantines unnotarized apps. The `xattr` removes the quarantine flag. Alternatively, right-click the app → Open the first time.)

Or build from source:

```bash
git clone https://github.com/nstefanelli/ha-smartcar.git
cd ha-smartcar/tools/bmw-pair
./build-app.sh release
open ./BMWPair.app
```

Requires the Swift toolchain (Xcode or Command Line Tools).

## Use

1. Launch `BMWPair.app`.
2. **First launch:** enter your Smartcar Client ID. Saved to UserDefaults; you won't be asked again.
3. The app loads Smartcar Connect. Click **Connect a vehicle** (Smartcar's own button) → select **BMW** → sign in with your BMW credentials → authorize the vehicles you want.
4. App captures the auth code, copies it to your clipboard, and shows it for verification.
5. In Home Assistant: open the Smartcar reauth notification (or Settings → Devices & Services → Smartcar → Reconfigure → Manual token entry) → paste the code → submit. The integration exchanges it for tokens.

## Notes

- Auth codes are **single-use** and **expire in ~10 minutes**. Don't dawdle between capturing and pasting into HA. If exchange fails, just run the pairing again — takes 30 seconds.
- The app stores only your Client ID locally (in `defaults read com.bmw-fork.bmwpair smartcar_client_id`). It never sees your Client Secret — that lives only in HA's `application_credentials` storage.
- Re-pair is the cure for any "Smartcar needs reauth" notification that the standard OAuth flow can't fix (which is all of them, for BMW US).

## Tech stack

- SwiftUI + AppKit (macOS 13+)
- WKWebView with custom JS bridge (mimicking Smartcar's iOS SDK protocol — see [`smartcar/ios-sdk`](https://github.com/smartcar/ios-sdk)'s `OAuthCapture.swift` and `RPCInterface.swift`)
- ASWebAuthenticationSession for the inner OEM OAuth
- ~300 lines of Swift, no third-party dependencies

## Why a separate Mac app?

The Smartcar iOS SDK is iOS-only and requires a real iPhone or iOS Simulator (full Xcode). This app reimplements the same JS bridge protocol natively for macOS, so any Mac with the Swift toolchain (Command Line Tools is enough) can run it. No iPhone required.
