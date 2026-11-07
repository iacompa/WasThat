import AppKit
import SwiftUI

@main
struct WasThatApp: App {
    @State private var model: EventsModel

    init() {
        let model = EventsModel()
        _model = State(initialValue: model)
        DispatchQueue.main.async {
            model.start()
        }
    }

    var body: some Scene {
        Window("WasThat", id: "history") {
            HistoryView()
                .environment(model)
        }
        .defaultSize(width: 960, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About WasThat") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: AppInfo.publicVersion,
                        .version: "",
                    ])
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button(model.recorder.isEnabled ? "Quit WasThat — Keep Detection On" : "Quit WasThat") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }

        MenuBarExtra {
            MenuPanelView()
                .environment(model)
        } label: {
            Image(systemName: "questionmark.bubble.fill")
                .accessibilityLabel("WasThat")
                .help("Show recent sound activity")
        }
        .menuBarExtraStyle(.window)
    }
}
