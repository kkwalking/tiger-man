import SwiftUI

@main
struct kBarApp: App {
    @NSApplicationDelegateAdaptor(AppCoordinator.self) private var appCoordinator

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
