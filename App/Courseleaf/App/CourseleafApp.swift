import SwiftUI
import UIKit
import DocumentCore
import Workspace

/// The app entry point. One `AppEnvironment` is created here and injected into
/// the view tree; nothing else constructs stores.
@main
struct CourseleafApp: App {
    @State private var appEnvironment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
                .preferredColorScheme(appEnvironment.settings.appearance.colorScheme)
                .task {
                    await appEnvironment.prepare()
                    await appEnvironment.openUITestNotebookIfNeeded()
                }
        }
        .commands { shortcuts }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                appEnvironment.setRecognitionPaused(true)
                Task { await appEnvironment.flushOpenDocuments() }
            case .active:
                appEnvironment.setRecognitionPaused(false)
            @unknown default:
                break
            }
        }
    }

    /// Hardware-keyboard shortcuts (docs/PRODUCT_SPEC.md §3.2).
    @CommandsBuilder
    private var shortcuts: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Notebook") { appEnvironment.router.isShowingNewNotebook = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("Quick Note") { appEnvironment.router.requestQuickCapture() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Find in Library") {
                appEnvironment.router.showSearch(scope: appEnvironment.router.openNotebookID.map { SearchScope.document($0) } ?? .library)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { appEnvironment.router.isShowingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
