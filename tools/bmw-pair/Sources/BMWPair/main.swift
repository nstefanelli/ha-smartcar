// BMWPair — Smartcar mobile-SDK pairing helper for BMW vehicles in regions where
// the standard web OAuth flow is blocked (US since 2025-09).
//
// Pairs your BMW via a WKWebView that mimics Smartcar's iOS SDK JS bridge, then
// returns the OAuth authorization code. Paste that code into Home Assistant via
// the BMW-fork smartcar integration's "Manual token entry" reauth step — the
// integration handles the token exchange internally.
//
// Companion to: https://github.com/nstefanelli/ha-smartcar

import SwiftUI
import WebKit
import AuthenticationServices
import AppKit

// =============================================================================
// Persistent settings
// =============================================================================

enum Settings {
    static let clientIdKey = "smartcar_client_id"

    static var clientId: String? {
        get { UserDefaults.standard.string(forKey: clientIdKey)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        set { UserDefaults.standard.set(newValue, forKey: clientIdKey) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// =============================================================================
// Constants
// =============================================================================

// Scopes match the HA integration's REQUIRED + DEFAULT + useful CONFIGURABLE set.
// See https://github.com/nstefanelli/ha-smartcar/blob/main/custom_components/smartcar/const.py
let SCOPES = [
    "read_vehicle_info", "read_vin",
    "read_battery", "read_charge",
    "read_engine_oil", "read_fuel",
    "read_location", "read_odometer",
    "read_security", "read_tires",
    "control_charge", "control_security",
]

// =============================================================================
// JSON-RPC types matching Smartcar iOS SDK protocol
// (See SmartcarAuth/OAuthCapture.swift in https://github.com/smartcar/ios-sdk)
// =============================================================================

struct RPCRequestParams: Codable { var authorizeURL: String; var interceptPrefix: String }
struct RPCRequest: Codable { var jsonrpc: String; var method: String; var params: RPCRequestParams; var id: String }
struct OauthResult: Codable { var returnUri: String }
struct OauthError: Codable { var code: Int; var message: String }
struct JSONRPCResponse: Codable { var jsonrpc: String = "2.0"; var result: OauthResult; var id: String }
struct JSONRPCErrorResponse: Codable { var jsonrpc: String = "2.0"; var error: OauthError; var id: String }

// =============================================================================
// App entry
// =============================================================================

NSApplication.shared.setActivationPolicy(.regular)

// =============================================================================
// Bridge: handles `window.SmartcarSDK.sendMessage` from the SPA, opens an inner
// ASWebAuthenticationSession with the OEM URL, and dispatches the result back
// via SmartcarSDKResponse CustomEvent.
// =============================================================================

class BridgeHandler: NSObject, WKScriptMessageHandler, ASWebAuthenticationPresentationContextProviding {
    weak var webView: WKWebView?
    weak var window: NSWindow?
    var session: ASWebAuthenticationSession?

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "SmartcarSDK",
              let bodyString = message.body as? String,
              let data = bodyString.data(using: .utf8) else { return }
        guard let req = try? JSONDecoder().decode(RPCRequest.self, from: data) else { return }
        guard let authURL = URL(string: req.params.authorizeURL),
              let interceptURL = URL(string: req.params.interceptPrefix),
              let scheme = interceptURL.scheme else { return }

        print("BRIDGE: opening OEM auth — \(authURL.host ?? "?")")
        let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { [weak self] callbackURL, err in
            self?.respondToWebView(reqId: req.id, callbackURL: callbackURL, error: err)
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        s.start()
        session = s
    }

    func respondToWebView(reqId: String, callbackURL: URL?, error: Error?) {
        let payload: Data
        if let err = error {
            let nsErr = err as NSError
            let canceled = nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
            let errObj = OauthError(
                code: canceled ? -32000 : -32603,
                message: canceled ? "OAuth capture cancelled" : "Internal JSONRPC error"
            )
            payload = (try? JSONEncoder().encode(JSONRPCErrorResponse(error: errObj, id: reqId))) ?? Data()
        } else if let url = callbackURL {
            payload = (try? JSONEncoder().encode(JSONRPCResponse(result: OauthResult(returnUri: url.absoluteString), id: reqId))) ?? Data()
        } else {
            payload = (try? JSONEncoder().encode(JSONRPCErrorResponse(
                error: OauthError(code: -32603, message: "Internal JSONRPC error"), id: reqId))) ?? Data()
        }
        guard let payloadStr = String(data: payload, encoding: .utf8) else { return }
        let js = "dispatchEvent(new CustomEvent('SmartcarSDKResponse', { detail: \(payloadStr) }))"
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(js) { _, e in
                if let e = e { print("BRIDGE: evalJS error: \(e)") }
            }
        }
    }

    func presentationAnchor(for s: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return window ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

// =============================================================================
// Navigation: intercepts the final sc<clientId>://exchange?code=... redirect
// =============================================================================

class NavDelegate: NSObject, WKNavigationDelegate {
    let clientId: String
    var onCode: ((String) -> Void)?
    var onErr: ((String) -> Void)?

    init(clientId: String) {
        self.clientId = clientId
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url {
            let scheme = "sc\(clientId)"
            if url.scheme == scheme {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                if let code = items?.first(where: { $0.name == "code" })?.value {
                    print("AUTH_CODE=\(code)")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    onCode?(code)
                } else if let errStr = items?.first(where: { $0.name == "error" })?.value {
                    onErr?(errStr)
                } else {
                    onErr?("callback had no code: \(url.absoluteString)")
                }
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}

// =============================================================================
// SwiftUI views
// =============================================================================

@MainActor
class AppState: ObservableObject {
    @Published var clientId: String? = Settings.clientId
    @Published var lastCode: String?
    @Published var status: String = ""

    func saveClientId(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Settings.clientId = trimmed
        clientId = trimmed
    }

    func clearClientId() {
        Settings.clientId = nil
        clientId = nil
    }
}

struct ConfigView: View {
    @EnvironmentObject var state: AppState
    @State private var input: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Smartcar Application Credentials").font(.title2).bold()
            Text("Enter the **Client ID** from your Smartcar developer dashboard. This is a UUID, e.g. `00000000-0000-0000-0000-000000000000`.")
                .fixedSize(horizontal: false, vertical: true)
            Text("**Important:** in your Smartcar application, register `sc<your-client-id>://exchange` as a redirect URI.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Client ID (UUID)", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { state.saveClientId(input) }

            HStack {
                Spacer()
                Button("Save") { state.saveClientId(input) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()
            Text("Don't have a Smartcar app yet? Sign up free at [dashboard.smartcar.com](https://dashboard.smartcar.com), create an Application, and copy the Client ID. Free tier covers 500 API calls/month/vehicle.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 520, height: 380)
    }
}

struct WebViewWrapper: NSViewRepresentable {
    let clientId: String
    let bridge: BridgeHandler
    let nav: NavDelegate

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        let shim = """
        (() => {
            window.SmartcarSDK = {};
            window.SmartcarSDK.sendMessage = (rpcString) => {
                window.webkit.messageHandlers.SmartcarSDK.postMessage(rpcString);
            };
        })();
        """
        ucc.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.add(bridge, name: "SmartcarSDK")
        config.userContentController = ucc
        config.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = nav
        bridge.webView = webView

        var comps = URLComponents(string: "https://connect.smartcar.com/oauth/authorize")!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: "sc\(clientId)://exchange"),
            .init(name: "scope", value: SCOPES.joined(separator: " ")),
            .init(name: "mode", value: "live"),
            .init(name: "approval_prompt", value: "force"),
            .init(name: "sdk_platform", value: "iOS"),
        ]
        webView.load(URLRequest(url: comps.url!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

struct PairView: View {
    @EnvironmentObject var state: AppState
    let bridge: BridgeHandler
    let nav: NavDelegate

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pairing — sign in with BMW credentials, authorize all vehicles you want in HA.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings") { state.clearClientId() }.font(.caption)
            }.padding(.horizontal, 12).padding(.vertical, 8)

            WebViewWrapper(clientId: state.clientId!, bridge: bridge, nav: nav)
                .frame(minWidth: 480, minHeight: 700)
        }
        .frame(width: 480, height: 760)
    }
}

struct SuccessView: View {
    @EnvironmentObject var state: AppState
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("✓ Auth code captured").font(.title2).bold()
            Text("Auth code (also copied to clipboard):")
            Text(code)
                .textSelection(.enabled)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .frame(maxWidth: 460, alignment: .leading)
            Text("**Next:** in Home Assistant, click the Smartcar reauth notification (or Settings → Devices & Services → Smartcar → Reconfigure) → choose **Manual token entry** → paste the code → submit.")
                .fixedSize(horizontal: false, vertical: true)
            Text("⚠️ Auth codes are single-use and expire in ~10 minutes. Don't dawdle.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Button("Pair again") { state.lastCode = nil }
                Spacer()
                Button("Settings") { state.clearClientId(); state.lastCode = nil }
            }
        }
        .padding(24)
        .frame(width: 520, height: 380)
    }
}

struct RootView: View {
    @StateObject var state = AppState()
    let bridge = BridgeHandler()
    var nav: NavDelegate { NavDelegate(clientId: state.clientId ?? "") }

    var body: some View {
        Group {
            if let code = state.lastCode {
                SuccessView(code: code)
            } else if state.clientId == nil {
                ConfigView()
            } else {
                let n = NavDelegate(clientId: state.clientId!)
                PairView(bridge: bridge, nav: n)
                    .onAppear {
                        n.onCode = { code in DispatchQueue.main.async { state.lastCode = code } }
                        n.onErr = { msg in
                            DispatchQueue.main.async {
                                let alert = NSAlert()
                                alert.messageText = "Pairing error"; alert.informativeText = msg; alert.runModal()
                            }
                        }
                    }
            }
        }
        .environmentObject(state)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = RootView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.center()
        window.title = "BMW Pair (Smartcar)"
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
