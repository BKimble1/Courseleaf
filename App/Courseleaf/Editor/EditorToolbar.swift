import Foundation
import UIKit
import SwiftUI
import DocumentCore
import Editing

@MainActor
protocol EditorToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: EditorToolbar, didChangeState state: EditorToolState)
    func toolbarDidTapUndo(_ toolbar: EditorToolbar)
    func toolbarDidTapRedo(_ toolbar: EditorToolbar)
    func toolbar(_ toolbar: EditorToolbar, insertImageFrom source: EditorToolbar.ImageSource)
    func toolbar(_ toolbar: EditorToolbar, requestsCustomColorFrom anchor: UIView, current: RGBAColor, completion: @escaping (RGBAColor) -> Void)
    func toolbar(_ toolbar: EditorToolbar, requestsTextStyleFrom anchor: UIView)
    func toolbar(_ toolbar: EditorToolbar, didChooseLayout isHorizontalPaging: Bool)
    func toolbarDidRequestClearPage(_ toolbar: EditorToolbar)
}

/// Compact tool strip. Overflows into a menu at compact widths; the tool
/// cluster sits at the leading edge, or trailing for left-handed students so
/// the writing hand never covers it. Every item has a VoiceOver label.
final class EditorToolbar: UIView {
    enum ImageSource { case photos, camera, files }

    weak var delegate: EditorToolbarDelegate?
    var state = EditorToolState() { didSet { if state != oldValue { rebuild() } } }
    var canUndo = false { didSet { undoButton.isEnabled = canUndo } }
    var canRedo = false { didSet { redoButton.isEnabled = canRedo } }
    var isCompact = false { didSet { if isCompact != oldValue { rebuild() } } }
    var isLeftHanded = false { didSet { if isLeftHanded != oldValue { rebuild() } } }
    var isHorizontalPaging = false { didSet { if isHorizontalPaging != oldValue { rebuild() } } }
    var isReadingMode = false { didSet { if isReadingMode != oldValue { rebuild() } } }

