import SwiftUI
import AppKit
import MapKit

/// A compact native search field with an inline, keyboard-accessible result picker.
/// The parent positions/materials this view and owns map selection.
struct MapSearchView: View {
    @ObservedObject var search: MapSearchService
    var maximumResultsHeight: CGFloat = 220
    let onSelect: (MapSearchPlace) -> Void
    @EnvironmentObject private var language: LanguageStore
    @State private var expanded = false
    @State private var fieldFocused = false
    @State private var pointerInsideResults = false
    @State private var highlightedIndex: Int?
    @State private var blurRevision = 0
    @State private var actionTask: Task<Void, Never>?
    @State private var inputState = MapSearchInputState()

    private func t(_ key: String) -> String { language.t(key) }
    private var choiceCount: Int { search.results.isEmpty ? search.suggestions.count : search.results.count }
    private var hasQuery: Bool { !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showPicker: Bool {
        expanded && hasQuery && (choiceCount > 0 || search.isSearching || search.errorKey != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            NativeMapSearchField(text: $search.query, placeholder: t("search.placeholder"),
                                 blurRevision: blurRevision, inputState: inputState,
                                 onCommand: handleCommand, compositionChanged: compositionChanged) { focused in
                fieldFocused = focused
                if focused {
                    expanded = true
                } else if !pointerInsideResults {
                    dismissResults()
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityLabel(t("search.placeholder"))

            if showPicker {
                Divider().padding(.horizontal, 10)
                if search.isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(t("search.searching")).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(12)
                } else if let error = search.errorKey {
                    Text(t(error)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    resultPicker
                        .onHover { pointerInsideResults = $0 }
                }
            }
        }
        .frame(width: 320)
        .onChange(of: search.query) { _, _ in
            highlightedIndex = nil
            actionTask?.cancel()
            actionTask = nil
            expanded = fieldFocused && hasQuery
        }
        .onChange(of: search.suggestions.map { ObjectIdentifier($0) }) { _, _ in
            highlightedIndex = nil
        }
        .onChange(of: search.results.map(\.id)) { _, _ in
            highlightedIndex = nil
        }
        .onDisappear { dismissResults() }
    }

    private var resultPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t(search.results.isEmpty ? "search.suggestions" : "search.results"))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 9)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(0..<choiceCount, id: \.self) { index in
                            Button { choose(index) } label: { resultRow(index) }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .id(index)
                        }
                    }.padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(height: min(CGFloat(choiceCount) * 58 + 6, maximumResultsHeight))
                .onChange(of: highlightedIndex) { _, index in
                    if let index { reader.scrollTo(index, anchor: .center) }
                }
            }
        }
    }

    private func resultRow(_ index: Int) -> some View {
        let title: String
        let subtitle: String
        if !search.results.isEmpty, search.results.indices.contains(index) {
            title = search.results[index].name
            subtitle = search.results[index].address
        } else if search.suggestions.indices.contains(index) {
            title = search.suggestions[index].title
            subtitle = search.suggestions[index].subtitle
        } else {
            title = ""
            subtitle = ""
        }
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .background(highlightedIndex == index ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlightedIndex == index ? .isSelected : [])
    }

    private func handleCommand(_ command: MapSearchFieldCommand) {
        switch command {
        case .down:
            expanded = true
            guard choiceCount > 0 else { return }
            highlightedIndex = min((highlightedIndex ?? -1) + 1, choiceCount - 1)
        case .up:
            expanded = true
            guard choiceCount > 0 else { return }
            highlightedIndex = max((highlightedIndex ?? choiceCount) - 1, 0)
        case .submit:
            if let highlightedIndex, expanded, (0..<choiceCount).contains(highlightedIndex) {
                choose(highlightedIndex)
            } else {
                submitQuery()
            }
        case .escape:
            fieldFocused = false
            blurRevision += 1
            dismissResults()
        case .clear:
            search.query = ""
            dismissResults()
        }
    }

    private func submitQuery() {
        guard hasQuery, !inputState.hasMarkedText else { return }
        actionTask?.cancel()
        expanded = true
        highlightedIndex = nil
        actionTask = Task { @MainActor in
            guard let places = await search.search(), !Task.isCancelled else { return }
            if places.count == 1, let place = places.first, search.isCurrent(place) {
                select(place)
            }
        }
    }

    private func choose(_ index: Int) {
        if !search.results.isEmpty {
            guard search.results.indices.contains(index) else { return }
            select(search.results[index])
        } else {
            guard search.suggestions.indices.contains(index) else { return }
            let completion = search.suggestions[index]
            actionTask?.cancel()
            actionTask = Task { @MainActor in
                guard let place = await search.resolve(completion), !Task.isCancelled, search.isCurrent(place) else { return }
                select(place)
            }
        }
    }

    private func select(_ place: MapSearchPlace) {
        // Inspect the live editor as well: an IME draft may precede its change notification.
        guard !inputState.hasMarkedText, search.isCurrent(place) else { return }
        // Make the selection before invalidating search revisions. This never simulates location.
        onSelect(place)
        fieldFocused = false
        blurRevision += 1
        expanded = false
        pointerInsideResults = false
        highlightedIndex = nil
        actionTask = nil
        search.query = place.name
        search.cancel()
    }

    private func dismissResults() {
        actionTask?.cancel()
        actionTask = nil
        search.cancel()
        highlightedIndex = nil
        expanded = false
        pointerInsideResults = false
    }

    private func compositionChanged(_ composing: Bool) {
        guard composing else { return }
        // The committed query has not changed yet, but an older request must not
        // select a result and remove focus while the user starts a new IME draft.
        actionTask?.cancel()
        actionTask = nil
        search.cancel()
        highlightedIndex = nil
    }
}

