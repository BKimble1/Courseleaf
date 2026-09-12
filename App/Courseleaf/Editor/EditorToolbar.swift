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
    func toolbar(_ toolbar: EditorToolbar, requestsFavoritesEditorFrom anchor: UIView)
    func toolbar(_ toolbar: EditorToolbar, didChooseLayout isHorizontalPaging: Bool)
    func toolbarDidRequestClearPage(_ toolbar: EditorToolbar)
}

/// The writing controls, as one persistent row under the navigation bar.
///
/// The page is the point of the screen, so this is a single row of ~44pt
/// targets with small glyphs, not a panel. Everything a student reaches for
/// while writing is a single tap: the six tools, three widths for the active
/// tool, a row of colours, and saved favourites that carry tool, colour and
/// width together. Text, images, tape and page options stay one level away in
/// the Insert and More menus so they do not crowd the writing controls.
///
/// It updates in place. A colour tap changes a few button configurations; the
/// views are rebuilt only when the layout tier or the favourites list changes,
/// so focus, popover anchors and the menu you have open survive an edit.
final class EditorToolbar: UIView {
    enum ImageSource { case photos, camera, files }

    /// How much of the toolbar fits. Chosen from the available width alone, so
    /// it is a pure function and `EditorToolbarLayoutTests` can check the
    /// breakpoints without building a window.
    enum Tier: Int, Hashable {
        case compact, medium, regular

        static func tier(forWidth width: CGFloat) -> Tier {
            if width >= 1000 { return .regular }
            if width >= 760 { return .medium }
            return .compact
        }

        /// Tools shown directly. The rest move into the More menu.
        var directTools: [EditorTool] {
            switch self {
            case .regular, .medium:
                return [.ink(.pen), .ink(.pencil), .ink(.highlighter), .eraser, .lasso]
            case .compact:
                // The current tool, the eraser and the lasso are what a student
                // cannot work without at a narrow width.
                return [.ink(.pen), .ink(.highlighter), .eraser, .lasso]
            }
        }

        var colorCount: Int {
            switch self {
            case .regular: return 6
            case .medium: return 4
            case .compact: return 3
            }
        }

        var favoriteCount: Int {
            switch self {
            case .regular: return 5
            case .medium: return 3
            case .compact: return 2
            }
        }

        var showsShapeTool: Bool { self != .compact }
        var showsInsertButton: Bool { true }
    }

    weak var delegate: EditorToolbarDelegate?

    var state = EditorToolState() {
        didSet {
            guard state != oldValue else { return }
            if state.favorites != oldValue.favorites { rebuild() } else { updateControls() }
        }
    }
    var canUndo = false { didSet { undoButton.isEnabled = canUndo } }
    var canRedo = false { didSet { redoButton.isEnabled = canRedo } }
    var isLeftHanded = false { didSet { if isLeftHanded != oldValue { applyAlignment() } } }
    var isHorizontalPaging = false { didSet { if isHorizontalPaging != oldValue { updateControls() } } }
    var isReadingMode = false { didSet { if isReadingMode != oldValue { rebuild() } } }

    /// Available width for the row; the owner sets it from its own layout.
    var availableWidth: CGFloat = 1024 {
        didSet {
            let next = Tier.tier(forWidth: availableWidth)
            guard next != tier else { return }
            tier = next
            rebuild()
        }
    }
    private(set) var tier: Tier = .regular

    // Views are kept, not recreated: the whole point of the rebuild rules above.
    private let scroller = UIScrollView()
    private let stack = UIStackView()
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private var toolButtons: [EditorTool: UIButton] = [:]
    private var colorButtons: [UIButton] = []
    private var widthButtons: [UIButton] = []
    private var favoriteButtons: [UUID: UIButton] = [:]
    private var favoriteOrder: [UUID] = []
    private var leadingAlignment: NSLayoutConstraint?
    private var trailingAlignment: NSLayoutConstraint?

