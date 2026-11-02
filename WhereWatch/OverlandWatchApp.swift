import SwiftUI

@main
struct OverlandWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchControlsView(model: model)
                .tint(.blue)
                .onAppear { model.start() }
        }
    }
}
