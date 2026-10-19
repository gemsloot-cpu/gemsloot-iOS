import UIKit
import WebKit

/// Modal popup WebView for `window.open` / `target=_blank` offerwall & OAuth chains.
///
/// **Critical:** constructed with the exact `WKWebViewConfiguration` from
/// `webView(_:createWebViewWith:for:windowFeatures:)` so `window.opener` stays connected
/// (required for Google OAuth `postMessage("oauth_done")` → `window.close()`).
final class TrackerRedirectViewController: UIViewController {
    private(set) var webView: WKWebView!

    private let initialAction: WKNavigationAction
    private let hostLabel = UILabel()
    private let hopBadge = UILabel()
    private var hopCount = 0
    private var hasDismissed = false

    init(configuration: WKWebViewConfiguration, initialAction: WKNavigationAction) {
        self.initialAction = initialAction
        super.init(nibName: nil, bundle: nil)

        // Must use the provided configuration — do not create a new one.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = GemslootWebViewController.safariUserAgent
        webView.backgroundColor = .gemslootBackground
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .gemslootBackground
        self.webView = webView

        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .gemslootBackground
        buildChrome()
        loadInitialRequest()
    }

    // MARK: - Chrome

    private func buildChrome() {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.backgroundColor = UIColor(red: 16 / 255, green: 16 / 255, blue: 18 / 255, alpha: 1)

        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        hostLabel.textColor = .white
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.text = initialAction.request.url?.host ?? "…"

        hopBadge.translatesAutoresizingMaskIntoConstraints = false
        hopBadge.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        hopBadge.textColor = .black
        hopBadge.backgroundColor = UIColor(white: 0.85, alpha: 1)
        hopBadge.textAlignment = .center
        hopBadge.layer.cornerRadius = 10
        hopBadge.clipsToBounds = true
        hopBadge.text = "Hop 0"
        hopBadge.setContentHuggingPriority(.required, for: .horizontal)

        let safariButton = UIButton(type: .system)
        safariButton.translatesAutoresizingMaskIntoConstraints = false
        safariButton.setTitle("Open in Safari", for: .normal)
        safariButton.setTitleColor(.white, for: .normal)
        safariButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        safariButton.addTarget(self, action: #selector(openInSafari), for: .touchUpInside)

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("✕", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "Close"

        webView.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(hostLabel)
        header.addSubview(hopBadge)
        header.addSubview(safariButton)
        header.addSubview(closeButton)
        view.addSubview(header)
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),

            closeButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 36),

            hopBadge.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            hopBadge.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hopBadge.heightAnchor.constraint(equalToConstant: 22),
            hopBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),

            hostLabel.leadingAnchor.constraint(equalTo: hopBadge.trailingAnchor, constant: 10),
            hostLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: safariButton.leadingAnchor, constant: -8),

            safariButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            safariButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func loadInitialRequest() {
        if let url = initialAction.request.url {
            recordHop(url: url.absoluteString, type: "popup-open", idfaInjected: false)
        }
        if initialAction.request.url != nil {
            webView.load(initialAction.request)
        }
    }

    private func recordHop(url: String, type: String, idfaInjected: Bool) {
        hopCount += 1
        hopBadge.text = "Hop \(hopCount)"
        if let host = URL(string: url)?.host {
            hostLabel.text = host
        }
        AppState.shared.appendRedirectHop(
            url: url,
            statusCodeOrType: type,
            idfaInjected: idfaInjected
        )
    }

    @objc private func openInSafari() {
        guard let url = webView.url ?? initialAction.request.url else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    @objc private func closeTapped() {
        dismissSelf()
    }

    private func dismissSelf() {
        guard !hasDismissed else { return }
        hasDismissed = true
        dismiss(animated: true)
    }

    private func handOffToAppStore(_ url: URL) {
        recordHop(url: url.absoluteString, type: "AppStore", idfaInjected: false)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.dismissSelf()
        }
    }
}

// MARK: - Navigation

extension TrackerRedirectViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if ExternalNavigation.isAppStoreURL(url) {
            decisionHandler(.cancel)
            handOffToAppStore(url)
            return
        }

        if ExternalNavigation.isExternalScheme(url) {
            recordHop(url: url.absoluteString, type: "external", idfaInjected: false)
            decisionHandler(.cancel)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

        if isMainFrame,
           let rewritten = IDFAURLRewriter.rewriteIfNeeded(url, idfa: AppState.shared.hardwareIDFA),
           rewritten.absoluteString != url.absoluteString
        {
            recordHop(url: rewritten.absoluteString, type: "idfa-rewrite", idfaInjected: true)
            decisionHandler(.cancel)
            webView.load(URLRequest(url: rewritten))
            return
        }

        // Intermediate main-frame hop (http/https navigations).
        if isMainFrame, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            recordHop(url: url.absoluteString, type: "navigation", idfaInjected: false)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           let url = http.url?.absoluteString
        {
            // Status-only log (hop badge already advanced on the matching navigationAction).
            AppState.shared.appendRedirectHop(
                url: url,
                statusCodeOrType: String(http.statusCode),
                idfaInjected: false
            )
            if let host = http.url?.host {
                hostLabel.text = host
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let host = webView.url?.host {
            hostLabel.text = host
        }
    }
}

extension TrackerRedirectViewController: WKUIDelegate {
    func webViewDidClose(_ webView: WKWebView) {
        // OAuth popup path: page `postMessage("oauth_done")` then `window.close()`.
        dismissSelf()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Nested window.open — load in this same popup to keep the chain alive.
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
