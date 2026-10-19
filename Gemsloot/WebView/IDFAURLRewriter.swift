import Foundation

/// Rewrites empty / all-zero IDFA query params on known MMP & offerwall hosts.
enum IDFAURLRewriter {
    static let idfaQueryKeys: Set<String> = [
        "idfa",
        "ios_idfa",
        "advertising_id",
        "gaid",
        "idfv", // only fill when empty/zero and we have hardware IDFA (common mis-tag)
    ]

    /// Host suffixes / fragments that participate in offerwall → MMP chains.
    private static let knownHostMarkers: [String] = [
        "appsflyer.com",
        "adjust.com",
        "singular.net",
        "branch.io",
        "app.link",
        "torox",
        "ayetstudios",
        "ayet",
        "lootably",
        "bitlabs",
        "adgatemedia",
        "adgate",
        "adgem",
        "revu.co",
        "revu",
        "adjoe",
        "adjoe.zone",
        "androidplatform.net",
        "offerwall",
        "theoremreach",
        "adscendmedia",
        "pollfish",
        "ironsrc",
        "unityads",
    ]

    static func isKnownTrackingHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return knownHostMarkers.contains { lowered.contains($0) }
    }

    /// Returns a rewritten URL when IDFA params were filled; otherwise `nil`.
    static func rewriteIfNeeded(_ url: URL, idfa: String?) -> URL? {
        guard let idfa, !idfa.isEmpty else { return nil }
        guard let host = url.host, isKnownTrackingHost(host) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard var items = components.queryItems, !items.isEmpty else { return nil }

        var changed = false
        for index in items.indices {
            let name = items[index].name.lowercased()
            guard idfaQueryKeys.contains(name) else { continue }
            if isEmptyOrZeroIDFA(items[index].value) {
                items[index].value = idfa
                changed = true
            }
        }
        guard changed else { return nil }
        components.queryItems = items
        return components.url
    }

    static func isEmptyOrZeroIDFA(_ value: String?) -> Bool {
        guard let value else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let compact = trimmed.replacingOccurrences(of: "-", with: "").lowercased()
        return compact.allSatisfy { $0 == "0" }
    }
}

/// Shared App Store / external-scheme helpers for main + popup WebViews.
enum ExternalNavigation {
    static func isAppStoreURL(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "itms-apps" || scheme == "itms-appss" { return true }
        guard let host = url.host?.lowercased() else { return false }
        return host == "apps.apple.com"
            || host.hasSuffix(".apps.apple.com")
            || host == "itunes.apple.com"
            || host.hasSuffix(".itunes.apple.com")
    }

    static func isExternalScheme(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        switch scheme {
        case "itms-apps", "itms-appss", "mailto", "tg", "discord", "twitter", "fb", "instagram":
            return true
        default:
            return false
        }
    }

    static func isGemslootAuthCallback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard host == "gemsloot.com" || host.hasSuffix(".gemsloot.com") else { return false }
        return url.path.contains("/_api/auth")
    }
}