    private let stack = UIStackView()
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private var toolButtons: [EditorTool: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        leadingConstraint = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingConstraint = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        leadingConstraint?.isActive = true
        configure(undoButton, symbol: "arrow.uturn.backward", label: "Undo")
        configure(redoButton, symbol: "arrow.uturn.forward", label: "Redo")
        undoButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.delegate?.toolbarDidTapUndo(self) }, for: .touchUpInside)
        redoButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.delegate?.toolbarDidTapRedo(self) }, for: .touchUpInside)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?

    private func configure(_ button: UIButton, symbol: String, label: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        button.configuration = config
        button.accessibilityLabel = label
    }

    func button(for tool: EditorTool) -> UIButton? { toolButtons[tool] }

    // MARK: Building

    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        toolButtons.removeAll()
        leadingConstraint?.isActive = !isLeftHanded
        trailingConstraint?.isActive = isLeftHanded

        var items: [UIView] = []
        if !isReadingMode {
            for kind in InkToolKind.allCases { items.append(toolButton(.ink(kind))) }
            items.append(toolButton(.eraser))
            items.append(toolButton(.lasso))
            if isCompact {
                items.append(insertMenuButton())
            } else {
                items.append(toolButton(.text))
                items.append(imageButton())
                items.append(toolButton(.shape(state.lastShapeKind)))
                items.append(toolButton(.tape))
            }
            items.append(separator())
        }
        items.append(undoButton)
        items.append(redoButton)
        items.append(moreButton())
        if isLeftHanded { items.reverse() }
        for item in items { stack.addArrangedSubview(item) }
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    private func separator() -> UIView {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 22).isActive = true
        view.isAccessibilityElement = false
        return view
    }

    private func isSelected(_ tool: EditorTool) -> Bool {
        switch (tool, state.tool) {
        case (.shape, .shape): return true
        default: return tool == state.tool
        }
    }

    private func toolButton(_ tool: EditorTool) -> UIButton {
        let button = UIButton(type: .system)
        let selected = isSelected(tool)
        var config = selected ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.image = UIImage(systemName: tool.symbolName)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        config.cornerStyle = .medium
        if selected { config.baseBackgroundColor = .tintColor.withAlphaComponent(0.18); config.baseForegroundColor = .tintColor }
        button.configuration = config
        button.accessibilityLabel = tool.displayName
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        button.accessibilityHint = selected ? "Double tap for options" : nil
        let menu = optionsMenu(for: tool)
        if selected, let menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        } else {
            button.addAction(UIAction { [weak self] _ in self?.select(tool) }, for: .touchUpInside)
            if let menu {
                button.menu = menu
                button.showsMenuAsPrimaryAction = false   // long-press opens options without selecting
            }
        }
        toolButtons[tool] = button
        return button
    }

    private func select(_ tool: EditorTool) {
        var s = state
        s.select(tool)
        state = s
        delegate?.toolbar(self, didChangeState: s)
    }

    private func update(_ mutate: (inout EditorToolState) -> Void) {
        var s = state
        mutate(&s)
        state = s
        delegate?.toolbar(self, didChangeState: s)
    }

    private func optionsMenu(for tool: EditorTool) -> UIMenu? {
        switch tool {
        case .ink(let kind):
            let preset = state.preset(for: kind)
            let widths = UIMenu(title: "Width", options: .displayInline, children: kind.widthPresets.map { width in
                UIAction(title: Self.widthTitle(width), state: abs(width - preset.width) < 0.01 ? .on : .off) { [weak self] _ in
                    self?.update { var p = $0.preset(for: kind); p.width = width; $0.setPreset(p, for: kind) }
                }
            })
            let palette = kind == .highlighter ? EditorToolState.highlighterPresets : EditorToolState.colorPresets
            var colorItems: [UIMenuElement] = palette.map { color in
                UIAction(title: Self.colorTitle(color), image: Self.swatch(color), state: color == preset.color ? .on : .off) { [weak self] _ in
                    self?.update { var p = $0.preset(for: kind); p.color = color; $0.setPreset(p, for: kind) }
                }
            }
            for color in state.recentColors.prefix(4) where !palette.contains(color) {
                colorItems.append(UIAction(title: "Recent \(color.hexString)", image: Self.swatch(color), state: color == preset.color ? .on : .off) { [weak self] _ in
                    self?.update { var p = $0.preset(for: kind); p.color = color; $0.setPreset(p, for: kind) }
                })
            }
            colorItems.append(UIAction(title: "Custom Color…", image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                guard let self, let anchor = self.toolButtons[tool] ?? self.stack.arrangedSubviews.first else { return }
                self.delegate?.toolbar(self, requestsCustomColorFrom: anchor, current: preset.color) { [weak self] color in
                    self?.update { var p = $0.preset(for: kind); p.color = color; $0.setPreset(p, for: kind) }
                }
            })
            let colors = UIMenu(title: "Color", options: .displayInline, children: colorItems)
            return UIMenu(title: kind.displayName, children: [widths, colors])
        case .eraser:
            let modes = EraserMode.allCases.map { mode in
                UIAction(title: mode.displayName, state: state.eraserMode == mode ? .on : .off) { [weak self] _ in
                    self?.update { $0.eraserMode = mode }
                }
            }
            let widths = [10.0, 20, 40].map { width in
                UIAction(title: Self.widthTitle(width), state: abs(state.eraserWidth - width) < 0.01 ? .on : .off) { [weak self] _ in
                    self?.update { $0.eraserWidth = width }
                }
            }
            return UIMenu(title: "Eraser", children: [
                UIMenu(title: "Mode", options: .displayInline, children: modes),
                UIMenu(title: "Pixel Eraser Size", options: .displayInline, children: widths),
            ])
        case .lasso:
            let modes = LassoMode.allCases.map { mode in
                UIAction(title: mode.displayName, state: state.lassoMode == mode ? .on : .off) { [weak self] _ in
                    self?.update { $0.lassoMode = mode }
                }
            }
            let filters: [(String, SelectionFilter)] = [("Ink", .ink), ("Text", .text), ("Images", .images), ("Shapes", .shapes), ("Tape", .tape)]
            let filterItems = filters.map { name, bit in
                UIAction(title: name, state: state.selectionFilter.contains(bit) ? .on : .off) { [weak self] _ in
                    self?.update { s in
                        var f = s.selectionFilter
                        if f.contains(bit) { f.remove(bit) } else { f.insert(bit) }
                        if f.isEmpty { f = .all }
                        s.selectionFilter = f
                    }
                }
            }
            return UIMenu(title: "Lasso", children: [
                UIMenu(title: "Shape", options: .displayInline, children: modes),
                UIMenu(title: "Selects", options: .displayInline, children: filterItems),
            ])
        case .shape:
            let kinds = ShapeKind.allCases.map { kind in
                UIAction(title: ShapeKindNames.name(kind), image: UIImage(systemName: ShapeKindNames.symbol(kind)),
                         state: state.tool == .shape(kind) ? .on : .off) { [weak self] _ in
                    self?.update { $0.select(.shape(kind)) }
                }
            }
            let widths = [1.0, 2, 4, 6].map { width in
                UIAction(title: Self.widthTitle(width), state: abs(state.shapeStrokeWidth - width) < 0.01 ? .on : .off) { [weak self] _ in
                    self?.update { $0.shapeStrokeWidth = width }
                }
            }
            let colors = EditorToolState.colorPresets.map { color in
                UIAction(title: Self.colorTitle(color), image: Self.swatch(color), state: state.shapeStrokeColor == color ? .on : .off) { [weak self] _ in
                    self?.update { $0.shapeStrokeColor = color; $0.noteColor(color) }
                }
            }
            return UIMenu(title: "Shape", children: [
                UIMenu(title: "Kind", options: .displayInline, children: kinds),
                UIMenu(title: "Line Width", options: .displayInline, children: widths),
                UIMenu(title: "Color", options: .displayInline, children: colors),
            ])
        case .text:
            return UIMenu(title: "Text", children: [
                UIAction(title: "Text Style…", image: UIImage(systemName: "textformat.size")) { [weak self] _ in
                    guard let self, let anchor = self.toolButtons[.text] else { return }
                    self.delegate?.toolbar(self, requestsTextStyleFrom: anchor)
                },
            ])
        case .tape:
            let colors = ([TapeContent().color] + EditorToolState.highlighterPresets).map { color in
                UIAction(title: Self.colorTitle(color), image: Self.swatch(color), state: state.tapeColor == color ? .on : .off) { [weak self] _ in
                    self?.update { $0.tapeColor = color }
                }
            }
            return UIMenu(title: "Tape Color", children: colors)
        case .image:
            return nil
        }
    }

    private func imageButton() -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "photo")
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        button.configuration = config
        button.accessibilityLabel = "Insert Image"
        button.menu = imageMenu()
        button.showsMenuAsPrimaryAction = true
        toolButtons[.image] = button
        return button
    }

    private func imageMenu() -> UIMenu {
        UIMenu(title: "Insert Image", children: [
            UIAction(title: "Photo Library", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                guard let self else { return }; self.delegate?.toolbar(self, insertImageFrom: .photos)
            },
            UIAction(title: "Camera", image: UIImage(systemName: "camera")) { [weak self] _ in
                guard let self else { return }; self.delegate?.toolbar(self, insertImageFrom: .camera)
            },
            UIAction(title: "Files", image: UIImage(systemName: "folder")) { [weak self] _ in
                guard let self else { return }; self.delegate?.toolbar(self, insertImageFrom: .files)
            },
        ])
    }

    private func insertMenuButton() -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "plus.circle")
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        button.configuration = config
        button.accessibilityLabel = "Insert"
        let tools: [EditorTool] = [.text, .shape(state.lastShapeKind), .tape]
        var children: [UIMenuElement] = tools.map { tool in
            UIAction(title: tool.displayName, image: UIImage(systemName: tool.symbolName), state: isSelected(tool) ? .on : .off) { [weak self] _ in
                self?.select(tool)
            }
        }
        children.append(imageMenu())
        button.menu = UIMenu(title: "Insert", children: children)
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func moreButton() -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis.circle")
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        button.configuration = config
        button.accessibilityLabel = "More"
        var children: [UIMenuElement] = [
            UIMenu(title: "Scrolling", options: .displayInline, children: [
                UIAction(title: "Vertical", image: UIImage(systemName: "arrow.up.arrow.down"), state: isHorizontalPaging ? .off : .on) { [weak self] _ in
                    guard let self else { return }; self.delegate?.toolbar(self, didChooseLayout: false)
                },
                UIAction(title: "Horizontal Pages", image: UIImage(systemName: "arrow.left.arrow.right"), state: isHorizontalPaging ? .on : .off) { [weak self] _ in
                    guard let self else { return }; self.delegate?.toolbar(self, didChooseLayout: true)
                },
            ]),
        ]
        if !isReadingMode {
            children.append(UIAction(title: "Clear Page", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }; self.delegate?.toolbarDidRequestClearPage(self)
            })
        }
        button.menu = UIMenu(children: children)
        button.showsMenuAsPrimaryAction = true
        return button
    }

    // MARK: Helpers

    static func widthTitle(_ width: Double) -> String {
        width == width.rounded() ? "\(Int(width)) pt" : String(format: "%.1f pt", width)
    }

    static func colorTitle(_ color: RGBAColor) -> String {
        switch color.hexString {
        case RGBAColor.black.hexString: return "Black"
        case "#1C4FD8FF": return "Blue"
        case "#D0312DFF": return "Red"
        case "#1E8E3EFF": return "Green"
        case "#F28C28FF": return "Orange"
        case "#7A3E9DFF": return "Purple"
        case "#6E6E73FF": return "Grey"
        case "#FFE600FF": return "Yellow"
        case "#7CF57AFF": return "Mint"
        case "#7ED0FFFF": return "Sky"
        case "#FF9BD3FF": return "Pink"
        case "#FFB05CFF": return "Peach"
        case "#F2C94CFF": return "Tape Yellow"
        default: return color.hexString
        }
    }

    static func swatch(_ color: RGBAColor) -> UIImage {
        let size = CGSize(width: 18, height: 18)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(color).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            UIColor.separator.setStroke()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)).stroke()
        }.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Text style popover

