import GoogleSignIn
import SwiftUI
import UIKit

@main
struct ParcelPilotApp: App {
    @State private var coordinator = AppCoordinator()

    init() {
        if UserDefaults.standard.bool(forKey: "PPDisableAnimations") { UIView.setAnimationsEnabled(false) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coordinator)
                .tint(Theme.brand)
                // Google sign-in returns to the app through its URL scheme.
                .onOpenURL { url in _ = GIDSignIn.sharedInstance.handle(url) }
        }
    }
}
