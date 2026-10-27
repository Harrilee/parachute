import Foundation
import MapKit
import Combine

struct MapSearchPlace: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    fileprivate let revision: UInt64
}

/// A small seam lets cancellation/race handling be tested without Apple network calls.
@MainActor
protocol MapSearchRequestRunning: AnyObject {
    func start() async throws -> [MKMapItem]
    func cancel()
}

@MainActor
private final class AppleMapSearchRequest: MapSearchRequestRunning {
    private let search: MKLocalSearch
    init(request: MKLocalSearch.Request) { search = MKLocalSearch(request: request) }
    func start() async throws -> [MKMapItem] { try await search.start().mapItems }
    func cancel() { search.cancel() }
}

/// Uses only typed queries and the visible map region. Never requests user location.
@MainActor
final class MapSearchService: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            queryChanged()
        }
    }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    @Published private(set) var results: [MapSearchPlace] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorKey: String?

    private var visibleRegion: MKCoordinateRegion?
    private var revision: UInt64 = 0
    private var completionRevision: UInt64 = 0
    private var completer: MKLocalSearchCompleter?
    private var debounceTask: Task<Void, Never>?
    private var activeRequest: (any MapSearchRequestRunning)?
    private let requestFactory: (MKLocalSearch.Request) -> any MapSearchRequestRunning
    private let debounceNanoseconds: UInt64

    init(debounceNanoseconds: UInt64 = 250_000_000,
         requestFactory: ((MKLocalSearch.Request) -> any MapSearchRequestRunning)? = nil) {
        self.debounceNanoseconds = debounceNanoseconds
        self.requestFactory = requestFactory ?? { AppleMapSearchRequest(request: $0) }
        super.init()
    }

    func updateRegion(_ region: MKCoordinateRegion) {
        guard CLLocationCoordinate2DIsValid(region.center),
              region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite,
              region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else { return }
        visibleRegion = region
        completer?.region = region
    }

    /// Explicit Enter/search action. It never selects a coordinate or moves the map.
    /// nil means failed/cancelled/stale; [] means the current search found no results.
    func search() async -> [MapSearchPlace]? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { cancel(); return nil }
        cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let visibleRegion { request.region = visibleRegion }
        return await execute(request)
    }

    /// Resolves only a suggestion still belonging to the current query.
    func resolve(_ completion: MKLocalSearchCompletion) async -> MapSearchPlace? {
        guard suggestions.contains(where: { $0 === completion }) else { return nil }
        let request = MKLocalSearch.Request(completion: completion)
        if let visibleRegion { request.region = visibleRegion }
        cancel()
        return await execute(request)?.first
    }

    /// The UI can recheck a returned result after its async continuation resumes.
    func isCurrent(_ place: MapSearchPlace) -> Bool {
        place.revision == revision && results.contains(where: { $0.id == place.id })
    }

    /// Also invalidates outstanding async selection actions, but preserves typed text.
    func cancel() {
        revision &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        completer?.delegate = nil
        completer?.cancel()
        completer = nil
        activeRequest?.cancel()
        activeRequest = nil
        suggestions = []
        results = []
        errorKey = nil
        isSearching = false
    }

    private func queryChanged() {
        cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let currentRevision = revision
        let delay = debounceNanoseconds
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled, let self, revision == currentRevision else { return }
            beginSuggestions(text, revision: currentRevision)
        }
    }

    private func beginSuggestions(_ text: String, revision: UInt64) {
        // Each debounced query gets a new identity. A cancelled completer's late
        // callback cannot be mistaken for results from the newer query fragment.
        let current = MKLocalSearchCompleter()
        current.resultTypes = [.address, .pointOfInterest]
        if let visibleRegion { current.region = visibleRegion }
        completionRevision = revision
        completer = current
        current.delegate = self
        isSearching = true
        current.queryFragment = text
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard completer === self.completer, completionRevision == revision else { return }
        suggestions = Array(completer.results.prefix(10))
        isSearching = false
        errorKey = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard completer === self.completer, completionRevision == revision else { return }
        suggestions = []
        isSearching = false
        errorKey = "search.failed"
    }

    private func execute(_ request: MKLocalSearch.Request) async -> [MapSearchPlace]? {
        guard !Task.isCancelled else { return nil }
        let currentRevision = revision
        let operation = requestFactory(request)
        activeRequest = operation
        isSearching = true
        defer {
            if revision == currentRevision {
                activeRequest = nil
                isSearching = false
            }
        }
        do {
            let items = try await withTaskCancellationHandler {
                try await operation.start()
            } onCancel: {
                Task { @MainActor in operation.cancel() }
            }
            guard revision == currentRevision, !Task.isCancelled else { return nil }
            let places = items.compactMap { item -> MapSearchPlace? in
                let coordinate = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate), coordinate.latitude.isFinite,
                      coordinate.longitude.isFinite else { return nil }
                return MapSearchPlace(
                    name: item.name ?? item.placemark.name ?? request.naturalLanguageQuery ?? "",
                    address: item.placemark.title ?? "",
                    coordinate: coordinate,
                    revision: currentRevision)
            }
            results = places
            errorKey = places.isEmpty ? "search.noResults" : nil
            return places
        } catch {
            guard revision == currentRevision, !Task.isCancelled else { return nil }
            results = []
            errorKey = "search.failed"
            return nil
        }
    }
}
