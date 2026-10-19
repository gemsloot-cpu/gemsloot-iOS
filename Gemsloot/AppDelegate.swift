import UIKit
import CoreLocation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private let locationManager = CLLocationManager()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Ensure Keychain master seed + derived ids exist before WebView / ff bridge work.
        _ = AppState.shared.keychainUUID
        requestLocationAuthorizationIfNeeded()
        // ATT is requested from GemslootWebViewController.viewDidAppear (after UI is visible).
        return true
    }

    // MARK: - Scene session lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    // MARK: - Location

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
