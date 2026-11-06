import AppKit
import SwiftUI

/// Full history window. M0 placeholder: a plain table of recorder events.
struct HistoryView: View {
    @Environment(EventsModel.self) private var model

    var body: some View {
        Table(model.events) {
            TableColumn("When") { Text($0.time, format: .dateTime.hour().minute().second()) }
                .width(90)
            TableColumn("What") { Text($0.kind.rawValue) }
                .width(100)
            TableColumn("Process") { Text($0.processName) }
            TableColumn("Bundle ID") { Text($0.bundleID).foregroundStyle(.secondary) }
            TableColumn("Detail") { Text($0.detail) }
        }
        .navigationTitle("WasThat · history")
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}
