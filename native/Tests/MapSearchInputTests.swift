import AppKit
import SwiftUI
import MapKit

/// Exercises AppKit's real field editor and marked ranges in a hosted SwiftUI view.
/// Requires a macOS GUI session. It does not change the system input source, use
/// device services, or contact Apple search servers. The candidate-confirmation
/// event is simulated; the operating system's candidate window is not automated.
@MainActor
private final class CandidateFieldEditor: NSTextView {
    weak var searchField: NSSearchField?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && hasMarkedText() {
            insertText("北京", replacementRange: markedRange())
            // Some input methods commit text and leave a Return/action callback
            // in the same native event. Both must remain composition-only.
            super.keyDown(with: event)
            if let field = searchField, let action = field.action {
                field.sendAction(action, to: field.target)
            }
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class SearchTestWindowDelegate: NSObject, NSWindowDelegate {
    let editor = CandidateFieldEditor(frame: .zero)

    override init() {
        super.init()
        editor.isFieldEditor = true
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSSearchField else { return nil }
        editor.searchField = field
        return editor
    }
}

@MainActor
private final class PendingSearch: MapSearchRequestRunning {
    private var continuation: CheckedContinuation<[MKMapItem], Error>?
    private(set) var cancelled = false

    func start() async throws -> [MKMapItem] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    // Still permit a late response, as can happen after cancelling network work.
    func cancel() { cancelled = true }

    func complete() {
        let item = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: 39.9, longitude: 116.4)))
        item.name = "北京"
        continuation?.resume(returning: [item])
        continuation = nil
    }
}

@main
struct MapSearchInputTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 500, height: 450),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Isolated search input regression tests"
        let delegate = SearchTestWindowDelegate()
        window.delegate = delegate

        var requests: [PendingSearch] = []
        var selections = 0
        var beginNewDraftAfterSelection = false
        weak var fieldReference: NSSearchField?
        let search = MapSearchService(debounceNanoseconds: 60_000_000_000) { _ in
            let request = PendingSearch()
            requests.append(request)
            return request
        }
        let content = VStack(alignment: .leading) {
            MapSearchView(search: search) { _ in
                selections += 1
                if beginNewDraftAfterSelection {
                    // Race a fresh composition with selection's deferred blur.
                    DispatchQueue.main.async {
                        guard let field = fieldReference else { return }
                        window.makeFirstResponder(field)
                        guard let editor = field.currentEditor() as? NSTextView else { return }
                        editor.selectAll(nil)
                        editor.setMarkedText("sh", selectedRange: NSRange(location: 2, length: 0),
                                             replacementRange: editor.selectedRange())
                    }
                }
            }.floatingGlass()
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environmentObject(LanguageStore())
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        Task { @MainActor in
            func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }
            @MainActor func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            @MainActor func postReturn() {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                    app.postEvent(event, atStart: false)
                }
            }
            await settle()
            guard let field = descendants(window.contentView!).compactMap({ $0 as? NSSearchField }).first else {
                preconditionFailure("The hosted search view must contain a native search field")
            }
            fieldReference = field
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? CandidateFieldEditor else {
                preconditionFailure("A native shared field editor must receive search input")
            }

            for marked in ["b", "be", "bei", "beij", "beijing"] {
                editor.setMarkedText(marked, selectedRange: NSRange(location: marked.count, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                search.objectWillChange.send()
                await settle()
                precondition(search.query.isEmpty && field.stringValue == marked,
                             "Provisional pinyin must not become the search query or be overwritten by refresh")
                precondition(editor.hasMarkedText() && field.currentEditor() === editor
                             && window.firstResponder === editor,
                             "A SwiftUI refresh must preserve the marked range and editor focus")
            }
            print("PASS marked-text evolution and observable refresh preserve draft and focus")

            if let action = field.action { field.sendAction(action, to: field.target) }
            await settle()
            precondition(requests.isEmpty && editor.hasMarkedText() && window.firstResponder === editor,
                         "A native search action during composition must not submit or blur")
            print("PASS native search action ignores unfinished composition")

            postReturn()
            await settle()
            precondition(requests.isEmpty && selections == 0 && search.query == "北京"
                         && !editor.hasMarkedText() && window.firstResponder === editor,
                         "Candidate-confirmation Return must only commit Chinese text")
            print("PASS candidate Return commits Chinese without submitting")

            postReturn()
            await settle()
            precondition(requests.count == 1 && search.isSearching,
                         "The next deliberate Return must submit the committed query")
            print("PASS subsequent Return submits the committed query")

            editor.selectAll(nil)
            editor.setMarkedText("sh", selectedRange: NSRange(location: 2, length: 0),
                                 replacementRange: editor.selectedRange())
            await settle()
            requests[0].complete()
            await settle()
            precondition(requests[0].cancelled && selections == 0 && search.results.isEmpty
                         && search.query == "北京" && field.stringValue == "sh"
                         && editor.hasMarkedText() && window.firstResponder === editor,
                         "A late result for the old query must not select a place or interrupt a new composition")
            print("PASS new composition cancels search and rejects a late result")

            editor.insertText("上海", replacementRange: editor.markedRange())
            await settle()
            precondition(search.query == "上海" && field.stringValue == "上海"
                         && window.firstResponder === editor,
                         "Committing Chinese must replace the marked range, without a raw-pinyin prefix")
            print("PASS Chinese commit contains no provisional pinyin")

            postReturn()
            await settle()
            precondition(requests.count == 2 && search.isSearching)
            beginNewDraftAfterSelection = true
            requests[1].complete()
            await settle()
            precondition(selections == 1 && field.stringValue == "sh" && editor.hasMarkedText()
                         && field.currentEditor() === editor && window.firstResponder === editor,
                         "An old deferred blur must not dismiss a newly started composition")
            print("PASS a queued selection blur cannot interrupt a new draft")

            editor.insertText("上海", replacementRange: editor.markedRange())
            await settle()
            postReturn()
            await settle()
            precondition(requests.count == 3 && search.isSearching)
            // Exercise the alternate ordering explicitly: a SwiftUI refresh sees
            // the marked range before AppKit delivers its change notification.
            let cell = field.cell as! NSTextFieldCell
            cell.setWantsNotificationForMarkedText(false)
            editor.selectAll(nil)
            editor.setMarkedText("guangzhou", selectedRange: NSRange(location: 9, length: 0),
                                 replacementRange: editor.selectedRange())
            search.objectWillChange.send()
            await settle()
            precondition(editor.hasMarkedText() && search.query == "上海")
            cell.setWantsNotificationForMarkedText(true)
            editor.didChangeText()
            await settle()
            requests[2].complete()
            await settle()
            precondition(requests[2].cancelled && selections == 1 && search.results.isEmpty
                         && search.query == "上海" && field.stringValue == "guangzhou"
                         && editor.hasMarkedText() && window.firstResponder === editor,
                         "Seeing composition during a refresh must not suppress its later cancellation notification")
            print("PASS refresh-before-notification still cancels old search")

            search.cancel()
            for request in requests { request.complete() }
            print("8 native search input regression checks passed")
            fflush(stdout)
            app.terminate(nil)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { exit(3) }
        app.run()
    }
}