/// Font size, weight, design, alignment and colour for text boxes. Applies to
/// the selected text object (if any) and becomes the default for new boxes.
struct TextStylePopoverView: View {
    @State var style: TextStyleDefaults
    var onChange: (TextStyleDefaults) -> Void

    var body: some View {
        Form {
            Section("Size") {
                Stepper(value: $style.fontSize, in: 8...96, step: 1) {
                    Text("\(Int(style.fontSize)) pt")
                }
                .accessibilityLabel("Font size")
            }
            Section("Weight") {
                Picker("Weight", selection: $style.weight) {
                    ForEach(FontWeight.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Design") {
                Picker("Design", selection: $style.design) {
                    ForEach(FontDesign.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Alignment") {
                Picker("Alignment", selection: $style.alignment) {
                    Image(systemName: "text.alignleft").tag(TextAlignment.leading).accessibilityLabel("Leading")
                    Image(systemName: "text.aligncenter").tag(TextAlignment.center).accessibilityLabel("Center")
                    Image(systemName: "text.alignright").tag(TextAlignment.trailing).accessibilityLabel("Trailing")
                }
                .pickerStyle(.segmented)
            }
            Section("Color") {
                HStack(spacing: 10) {
                    ForEach(EditorToolState.colorPresets, id: \.hexString) { color in
                        Button {
                            style.color = color
                        } label: {
                            Circle()
                                .fill(Color(UIColor(color)))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(style.color == color ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: style.color == color ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(EditorToolbar.colorTitle(color))
                        .accessibilityAddTraits(style.color == color ? .isSelected : [])
                    }
                }
            }
        }
        .onChange(of: style) { _, newValue in onChange(newValue) }
        .frame(minWidth: 320, minHeight: 420)
    }
}
