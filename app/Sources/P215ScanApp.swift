import SwiftUI
import AppKit

@main
struct P215ScanApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("P215 Scan", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 560)
                .task { await Snapshot.runIfRequested(state) }
        }
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") { state.showPreferences = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Import Images…") { state.presentImportPanel() }
                    .keyboardShortcut("i", modifiers: .command)
                Divider()
                Button("Scan") { state.requestScan() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Scan More Pages") { state.startScan(appending: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Save…") { state.showSaveSheet = true }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandMenu("Pages") {
                Toggle("Show Blank Pages", isOn: $state.showBlankPages)
                Divider()
                Button("Select All Pages") { state.selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Select Odd Pages") { state.selectOdd() }
                Button("Select Even Pages") { state.selectEven() }
                Divider()
                // Arrow keys rather than [ and ]: those need a modifier on
                // Swiss, French and German layouts, so the shortcut simply did
                // nothing on a non-US keyboard.
                Button("Rotate Left")  { state.rotate(by: -90) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Rotate Right") { state.rotate(by: 90) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Rotate 180°")  { state.rotate(by: 180) }
                Button("Straighten") { state.autoStraightenSelected() }
                Button("Trim to Contents") { state.autoCropSelected() }
                Divider()
                Button("Revert to Original") { state.revertSelected() }
                Button("Delete Selected") { state.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                Button("Undo Delete") { state.undoDelete() }
                    .keyboardShortcut("z", modifiers: .command)
            }
        }
    }
}
