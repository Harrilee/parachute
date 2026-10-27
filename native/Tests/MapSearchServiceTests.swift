import Foundation
import MapKit

@MainActor
private final class ControlledSearch: MapSearchRequestRunning {
    private var continuation: CheckedContinuation<[MKMapItem], Error>?
    private(set) var started = false
    private(set) var cancellations = 0
    func start() async throws -> [MKMapItem] {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func cancel() { cancellations += 1 }
    func complete(_ items: [MKMapItem]) { continuation?.resume(returning: items); continuation = nil }
    func fail() { continuation?.resume(throwing: NSError(domain: "SearchTest", code: 1)); continuation = nil }
}

/// Deterministic race tests: no Apple requests, geolocation or device commands.
@main
struct MapSearchServiceTests {
    @MainActor static func main() async throws {
        func item(_ name: String, latitude: Double = 37.3346) -> MKMapItem {
            let result = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -122.009)))
            result.name = name
            return result
        }
        func awaitStart(_ operation: ControlledSearch) async {
            for _ in 0..<100 where !operation.started { await Task.yield() }
            precondition(operation.started)
        }
        var operations: [ControlledSearch] = []
        var requests: [MKLocalSearch.Request] = []
        let service = MapSearchService(debounceNanoseconds: 60_000_000_000) { request in
            requests.append(request)
            let operation = ControlledSearch()
            operations.append(operation)
            return operation
        }
        defer { service.cancel() }
        service.query = "  "
        let empty = await service.search()
        precondition(empty == nil && requests.isEmpty, "Blank text must not send a request")

        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.01), span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.3))
        service.updateRegion(region)
        service.query = "  Apple Park  "
        let first = Task { await service.search() }
        await Task.yield()
        let old = operations[0]
        await awaitStart(old)
        precondition(requests[0].naturalLanguageQuery == "Apple Park", "Explicit search should trim outer whitespace")
        precondition(requests[0].region.center.latitude == region.center.latitude, "Visible region should bias the request")
        service.query = "Cupertino Library"
        precondition(old.cancellations == 1 && service.results.isEmpty, "Editing query must cancel old work and clear old results")
        let second = Task { await service.search() }
        await Task.yield()
        let new = operations[1]
        await awaitStart(new)
        new.complete([item("Library")])
        let newPlaces = await second.value
        precondition(newPlaces?.first?.name == "Library" && service.isCurrent(newPlaces![0]), "Current response should produce selectable results")
        old.complete([item("Old result")])
        let oldPlaces = await first.value
        precondition(oldPlaces == nil && service.results.first?.name == "Library", "Late cancelled response must not replace newer results")

        service.query = "New text"
        precondition(!service.isCurrent(newPlaces![0]), "A prior result must be invalidated before UI can relocate the map")
        let clearTask = Task { await service.search() }
        await Task.yield()
        let cleared = operations[2]
        await awaitStart(cleared)
        service.query = ""
        cleared.complete([item("Cleared result")])
        let clearedResult = await clearTask.value
        precondition(clearedResult == nil && service.results.isEmpty && !service.isSearching && service.errorKey == nil, "Clearing input must suppress completion and reset transient UI")

        service.query = "No matches"
        let noMatchTask = Task { await service.search() }
        await Task.yield()
        let noMatch = operations[3]
        await awaitStart(noMatch)
        noMatch.complete([])
        let noMatches = await noMatchTask.value
        precondition(noMatches?.isEmpty == true && service.errorKey == "search.noResults", "Empty successful searches need a clear no-results state")

        service.query = "Network failure"
        let errorTask = Task { await service.search() }
        await Task.yield()
        let failed = operations[4]
        await awaitStart(failed)
        failed.fail()
        let failure = await errorTask.value
        precondition(failure == nil && service.errorKey == "search.failed" && !service.isSearching, "Errors must not leave an endless progress state")

        service.query = "Cancelled task"
        let cancelledTask = Task { await service.search() }
        await Task.yield()
        let cancelled = operations[5]
        await awaitStart(cancelled)
        cancelledTask.cancel()
        for _ in 0..<100 where cancelled.cancellations == 0 { await Task.yield() }
        precondition(cancelled.cancellations > 0, "Task cancellation must cancel the underlying Apple request")
        cancelled.complete([item("Cancelled result")])
        let cancelledResult = await cancelledTask.value
        precondition(cancelledResult == nil && service.results.isEmpty && !service.isSearching, "Task cancellation must not publish late results")

        let staleSuggestion = MKLocalSearchCompletion()
        let requestCount = requests.count
        let staleResolution = await service.resolve(staleSuggestion)
        precondition(staleResolution == nil && requests.count == requestCount, "A suggestion outside the current list must not be resolved")
        print("Passed 12 map-search checks: blank query, trimming, region bias, query cancellation, current results, stale response rejection, stale selection rejection, clear, no results, error, task cancellation, stale suggestion rejection.")
    }
}
