import UIKit
import WebKit

/// Full-screen WKWebView shell loading `https://gemsloot.com` with the Step 2 bridge.
final class GemslootWebViewController: UIViewController {
    static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private let startURL = URL(string: "https://gemsloot.com")!
    private var webView: WKWebView!
    private let refreshControl = UIRefreshControl()
    private var scriptHandlerProxy: WeakScriptMessageHandler?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .gemslootBackground
        configureWebView()
        installDiagnosticGestures()
        loadHome()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSafeAreaCSSVariable()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            presentDiagnostics()
        } else {
            super.motionEnded(motion, with: event)
        }
    }

    deinit {
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: WebViewBridge.messageHandlerName)
    }

    // MARK: - Setup

    private func configureWebView() {
        let userContent = WKUserContentController()
        let proxy = WeakScriptMessageHandler(delegate: self)
        scriptHandlerProxy = proxy
        userContent.add(proxy, name: WebViewBridge.messageHandlerName)

        let safeTop = view.safeAreaInsets.top > 0 ? view.safeAreaInsets.top : statusBarHeight()
        installBridgeScript(on: userContent, safeAreaTop: safeTop)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController = userContent
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.backgroundColor = .gemslootBackground
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .gemslootBackground
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self

        refreshControl.addTarget(self, action: #selector(reloadFromRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.webView = webView
    }

    private func installBridgeScript(on userContent: WKUserContentController, safeAreaTop: CGFloat) {
        let config = AppState.shared.bridgeConfig(safeAreaTop: safeAreaTop)
        do {
            let script = try WebViewBridge.makeUserScript(config: config)
            userContent.removeAllUserScripts()
            userContent.addUserScript(script)
        } catch {
            assertionFailure("Failed to build WebViewBridge script: \(error)")
        }
    }

    /// Rebuild the document-start script so a newly locked ff snapshot is baked in on the next load.
    private func rebuildBridgeScriptForNextLoad() {
        let safeTop = view.safeAreaInsets.top > 0 ? view.safeAreaInsets.top : statusBarHeight()
        installBridgeScript(on: webView.configuration.userContentController, safeAreaTop: safeTop)
    }

    /// Diagnostics “Apply & Reload”: rebuild baked bridge config and hard-load gemsloot.com.
    func applyBridgeConfigAndReload() {
        rebuildBridgeScriptForNextLoad()
        webView.load(URLRequest(url: startURL))
    }

    private func loadHome() {
        webView.load(URLRequest(url: startURL))
    }

    @objc private func reloadFromRefresh() {
        rebuildBridgeScriptForNextLoad()
        webView.reload()
    }

    // MARK: - Diagnostic HUD gestures

    private func installDiagnosticGestures() {
        let makeRecognizer = { () -> UITapGestureRecognizer in
            let threeFinger = UITapGestureRecognizer(target: self, action: #selector(self.threeFingerTapRecognized))
            threeFinger.numberOfTapsRequired = 1
            threeFinger.numberOfTouchesRequired = 3
            threeFinger.cancelsTouchesInView = false
            threeFinger.delegate = self
            return threeFinger
        }
        webView.addGestureRecognizer(makeRecognizer())
        view.addGestureRecognizer(makeRecognizer())
    }

    @objc private func threeFingerTapRecognized() {
        presentDiagnostics()
    }

    func presentDiagnostics() {
        guard !isPresentingDiagnostics else { return }
        // Don't stack if a sheet is already up.
        if presentedViewController != nil { return }
        isPresentingDiagnostics = true
        let host = TrackingDiagnosticsPresenter.makeHostingController { [weak self] in
            self?.applyBridgeConfigAndReload()
        }
        host.presentationController?.delegate = self
        present(host, animated: true) { [weak self] in
            self?.isPresentingDiagnostics = false
        }
    }

    private func updateSafeAreaCSSVariable() {
        let px = view.safeAreaInsets.top
        let js = "document.documentElement.style.setProperty('--safe-area', '\(px)px');"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func statusBarHeight() -> CGFloat {
        view.window?.windowScene?.statusBarManager?.statusBarFrame.height
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .statusBarManager?
            .statusBarFrame.height
            ?? 47
    }
}

// MARK: - WKScriptMessageHandler

extension GemslootWebViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == WebViewBridge.messageHandlerName else { return }
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else { return }

        switch type {
        case "lockFfSnapshot":
            if let json = body["bodyJSON"] as? String {
                AppState.shared.lockFfBodyIfNeeded(exactJSON: json)
                rebuildBridgeScriptForNextLoad()
            }
        case "ffTelemetry":
            let url = body["url"] as? String ?? ""
            let bodyJSON = body["bodyJSON"] as? String ?? ""
            let status = body["status"] as? Int
            AppState.shared.recordFfTelemetry(url: url, bodyJSON: bodyJSON, status: status)
        default:
            break
        }
    }
}

// MARK: - Navigation / UI

extension GemslootWebViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // App Store / store links → native handoff (main frame or redirect).
        if ExternalNavigation.isAppStoreURL(url) {
            AppState.shared.appendRedirectHop(url: url.absoluteString, statusCodeOrType: "AppStore")
            decisionHandler(.cancel)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }

        // Other external schemes (mail, Telegram, Discord, …).
        if ExternalNavigation.isExternalScheme(url) {
            AppState.shared.appendRedirectHop(url: url.absoluteString, statusCodeOrType: "external")
            decisionHandler(.cancel)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }

        // `_api/auth` OAuth return on gemsloot.com — allow in-place so cookies stay on
        // `WKWebsiteDataStore.default()` (shared with popup WebViews from createWebViewWith).
        if ExternalNavigation.isGemslootAuthCallback(url) {
            AppState.shared.appendRedirectHop(url: url.absoluteString, statusCodeOrType: "oauth-callback")
            decisionHandler(.allow)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        updateSafeAreaCSSVariable()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        refreshControl.endRefreshing()
    }
}

extension GemslootWebViewController: WKUIDelegate {
    /// Offerwall / OAuth `window.open` — present popup WebView with the **same** configuration
    /// so `window.opener` remains connected; return that WebView (not nil / not the main one).
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let tracker = TrackerRedirectViewController(
            configuration: configuration,
            initialAction: navigationAction
        )
        present(tracker, animated: true)
        return tracker.webView
    }
}

// MARK: - Gesture / presentation delegates

extension GemslootWebViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension GemslootWebViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        isPresentingDiagnostics = false
        becomeFirstResponder()
    }
}

// MARK: - Retain-cycle-safe script handler

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
