import UIKit
import AppTrackingTransparency
import CoreLocation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private let locationManager = CLLocationManager()
    private var didRequestTrackingThisLaunch = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Ensure a permanent device UUID exists before any later ff / bridge work.
        _ = AppState.shared.deviceUUID
        requestLocationAuthorizationIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // ATT must be requested while the app is active; Apple shows the system prompt once.
        requestTrackingAuthorizationIfNeeded()
    }

    // MARK: - Scene session lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    // MARK: - Privacy prompts

    private func requestTrackingAuthorizationIfNeeded() {
        guard !didRequestTrackingThisLaunch else { return }
        didRequestTrackingThisLaunch = true

        // Defer slightly so the first frame is on-screen before the system dialog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ATTrackingManager.requestTrackingAuthorization { status in
                DispatchQueue.main.async {
                    AppState.shared.refreshIDFA(trackingStatus: status)
                }
            }
        }
    }

    private func requestLocationAuthorizationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }
}
