import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .gemslootBackground
        window.rootViewController = GemslootWebViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

extension UIColor {
    /// App chrome / WebView shell background (`#101012`).
    static let gemslootBackground = UIColor(red: 16 / 255, green: 16 / 255, blue: 18 / 255, alpha: 1)
}
