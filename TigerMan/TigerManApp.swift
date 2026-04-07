import SwiftUI

@main
struct TigerManApp: App {
    @NSApplicationDelegateAdaptor(AppCoordinator.self) private var appCoordinator

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