private enum MapSearchFieldCommand { case submit, up, down, escape, clear }

@MainActor
private final class MapSearchInputState {
    weak var field: NSSearchField?
    var hasMarkedText: Bool { (field?.currentEditor() as? NSTextView)?.hasMarkedText() == true }
}

private struct NativeMapSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let blurRevision: Int
    let inputState: MapSearchInputState
    let onCommand: (MapSearchFieldCommand) -> Void
    let compositionChanged: (Bool) -> Void
    let focusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.cell = GlassSearchFieldCell(textCell: "")
        (field.cell as? NSTextFieldCell)?.setWantsNotificationForMarkedText(true)
        field.isEditable = true
        field.isSelectable = true
        field.cell?.isScrollable = true
        field.controlSize = .large
        // Keep the native icon/text insets; the cell omits only the bezel drawing.
        field.isBezeled = true
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.stringValue = text
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchAction(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(placeholder)
        inputState.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronizeModel(text, with: field)
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(placeholder)
        }
        context.coordinator.applyBlurRevision(to: field)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeMapSearchField
        var lastBlurRevision: Int
        private var lastModelText: String
        private var composing = false
        private var compositionStartNotified = false
        private var editingGeneration = 0
        private var commitGeneration = 0
        private var suppressCommitTurn = false
        private var commitEvent: NSEvent?
        init(_ parent: NativeMapSearchField) {
            self.parent = parent
            lastBlurRevision = parent.blurRevision
            lastModelText = parent.text
        }

        func synchronizeModel(_ text: String, with field: NSSearchField) {
            let modelChanged = lastModelText != text
            lastModelText = text
            // AppKit owns marked text. Even assigning the previous committed value
            // here discards the marked range and prematurely commits raw pinyin.
            if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true {
                composing = true
                return
            }
            // An unrelated results/status refresh is not an external text edit.
            if modelChanged && field.stringValue != text { field.stringValue = text }
        }

        func applyBlurRevision(to field: NSSearchField) {
            guard lastBlurRevision != parent.blurRevision else { return }
            let revision = parent.blurRevision
            lastBlurRevision = revision
            let generation = editingGeneration
            guard let editor = field.currentEditor() as? NSTextView else { return }
            DispatchQueue.main.async { [weak self, weak field, weak editor] in
                guard let self, let field, let editor,
                      parent.blurRevision == revision, editingGeneration == generation,
                      field.currentEditor() === editor, field.window?.firstResponder === editor,
                      !editor.hasMarkedText() else { return }
                field.window?.makeFirstResponder(nil)
            }
        }

        private func observeComposition(_ marked: Bool) {
            if marked {
                composing = true
                // A model refresh can observe marked text before its notification.
                // Still notify/cancel once when the native change event arrives.
                guard !compositionStartNotified else { return }
                compositionStartNotified = true
                parent.compositionChanged(true)
                return
            }
            guard composing else { return }
            composing = false
            compositionStartNotified = false
            // Candidate-confirmation Return belongs to the IME. Only a later,
            // deliberate Return may trigger the search field's action.
            commitEvent = NSApp.currentEvent
            suppressCommitTurn = true
            commitGeneration += 1
            let generation = commitGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, commitGeneration == generation else { return }
                suppressCommitTurn = false
            }
            parent.compositionChanged(false)
        }

        private var isCompositionCommitEvent: Bool {
            if suppressCommitTurn { return true }
            guard let commitEvent, let current = NSApp.currentEvent else { return false }
            if current === commitEvent { return true }
            return current.type == .keyDown && commitEvent.type == .keyDown
                && current.keyCode == commitEvent.keyCode && current.timestamp == commitEvent.timestamp
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            editingGeneration += 1
            let marked = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
            observeComposition(marked)
            guard !marked else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            editingGeneration += 1
            parent.focusChanged(true)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            observeComposition(false)
            parent.focusChanged(false)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Let the system input method handle candidate navigation/confirmation.
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if !isCompositionCommitEvent { parent.onCommand(.submit) }
            case #selector(NSResponder.moveUp(_:)): parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)): parent.onCommand(.down)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCommand(.escape)
            default: return false
            }
            return true
        }
        @objc func searchAction(_ sender: NSSearchField) {
            guard (sender.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            let empty = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard empty || !isCompositionCommitEvent else { return }
            if parent.text != sender.stringValue { parent.text = sender.stringValue }
            parent.onCommand(empty ? .clear : .submit)
        }
    }
}

private final class GlassSearchFieldCell: NSSearchFieldCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // The surrounding glass supplies the surface. Native interior drawing
        // retains the magnifier, clear button, placeholder and text layout.
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}