    static let controlHeight: CGFloat = 44
    static let toolWidth: CGFloat = 40
    static let swatchWidth: CGFloat = 34

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        scroller.clipsToBounds = true
        addSubview(scroller)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)

        NSLayoutConstraint.activate([
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
        ])
        // The row hugs the leading edge, or the trailing edge for a left-handed
        // student. Handedness moves the group; it never reverses the controls
        // inside it, because a toolbar that reads backwards is not a mirror.
        leadingAlignment = stack.leadingAnchor.constraint(equalTo: scroller.frameLayoutGuide.leadingAnchor)
        trailingAlignment = stack.trailingAnchor.constraint(equalTo: scroller.frameLayoutGuide.trailingAnchor)
        leadingAlignment?.priority = .defaultHigh
        trailingAlignment?.priority = .defaultHigh
        applyAlignment()

        configure(undoButton, symbol: "arrow.uturn.backward", label: "Undo")
        configure(redoButton, symbol: "arrow.uturn.forward", label: "Redo")
        configure(insertButton, symbol: "plus", label: "Insert")
        configure(moreButton, symbol: "ellipsis", label: "More")
        // Stable identifiers so a UI test names a control rather than guessing
        // at its position or its localised label.
        undoButton.accessibilityIdentifier = "toolbar.undo"
        redoButton.accessibilityIdentifier = "toolbar.redo"
        insertButton.accessibilityIdentifier = "toolbar.insert"
        moreButton.accessibilityIdentifier = "toolbar.more"
        undoButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.delegate?.toolbarDidTapUndo(self) }, for: .touchUpInside)
        redoButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.delegate?.toolbarDidTapRedo(self) }, for: .touchUpInside)
        insertButton.showsMenuAsPrimaryAction = true
        moreButton.showsMenuAsPrimaryAction = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.controlHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 { availableWidth = bounds.width }
    }

    func button(for tool: EditorTool) -> UIButton? { toolButtons[tool] }
    func favoriteButton(id: UUID) -> UIButton? { favoriteButtons[id] }
    var colorSwatchButtons: [UIButton] { colorButtons }
    var widthPresetButtons: [UIButton] { widthButtons }

    private func applyAlignment() {
        leadingAlignment?.isActive = !isLeftHanded
        trailingAlignment?.isActive = isLeftHanded
    }

    // MARK: Building

    /// Recreates the row. Called only when the layout tier, the favourites list
    /// or reading mode changes — never for an ordinary colour or width tap.
    private func rebuild() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        toolButtons.removeAll()
        colorButtons.removeAll()
        widthButtons.removeAll()
        favoriteButtons.removeAll()
        favoriteOrder.removeAll()

        guard !isReadingMode else {
            stack.addArrangedSubview(undoButton)
            stack.addArrangedSubview(redoButton)
            stack.addArrangedSubview(moreButton)
            updateControls()
            return
        }

        for tool in tier.directTools { stack.addArrangedSubview(makeToolButton(tool)) }
        if tier.showsShapeTool { stack.addArrangedSubview(makeToolButton(.shape(state.lastShapeKind))) }
        stack.addArrangedSubview(makeSeparator())

        for index in 0..<3 { stack.addArrangedSubview(makeWidthButton(index: index)) }
        stack.addArrangedSubview(makeSeparator())

        for index in 0..<tier.colorCount { stack.addArrangedSubview(makeColorButton(index: index)) }
        stack.addArrangedSubview(makeSeparator())

        for (index, favorite) in state.favorites.prefix(tier.favoriteCount).enumerated() {
            favoriteOrder.append(favorite.id)
            stack.addArrangedSubview(makeFavoriteButton(favorite, index: index))
        }
        if !state.favorites.isEmpty { stack.addArrangedSubview(makeSeparator()) }

        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)
        if tier.showsInsertButton { stack.addArrangedSubview(insertButton) }
        stack.addArrangedSubview(moreButton)
        updateControls()
    }

    /// Everything that changes with state, applied to the existing buttons.
    private func updateControls() {
        for (tool, button) in toolButtons { applyToolAppearance(button, tool: tool) }

        let widths = state.widthPresetsForActiveTool
        for (index, button) in widthButtons.enumerated() {
            guard index < widths.count else { button.isHidden = true; continue }
            button.isHidden = false
            applyWidthAppearance(button, width: widths[index])
        }

        let palette = state.paletteForActiveTool
        for (index, button) in colorButtons.enumerated() {
            guard index < palette.count else { button.isHidden = true; continue }
            button.isHidden = false
            applyColorAppearance(button, color: palette[index])
        }

        for id in favoriteOrder {
            guard let button = favoriteButtons[id], let favorite = state.favorites.first(where: { $0.id == id }) else { continue }
            applyFavoriteAppearance(button, favorite: favorite)
        }

        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
        insertButton.menu = insertMenu()
        moreButton.menu = moreMenu()
    }

    private func configure(_ button: UIButton, symbol: String, label: String, width: CGFloat = EditorToolbar.toolWidth) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)?.applyingSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        config.contentInsets = .zero
        config.cornerStyle = .medium
        button.configuration = config
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        // ~44pt of target, whatever the glyph inside measures: the icon stays
        // small so the page keeps the screen, the tap area does not.
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true
    }

    private func makeSeparator() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isAccessibilityElement = false
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 9),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 22),
            line.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    // MARK: Tools

    private func makeToolButton(_ tool: EditorTool) -> UIButton {
        let button = UIButton(type: .system)
        configure(button, symbol: tool.symbolName, label: tool.displayName)
        // A tap always selects. Options are a long press or the More menu, so a
        // single tap on the tool you are already using is never swallowed by a
        // menu you did not ask for.
        button.addAction(UIAction { [weak self] _ in self?.select(tool) }, for: .touchUpInside)
        button.showsMenuAsPrimaryAction = false
        button.menu = optionsMenu(for: tool)
        button.accessibilityIdentifier = "toolbar.tool.\(EditorToolbar.identifier(for: tool))"
        toolButtons[tool] = button
        applyToolAppearance(button, tool: tool)
        return button
    }

    private func isSelected(_ tool: EditorTool) -> Bool {
        switch (tool, state.tool) {
        case (.shape, .shape): return true
        default: return tool == state.tool
        }
    }

    private func applyToolAppearance(_ button: UIButton, tool: EditorTool) {
        let selected = isSelected(tool)
        var config = button.configuration ?? UIButton.Configuration.plain()
        config.background = selectedBackground(selected)
        config.baseForegroundColor = selected ? .tintColor : .label
        if case .ink(let kind) = tool {
            // The glyph carries the tool's own colour so the row says what it
            // will draw with, not just which tool is picked.
            config.baseForegroundColor = selected ? UIColor(state.preset(for: kind).color) : .label
        }
        button.configuration = config
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        button.accessibilityHint = "Long press for options"
        if case .ink(let kind) = tool {
            let preset = state.preset(for: kind)
            button.accessibilityValue = "\(EditorPalette.name(for: preset.color)), \(Self.widthTitle(preset.width))"
        }
        button.menu = optionsMenu(for: tool)
    }

    private func selectedBackground(_ selected: Bool) -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.clear()
        if selected {
            background.backgroundColor = UIColor.tintColor.withAlphaComponent(0.16)
            background.cornerRadius = 10
            background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        }
        return background
    }

    private func select(_ tool: EditorTool) {
        update { $0.select(tool) }
    }

    private func update(_ mutate: (inout EditorToolState) -> Void) {
        var s = state
        mutate(&s)
        guard s != state else { return }
        state = s
        delegate?.toolbar(self, didChangeState: s)
    }

    // MARK: Widths

    private func makeWidthButton(index: Int) -> UIButton {
        let button = UIButton(type: .system)
        configure(button, symbol: "minus", label: "Width", width: Self.swatchWidth)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let widths = self.state.widthPresetsForActiveTool
            guard index < widths.count else { return }
            self.update { $0.applyWidth(widths[index]) }
        }, for: .touchUpInside)
        button.accessibilityIdentifier = "toolbar.width.\(index)"
        widthButtons.append(button)
        return button
    }

    private func applyWidthAppearance(_ button: UIButton, width: Double) {
        let selected = abs(state.activeWidth - width) < 0.01
        var config = button.configuration ?? UIButton.Configuration.plain()
        config.image = Self.widthGlyph(width: width, color: UIColor(state.activeColor))
        config.background = selectedBackground(selected)
        button.configuration = config
        button.accessibilityLabel = "Width \(Self.widthTitle(width))"
        button.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    /// A line whose thickness is the preset, so the row shows the width rather
    /// than naming it. Capped so a 32pt highlighter does not become a block.
    static func widthGlyph(width: Double, color: UIColor) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        let thickness = min(max(CGFloat(width) * 0.8, 1.5), 11)
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            let rect = CGRect(x: 1, y: (size.height - thickness) / 2, width: size.width - 2, height: thickness)
            UIBezierPath(roundedRect: rect, cornerRadius: thickness / 2).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    // MARK: Colours

    private func makeColorButton(index: Int) -> UIButton {
        let button = UIButton(type: .system)
        configure(button, symbol: "circle.fill", label: "Color", width: Self.swatchWidth)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let palette = self.state.paletteForActiveTool
            guard index < palette.count else { return }
            self.update { $0.applyColor(palette[index]) }
        }, for: .touchUpInside)
        button.menu = UIMenu(children: [
            UIAction(title: "Custom Colour…", image: UIImage(systemName: "paintpalette")) { [weak self, weak button] _ in
                guard let self, let button else { return }
                self.delegate?.toolbar(self, requestsCustomColorFrom: button, current: self.state.activeColor) { [weak self] color in
                    self?.update { $0.applyColor(color) }
                }
            },
        ])
        button.accessibilityIdentifier = "toolbar.color.\(index)"
        colorButtons.append(button)
        return button
    }

    private func applyColorAppearance(_ button: UIButton, color: RGBAColor) {
        let selected = state.activeColor == color
        var config = button.configuration ?? UIButton.Configuration.plain()
        config.image = Self.swatch(color, selected: selected)
        config.background = .clear()
        button.configuration = config
        button.accessibilityLabel = EditorPalette.name(for: color)
        button.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    // MARK: Favourites

    private func makeFavoriteButton(_ favorite: ToolFavorite, index: Int) -> UIButton {
        let button = UIButton(type: .system)
        configure(button, symbol: favorite.kind.symbolName, label: favorite.displayName)
        let id = favorite.id
        button.addAction(UIAction { [weak self] _ in
            guard let self, let current = self.state.favorites.first(where: { $0.id == id }) else { return }
            self.update { $0.applyFavorite(current) }
        }, for: .touchUpInside)
        button.menu = UIMenu(children: [
            UIAction(title: "Edit Favourites…", image: UIImage(systemName: "slider.horizontal.3")) { [weak self, weak button] _ in
                guard let self, let button else { return }
                self.delegate?.toolbar(self, requestsFavoritesEditorFrom: button)
            },
            UIAction(title: "Remove from Favourites", image: UIImage(systemName: "star.slash"), attributes: .destructive) { [weak self] _ in
                self?.update { $0.removeFavorite(id: id) }
            },
        ])
        button.accessibilityIdentifier = "toolbar.favorite.\(index)"
        favoriteButtons[favorite.id] = button
        applyFavoriteAppearance(button, favorite: favorite)
        return button
    }

    private func applyFavoriteAppearance(_ button: UIButton, favorite: ToolFavorite) {
        let selected = state.matchingFavorite?.id == favorite.id
        var config = button.configuration ?? UIButton.Configuration.plain()
        config.image = Self.favoriteGlyph(favorite, selected: selected)
        config.background = selectedBackground(selected)
        button.configuration = config
        button.accessibilityLabel = favorite.displayName
        button.accessibilityValue = Self.widthTitle(favorite.width)
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        button.accessibilityHint = "Long press to edit favourites"
    }

    /// The tool's symbol over a bar in its own colour and width: the preview
    /// says what the favourite writes like before it is picked.
    static func favoriteGlyph(_ favorite: ToolFavorite, selected: Bool) -> UIImage {
        let size = CGSize(width: 24, height: 26)
        let color = UIColor(favorite.color)
        let symbol = UIImage(systemName: favorite.kind.symbolName)?
            .applyingSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        return UIGraphicsImageRenderer(size: size).image { _ in
            symbol?.withTintColor(selected ? color : .label, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: (size.width - 16) / 2, y: 0, width: 16, height: 16))
            let thickness = min(max(CGFloat(favorite.width) * 0.7, 2), 7)
            color.setFill()
            let bar = CGRect(x: 2, y: size.height - thickness - 1, width: size.width - 4, height: thickness)
            UIBezierPath(roundedRect: bar, cornerRadius: thickness / 2).fill()
        }.withRenderingMode(.alwaysOriginal)
    }

    // MARK: Menus

    private func optionsMenu(for tool: EditorTool) -> UIMenu? {
        switch tool {
        case .ink(let kind):
            let preset = state.preset(for: kind)
            let widths = UIMenu(title: "Width", options: .displayInline, children: kind.widthPresets.map { width in
                UIAction(title: Self.widthTitle(width), state: abs(width - preset.width) < 0.01 ? .on : .off) { [weak self] _ in
                    self?.update { var p = $0.preset(for: kind); p.width = width; $0.setPreset(p, for: kind); $0.select(.ink(kind)) }
                }
            })
            let palette = kind == .highlighter ? EditorToolState.highlighterPresets : EditorToolState.colorPresets
            var colorItems: [UIMenuElement] = palette.map { color in
                UIAction(title: EditorPalette.name(for: color), image: Self.swatch(color, selected: false),
                         state: color == preset.color ? .on : .off) { [weak self] _ in
                    self?.update { var p = $0.preset(for: kind); p.color = color; $0.setPreset(p, for: kind); $0.select(.ink(kind)) }
                }
            }
            for color in state.recentColors.prefix(4) where !palette.contains(color) {
                colorItems.append(UIAction(title: EditorPalette.name(for: color), image: Self.swatch(color, selected: false),
                                           state: color == preset.color ? .on : .off) { [weak self] _ in
                    self?.update { var p = $0.preset(for: kind); p.color = color; $0.setPreset(p, for: kind); $0.select(.ink(kind)) }
                })
            }
            colorItems.append(UIAction(title: "Custom Colour…", image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                guard let self, let anchor = self.toolButtons[tool] ?? self.stack.arrangedSubviews.first else { return }
                self.delegate?.toolbar(self, requestsCustomColorFrom: anchor, current: preset.color) { [weak self] color in
                    self?.update { var p = $0.preset(for: kind); p.color = color; $0.setPreset(p, for: kind) }
                }
            })
            let colors = UIMenu(title: "Colour", options: .displayInline, children: colorItems)
            let favorite = UIAction(title: "Save as Favourite", image: UIImage(systemName: "star")) { [weak self] _ in
                self?.update { $0.addFavoriteFromCurrentTool() }
            }
            return UIMenu(title: kind.displayName, children: [widths, colors, UIMenu(options: .displayInline, children: [favorite])])
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
            return UIMenu(title: "Shape", children: [
                UIMenu(title: "Kind", options: .displayInline, children: kinds),
                UIMenu(title: "Line Width", options: .displayInline, children: widths),
            ])
        case .text, .image, .tape:
            return nil
        }
    }

    private func insertMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: "Text Box", image: UIImage(systemName: "textformat"),
                     state: isSelected(.text) ? .on : .off) { [weak self] _ in self?.select(.text) },
            UIAction(title: "Answer Tape", image: UIImage(systemName: "rectangle.fill"),
                     state: isSelected(.tape) ? .on : .off) { [weak self] _ in self?.select(.tape) },
        ]
        if !tier.showsShapeTool {
            children.insert(UIAction(title: "Shape", image: UIImage(systemName: ShapeKindNames.symbol(state.lastShapeKind)),
                                     state: isSelected(.shape(state.lastShapeKind)) ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.select(.shape(self.state.lastShapeKind))
            }, at: 1)
        }
        children.append(imageMenu())
        children.append(UIAction(title: "Text Style…", image: UIImage(systemName: "textformat.size")) { [weak self] _ in
            guard let self else { return }
            self.delegate?.toolbar(self, requestsTextStyleFrom: self.insertButton)
        })
        return UIMenu(title: "Insert", children: children)
    }

    private func imageMenu() -> UIMenu {
        UIMenu(title: "Image", image: UIImage(systemName: "photo"), children: [
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

    private func moreMenu() -> UIMenu {
        var children: [UIMenuElement] = []
        if !isReadingMode {
            // Tools the current width could not show directly stay reachable here.
            let direct = Set(tier.directTools)
            var hidden: [EditorTool] = InkToolKind.allCases.map { .ink($0) }.filter { !direct.contains($0) }
            if !tier.showsShapeTool { hidden.append(.shape(state.lastShapeKind)) }
            if !hidden.isEmpty {
                children.append(UIMenu(title: "Tools", options: .displayInline, children: hidden.map { tool in
                    UIAction(title: tool.displayName, image: UIImage(systemName: tool.symbolName),
                             state: isSelected(tool) ? .on : .off) { [weak self] _ in self?.select(tool) }
                }))
            }
            children.append(UIMenu(title: "Favourites", options: .displayInline, children: [
                UIAction(title: "Save Current Tool", image: UIImage(systemName: "star")) { [weak self] _ in
                    self?.update { $0.addFavoriteFromCurrentTool() }
                },
                UIAction(title: "Edit Favourites…", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.toolbar(self, requestsFavoritesEditorFrom: self.moreButton)
                },
            ]))
        }
        children.append(UIMenu(title: "Scrolling", options: .displayInline, children: [
            UIAction(title: "Vertical", image: UIImage(systemName: "arrow.up.arrow.down"), state: isHorizontalPaging ? .off : .on) { [weak self] _ in
                guard let self else { return }; self.delegate?.toolbar(self, didChooseLayout: false)
            },
            UIAction(title: "Horizontal Pages", image: UIImage(systemName: "arrow.left.arrow.right"), state: isHorizontalPaging ? .on : .off) { [weak self] _ in
                guard let self else { return }; self.delegate?.toolbar(self, didChooseLayout: true)
            },
        ]))
        if !isReadingMode {
            children.append(UIAction(title: "Clear Page", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }; self.delegate?.toolbarDidRequestClearPage(self)
            })
        }
        return UIMenu(children: children)
    }

    // MARK: Helpers

    /// Short stable name for a tool, for accessibility identifiers.
    static func identifier(for tool: EditorTool) -> String {
        switch tool {
        case .ink(let kind): return kind.rawValue
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "text"
        case .image: return "image"
        case .shape: return "shape"
        case .tape: return "tape"
        }
    }

    static func widthTitle(_ width: Double) -> String {
        width == width.rounded() ? "\(Int(width)) pt" : String(format: "%.1f pt", width)
    }

    static func colorTitle(_ color: RGBAColor) -> String { EditorPalette.name(for: color) }

    static func swatch(_ color: RGBAColor, selected: Bool) -> UIImage {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let inset: CGFloat = selected ? 3 : 2.5
            let circle = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            UIColor(color).setFill()
            UIBezierPath(ovalIn: circle).fill()
            // A hairline keeps a pale highlighter visible on white, and the ring
            // is what shows selection without relying on colour alone.
            UIColor.separator.setStroke()
            let hairline = UIBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
            hairline.lineWidth = 1
            hairline.stroke()
            if selected {
                UIColor.label.setStroke()
                let ring = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}
