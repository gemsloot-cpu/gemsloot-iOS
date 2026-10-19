import SwiftUI
import UIKit
import AppTrackingTransparency
import WebKit

/// Step 4 Diagnostic HUD — presented from 3-finger tap or shake.
struct TrackingDiagnosticsSheet: View {
    var onApplyAndReload: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var deviceHeaderMode: AppState.DeviceHeaderMode = AppState.shared.deviceHeaderMode
    @State private var ffLockMode: AppState.FfLockMode = AppState.shared.ffLockMode
    @State private var ffBodyExpanded = false
    @State private var statusMessage: String?
    @State private var copiedFlash: String?
    @State private var refreshToken = UUID()

    private let bg = Color(red: 16 / 255, green: 16 / 255, blue: 18 / 255)
    private let card = Color(white: 0.12)
    private let accent = Color(red: 0.45, green: 0.78, blue: 0.55)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identitySection
                    bridgeSection
                    ffTelemetrySection
                    redirectLogSection
                    storageSection
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .id(refreshToken)
            }
            .background(bg.ignoresSafeArea())
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            deviceHeaderMode = AppState.shared.deviceHeaderMode
            ffLockMode = AppState.shared.ffLockMode
        }
    }

    // MARK: - Section 1

    private var identitySection: some View {
        sectionCard(title: "Identity & Permissions") {
            HStack(spacing: 8) {
                Text("ATT")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(attStatusLabel)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(attBadgeColor.opacity(0.25))
                    .foregroundStyle(attBadgeColor)
                    .clipShape(Capsule())
            }

            if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
                Button {
                    requestATTFromHUD()
                } label: {
                    labelButton("Request ATT Permission", systemImage: "hand.raised.fill")
                }
            }

            copyRow(label: "Hardware IDFA", value: AppState.shared.hardwareIDFA ?? "(unavailable)")
            copyRow(label: "keychainUUID", value: AppState.shared.keychainUUID)
            copyRow(label: "deterministicBase36Hash", value: AppState.shared.deterministicBase36Hash)
            copyRow(label: "deterministicHex16", value: AppState.shared.deterministicHex16)
        }
    }

    private func requestATTFromHUD() {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else {
            AppState.shared.refreshIDFA()
            bump()
            return
        }
        ATTrackingManager.requestTrackingAuthorization { status in
            DispatchQueue.main.async {
                AppState.shared.refreshIDFA(trackingStatus: status)
                statusMessage = "ATT updated: \(Self.attLabel(for: status))."
                bump()
            }
        }
    }

    // MARK: - Section 2

    private var bridgeSection: some View {
        sectionCard(title: "Bridge & Header Configuration") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Device header")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Device header", selection: $deviceHeaderMode) {
                    Text("Off").tag(AppState.DeviceHeaderMode.off)
                    Text("ios").tag(AppState.DeviceHeaderMode.ios)
                    Text("android").tag(AppState.DeviceHeaderMode.android)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("ff lock mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("ff lock mode", selection: $ffLockMode) {
                    Text("B Locked").tag(AppState.FfLockMode.branchB_Locked)
                    Text("A Capacitor").tag(AppState.FfLockMode.branchA_Capacitor)
                    Text("Pass").tag(AppState.FfLockMode.passthrough)
                }
                .pickerStyle(.segmented)
            }

            Button {
                AppState.shared.deviceHeaderMode = deviceHeaderMode
                AppState.shared.ffLockMode = ffLockMode
                onApplyAndReload()
                statusMessage = "Applied \(ffLockMode.rawValue) / Device:\(deviceHeaderMode.rawValue) — reloading…"
                bump()
            } label: {
                labelButton("Apply & Reload WebView", systemImage: "arrow.clockwise")
            }

            Button(role: .destructive) {
                AppState.shared.clearLockedFfBody()
                statusMessage = "Cleared branchB_Locked ff snapshot."
                bump()
            } label: {
                labelButton("Reset Snapshot", systemImage: "trash")
            }
        }
    }

    // MARK: - Section 3

    private var ffTelemetrySection: some View {
        sectionCard(title: "/_api/ff Telemetry") {
            if let ff = AppState.shared.lastFfTelemetry {
                metaRow("Timestamp", Self.timeFormatter.string(from: ff.recordedAt))
                metaRow("HTTP status", ff.status.map(String.init) ?? "—")
                metaRow("Active mode", AppState.shared.ffLockMode.rawValue)
                metaRow("URL", ff.url)

                DisclosureGroup(isExpanded: $ffBodyExpanded) {
                    ScrollView(.vertical) {
                        Text(prettyJSON(ff.bodyJSON))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                    .padding(8)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button("Copy JSON body") {
                        copy(ff.bodyJSON, flash: "ff body")
                    }
                    .font(.caption.weight(.semibold))
                } label: {
                    Text("JSON body preview")
                        .font(.subheadline.weight(.medium))
                }
            } else {
                Text("No ff request intercepted yet.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Section 4

    private var redirectLogSection: some View {
        sectionCard(title: "Offer Redirect Hop Log") {
            let hops = Array(AppState.shared.redirectLogs.reversed())
            if hops.isEmpty {
                Text("No redirect hops logged.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(Array(hops.enumerated()), id: \.element.id) { offset, hop in
                    let index = hops.count - offset
                    Button {
                        copy(hop.url, flash: "hop URL")
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Hop \(index)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(accent)
                                Text(hop.statusCodeOrType)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if hop.idfaInjected {
                                    Text("IDFA")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(accent.opacity(0.25))
                                        .foregroundStyle(accent)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(Self.timeFormatter.string(from: hop.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(URL(string: hop.url)?.host ?? hop.url)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(hop.url)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(role: .destructive) {
                AppState.shared.clearRedirectLogs()
                statusMessage = "Cleared redirect logs."
                bump()
            } label: {
                labelButton("Clear Redirect Logs", systemImage: "eraser")
            }
        }
    }

    // MARK: - Section 5

    private var storageSection: some View {
        sectionCard(title: "Storage Maintenance") {
            Button(role: .destructive) {
                clearThirdPartyOfferwallCache()
            } label: {
                labelButton(
                    "Clear 3rd-Party Offerwall Cache (Keep Gemsloot Session)",
                    systemImage: "externaldrive.badge.xmark"
                )
            }
            Text("Removes WKWebsiteDataStore records whose displayName does not contain gemsloot.com or google.com.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func copyRow(label: String, value: String) -> some View {
        Button {
            copy(value, flash: label)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(accent)
                }
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labelButton(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var attStatusLabel: String {
        Self.attLabel(for: ATTrackingManager.trackingAuthorizationStatus)
    }

    private static func attLabel(for status: ATTrackingManager.AuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .notDetermined: return "Not Determined"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private var attBadgeColor: Color {
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return accent
        case .denied, .restricted: return .orange
        case .notDetermined: return .yellow
        @unknown default: return .gray
        }
    }

    private func copy(_ value: String, flash: String) {
        UIPasteboard.general.string = value
        copiedFlash = flash
        statusMessage = "Copied \(flash)."
    }

    private func bump() {
        refreshToken = UUID()
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8)
        else { return raw }
        return text
    }

    private func clearThirdPartyOfferwallCache() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let victims = records.filter { record in
                let name = record.displayName.lowercased()
                let keep = name.contains("gemsloot.com") || name.contains("google.com")
                return !keep
            }
            store.removeData(ofTypes: types, for: victims) {
                DispatchQueue.main.async {
                    statusMessage = "Cleared \(victims.count) 3rd-party data record(s); gemsloot.com / google.com kept."
                    bump()
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}

// MARK: - UIKit host

enum TrackingDiagnosticsPresenter {
    static func makeHostingController(onApplyAndReload: @escaping () -> Void) -> UIViewController {
        let view = TrackingDiagnosticsSheet(onApplyAndReload: onApplyAndReload)
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = UIColor(red: 16 / 255, green: 16 / 255, blue: 18 / 255, alpha: 1)
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        return host
    }
}
