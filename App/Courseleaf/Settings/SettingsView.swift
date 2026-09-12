import SwiftUI
import DocumentCore
import Workspace

/// App settings. Nothing here is an account setting: there is no account.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = env.settings

        NavigationStack {
            Form {
                Section {
                    Toggle("Pencil-only drawing", isOn: $settings.pencilOnly)
                        .accessibilityHint("When on, a finger pans and selects but never draws")
                    Toggle("Draw with a finger", isOn: $settings.fingerDrawing)
                        .accessibilityHint("When on, a finger draws and two fingers pan and zoom")
                    Toggle("Left-handed layout", isOn: $settings.leftHanded)
                        .accessibilityHint("Moves the main controls to the leading edge so your hand does not cover them")
                } header: {
                    Text("Input")
                } footer: {
                    Text("Palm rejection is Apple Pencil behaviour provided by the system. Two fingers always pan and zoom.")
                }

                Section {
                    Picker("Paper", selection: $settings.defaultPaperKind) {
                        ForEach(PaperKind.allCases, id: \.self) { kind in
                            Text(PaperKindNames.title(kind)).tag(kind)
                        }
                    }
                    Picker("Page size", selection: $settings.defaultPageSize) {
                        ForEach(PageSizeChoice.allCases) { size in
                            Text("\(size.title) (\(size.detail))").tag(size)
                        }
                    }
                    HStack {
                        Spacer()
                        PagePreviewView(template: .preset(settings.defaultPaperKind),
                                        pageSize: settings.defaultPageSize.pageSize)
                            .frame(width: 90, height: 116)
                        Spacer()
                    }
                } header: {
                    Text("New Notebook Defaults")
                } footer: {
                    Text(PaperKindNames.detail(settings.defaultPaperKind))
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(SettingsStore.Appearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Appearance")
                }

                Section("Storage and Backup") {
                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        Label("Storage, backup and the search index", systemImage: "internaldrive")
                    }
                }

                Section {
                    NavigationLink {
                        AccessibilityNotesView()
                    } label: {
                        Label("Accessibility", systemImage: "accessibility")
                    }
                    NavigationLink {
                        PurchasesView()
                    } label: {
                        Label("Purchases", systemImage: "cart")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About Courseleaf", systemImage: "info.circle")
                    }
                }

                Section {
                    Button {
                        env.settings.hasSeenOnboarding = false
                        dismiss()
                        env.router.isShowingOnboarding = true
                    } label: {
                        Label("Show the welcome screens again", systemImage: "sparkles")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// What the app does for accessibility, and what still needs a device check.
struct AccessibilityNotesView: View {
    var body: some View {
        List {
            Section {
                Label("Every control has a VoiceOver label, and cards carry actions for open, rename, move, duplicate, favourite, cover and delete.", systemImage: "hand.point.up.braille")
                Label("Text scales with Dynamic Type, including the largest accessibility sizes.", systemImage: "textformat.size")
                Label("Left-handed layout mirrors the primary controls so your writing hand never covers them.", systemImage: "hand.raised")
                Label("Colour is never the only signal: states are labelled in words as well.", systemImage: "eye")
            } header: {
                Text("What is built in")
            }
            Section {
                Text("Handwriting stays a picture of your strokes; it is never replaced by recognized text. Recognition only feeds search.")
                Text("Some behaviours — Apple Pencil latency, palm rejection and Scribble — can only be verified on a physical iPad and are not claimed here.")
            } header: {
                Text("Honest limits")
            }
        }
        .navigationTitle("Accessibility")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Version, support and privacy links. The URLs are placeholders until the
/// owner publishes the real pages (docs/RELEASE_CHECKLIST.md).
struct AboutView: View {
    private var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(marketing) (\(build))"
    }

    var body: some View {
        List {
            Section("This build") {
                LabeledContent("Version", value: version)
                LabeledContent("Library", value: "Application Support/Courseleaf/Library")
            }
            Section {
                Text("Your notebooks stay on this iPad. There is no account, no sync service and no analytics. Back up with “Back up library…”, or through your own iPad backup.")
            } header: {
                Text("Your files")
            }
            Section {
                Link(destination: URL(string: "https://example.invalid/courseleaf/support")!) {
                    Label("Support page (placeholder link)", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://example.invalid/courseleaf/privacy")!) {
                    Label("Privacy policy (placeholder link)", systemImage: "hand.raised")
                }
            } header: {
                Text("Support")
            } footer: {
                Text("These addresses are placeholders. The real support and privacy pages are published before release.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
