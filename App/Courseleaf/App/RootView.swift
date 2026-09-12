import SwiftUI
import DocumentCore
import Workspace

/// The window's root: the library split view plus the shell sheets
/// (Settings, Search, Onboarding) and the one alert every screen reports to.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var router = env.router
        @Bindable var environment = env

        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView()
        } detail: {
            NavigationStack(path: $router.path) {
                detailRoot
                    .navigationDestination(for: AppRouter.Route.self) { route in
                        switch route {
                        case .notebook(let target):
                            NotebookScreen(target: target)
                        }
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Palette.accent)
        .appAlert($environment.alert)
        .sheet(isPresented: $router.isShowingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $router.isShowingSearch) {
            SearchView(initialScope: router.searchScope)
        }
        .fullScreenCover(isPresented: $router.isShowingOnboarding) {
            OnboardingView()
        }
        .onAppear {
            if !env.settings.hasSeenOnboarding { env.router.isShowingOnboarding = true }
        }
    }

    @ViewBuilder
    private var detailRoot: some View {
        switch env.router.sidebar {
        case .review:
            ReviewQueueView(courseID: nil)
        case .trash:
            TrashView()
        default:
            LibraryContentView(selection: env.router.sidebar)
        }
    }
}
