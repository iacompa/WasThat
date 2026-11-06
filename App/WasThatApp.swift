import SwiftUI

@main
struct WasThatApp: App {
    @State private var model = EventsModel()

    var body: some Scene {
        // Quick check: menu bar panel (a global hotkey opens it too, from M2).
        MenuBarExtra {
            MenuPanelView()
                .environment(model)
        } label: {
            // Placeholder. A monochrome template of the app icon replaces this in M2.
            Image(systemName: "questionmark.bubble.fill")
        }
        .menuBarExtraStyle(.window)

        // Full history window. The Dock icon shows only while it's open.
        Window("WasThat", id: "history") {
            HistoryView()
                .environment(model)
        }
        .defaultSize(width: 860, height: 560)
    }
}
