import Foundation
import SwiftUI
import DocumentCore
import Workspace

/// A failure surfaced to the student. Nothing in the shell traps or crashes on
/// a service error: every call site turns the error into one of these.
struct AppAlert: Identifiable, Equatable {
    var id = UUID()
    /// Short, plain title, e.g. "Could not create the notebook".
    var title: String
    /// What happened, in the student's terms.
    var message: String
    /// Set when the action can sensibly be tried again.
    var isRetryable: Bool = false

    static func == (lhs: AppAlert, rhs: AppAlert) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.message == rhs.message
    }
}

/// Turns service errors into plain English. `WorkspaceError` is not a
/// `LocalizedError`, so the wording lives here rather than in the package.
enum AppErrorText {
    static func message(for error: Error) -> String {
        if let workspace = error as? WorkspaceError { return message(for: workspace) }
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        if error is CancellationError { return "The operation was cancelled." }
        return (error as NSError).localizedDescription
    }

    static func message(for error: WorkspaceError) -> String {
        switch error {
        case .documentNotFound:
            return "That notebook is no longer in your library."
        case .folderNotFound:
            return "That folder is no longer in your library."
        case .documentNeedsNewerApp(_, let schemaVersion):
            return "This notebook was made with a newer version of the app (format \(schemaVersion)). Update the app to open it. It is shown read-only and nothing was changed."
        case .documentAlreadyOpen:
            return "That notebook is already open."
        case .importFailed(let reason):
            return "The file could not be imported: \(reason)"
        case .unsupportedFile(let reason):
            return "That kind of file cannot be imported: \(reason)"
        case .cancelled:
            return "The operation was cancelled. Nothing was changed."
        case .storage(let reason):
            return "Your notebooks could not be written to: \(reason)"
        case .archive(let reason):
            return "The archive could not be read or written: \(reason)"
        case .catalogUnavailable(let reason):
            return "The search index is unavailable: \(reason) Your notebooks are unaffected; you can rebuild the index in Settings."
        }
    }

    /// True when retrying the same action makes sense.
    static func isRetryable(_ error: Error) -> Bool {
        if let workspace = error as? WorkspaceError {
            switch workspace {
            case .storage, .catalogUnavailable, .archive: return true
            default: return false
            }
        }
        return false
    }
}

extension View {
    /// Presents `alert` as a standard alert with an OK button, plus Retry when
    /// the failure is retryable and the caller supplied an action.
    func appAlert(_ alert: Binding<AppAlert?>, retry: (() -> Void)? = nil) -> some View {
        let isPresented = Binding<Bool>(
            get: { alert.wrappedValue != nil },
            set: { presented in if !presented { alert.wrappedValue = nil } })
        return self.alert(alert.wrappedValue?.title ?? "Something went wrong",
                          isPresented: isPresented,
                          presenting: alert.wrappedValue) { value in
            if value.isRetryable, let retry {
                Button("Try Again") { alert.wrappedValue = nil; retry() }
            }
            Button("OK", role: .cancel) { alert.wrappedValue = nil }
        } message: { value in
            Text(value.message)
        }
    }
}
