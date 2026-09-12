import Foundation
import UIKit
import DocumentCore

/// Shows the session's durable save state (docs/ARCHITECTURE.md §7):
/// unsaved, saving, saved, failed (with retry).
final class SaveStatusView: UIView {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    var onRetry: (() -> Void)?
    private(set) var status: SaveStatus = .saved(at: Date(), latency: 0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [spinner, label, retryButton])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        retryButton.setTitle("Retry", for: .normal)
        retryButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        retryButton.isHidden = true
        spinner.hidesWhenStopped = true
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        update(status)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ status: SaveStatus) {
        self.status = status
        retryButton.isHidden = true
        switch status {
        case .unsaved(let pending):
            spinner.stopAnimating()
            label.text = pending > 0 ? "Unsaved changes" : "Edited"
            label.textColor = .secondaryLabel
        case .saving:
            spinner.startAnimating()
            label.text = "Saving…"
            label.textColor = .secondaryLabel
        case .saved:
            spinner.stopAnimating()
            label.text = "Saved"
            label.textColor = .secondaryLabel
        case .failed(let message, let retryable):
            spinner.stopAnimating()
            label.text = "Save failed: \(message)"
            label.textColor = .systemRed
            retryButton.isHidden = !retryable
        }
        accessibilityLabel = label.text
    }
}
