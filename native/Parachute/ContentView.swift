import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject private var language: LanguageStore
    @EnvironmentObject private var device: DeviceService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3346, longitude: -122.009),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)))
    @State private var selected: Coordinates?
    @State private var editing = false
    @State private var guide = false
    @State private var imagery = false
    @State private var latestCamera: MapCamera?
    @State private var mapGestureMoved = false
    @State private var titlebarHovered = false
    @State private var titlebarHeight: CGFloat = 32
    @StateObject private var search = MapSearchService()
    @State private var selectedPlaceName: String?
    @State private var locationFeedback: LocationFeedback?
    @State private var pulseElapsed: TimeInterval = 0
    @State private var pulseMaximumRadius: CLLocationDistance = 500
    @State private var devicePanelHeight: CGFloat = 280
    private func t(_ key: String) -> String { language.t(key) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                MapReader { proxy in
                    Map(position: $camera, interactionModes: [.pan, .zoom, .rotate]) {
                        if let locationFeedback {
                            LocationPulse(coordinate: locationFeedback.coordinate,
                                maximumRadius: pulseMaximumRadius, elapsed: pulseElapsed,
                                reduceMotion: reduceMotion)
                        }
                        if let selected {
                            Marker(selectedPlaceName ?? t("map.selected"), coordinate: selected.clCoordinate)
                        }
                    }
                    .mapStyle(imagery ? .hybrid(elevation: .realistic) : .standard(elevation: .flat))
                    .mapControls { }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        latestCamera = context.camera
                        search.updateRegion(context.region)
                    }
                    .onChange(of: locationFeedback?.id) { _, _ in
                        if let feedback = locationFeedback {
                            pulseMaximumRadius = pulseRadius(at: feedback.coordinate, in: proxy)
                        }
                    }
                    // Observe the completed click without waiting for double-click recognition.
                    // Native pan and double-click zoom still receive the same gesture.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !mapGestureMoved && hypot(value.translation.width, value.translation.height) >= 4 {
                                    mapGestureMoved = true
                                }
                            }
                            .onEnded { value in
                                defer { mapGestureMoved = false }
                                guard !mapGestureMoved,
                                      hypot(value.translation.width, value.translation.height) < 4,
                                      let coordinate = proxy.convert(value.location, from: .local),
                                      CLLocationCoordinate2DIsValid(coordinate) else { return }
                                selected = Coordinates(latitude: coordinate.latitude, longitude: coordinate.longitude)
                                selectedPlaceName = nil
                                search.cancel()
                            }
                    )
                }
                .ignoresSafeArea()

                WindowDragRegion(isHovered: $titlebarHovered, height: $titlebarHeight)
                    .frame(height: titlebarHeight)
                    .background {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(alignment: .bottom) { Divider() }
                            .opacity(titlebarHovered ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    .animation(.easeOut(duration: 0.12), value: titlebarHovered)

                ViewThatFits(in: .vertical) {
                    sidebar.fixedSize(horizontal: false, vertical: true)
                        .floatingGlass()
                    ScrollView { sidebar }
                        .floatingGlass()
                }
                    .frame(width: 320)
                    .background {
                        GeometryReader { panel in
                            Color.clear.preference(key: DevicePanelHeightKey.self, value: panel.size.height)
                        }
                    }
                    .frame(maxHeight: max(240, geometry.size.height - titlebarHeight - 100), alignment: .bottom)
                    .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
                    .padding(.leading, 16)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                MapSearchView(search: search,
                    maximumResultsHeight: max(58, min(220,
                        geometry.size.height - devicePanelHeight - titlebarHeight - 138))) { place in
                    selected = Coordinates(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
                    selectedPlaceName = place.name
                    center(on: place.coordinate)
                }
                .frame(width: 320)
                .floatingGlass()
                .padding(.leading, 16)
                .padding(.top, titlebarHeight + 12)

                HStack {
                    Spacer()
                    Button { imagery.toggle() } label: {
                        Image(systemName: imagery ? "map" : "globe.americas")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .help(t(imagery ? "map.standard" : "map.satellite"))
                    .accessibilityLabel(t(imagery ? "map.standard" : "map.satellite"))
                }
                .padding(.trailing, 12)
                .padding(.top, 12)
            }
        }
        .ignoresSafeArea()
        .onPreferenceChange(DevicePanelHeightKey.self) { height in
            if height > 0 { devicePanelHeight = height }
        }
        .onChange(of: device.lastSuccessfulSimulation) { _, success in
            guard let success else { return }
            locationFeedback = LocationFeedback(id: success.id,
                coordinate: CLLocationCoordinate2D(latitude: success.latitude, longitude: success.longitude),
                startedAt: Date())
        }
        .task(id: locationFeedback?.id) {
            guard let feedback = locationFeedback else { return }
            pulseElapsed = 0
            do {
                if reduceMotion {
                    try await Task.sleep(for: .seconds(0.65))
                } else {
                    while pulseElapsed < 2.8 {
                        try await Task.sleep(for: .milliseconds(33))
                        pulseElapsed = Date().timeIntervalSince(feedback.startedAt)
                    }
                }
                locationFeedback = nil
            } catch { }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            mapGestureMoved = false
            titlebarHovered = false
        }
        .sheet(isPresented: $editing) {
            CoordinateEditor(coordinate: selected) { value in
                selected = value
                selectedPlaceName = nil
                center(on: value.clCoordinate)
            }.environmentObject(language)
        }
        .sheet(isPresented: $guide) { connectionGuide }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("device.title")).font(.subheadline.weight(.semibold))
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        if !device.deviceName.isEmpty {
                            Text(device.deviceName).font(.headline).lineLimit(2)
                        }
                        Text(t(deviceStatusKey)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !device.connectionType.isEmpty {
                            Label(t(device.connectionType == "USB" ? "device.transport.usb" : "device.transport.network"),
                                  systemImage: device.connectionType == "USB" ? "cable.connector" : "network")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "iphone")
                }
                if device.deviceName.isEmpty || device.status == .untrusted {
                    Button(t("device.guide.title")) { guide = true }
                        .buttonStyle(.link)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(t("coordinate.title")).font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    coordinateValue(t("coordinate.lon"), value: selected?.longitude)
                    Spacer(minLength: 4)
                    coordinateValue(t("coordinate.lat"), value: selected?.latitude)
                    Spacer(minLength: 0)
                    Button { editing = true } label: {
                        Image(systemName: "pencil")
                    }.buttonStyle(.borderless).help(t("coordinate.edit"))
                        .accessibilityLabel(t("coordinate.edit"))
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Button(action: primaryAction) {
                    HStack {
                        if device.busy { ProgressView().controlSize(.small) }
                        Text(t(actionKey))
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(device.busy || (device.status == .ready && selected == nil))
                if let message = device.message {
                    Text(t(message)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !device.diagnostic.isEmpty {
                        DisclosureGroup(t("device.details")) {
                            Text(device.diagnostic).font(.caption.monospaced())
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Button(t("device.showLog")) {
                                let url = FileManager.default.fileExists(atPath: device.lastFailureLogURL.path)
                                    ? device.lastFailureLogURL : device.diagnosticLogURL
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    private func coordinateValue(_ label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.5f", $0) } ?? "—")
                .font(.system(.caption, design: .monospaced)).monospacedDigit().lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private func center(on coordinate: CLLocationCoordinate2D) {
        withAnimation {
            camera = .camera(MapCamera(centerCoordinate: coordinate, distance: 5_000,
                heading: latestCamera?.heading ?? 0, pitch: 0))
        }
    }

    private func pulseRadius(at coordinate: CLLocationCoordinate2D, in proxy: MapProxy) -> CLLocationDistance {
        // Freeze an approximately 80-point radius in geographic space at acknowledgement.
        // Native overlays then follow the map and stay below the marker while panning/zooming.
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let point = proxy.convert(coordinate, to: .local) {
            for offset in [CGPoint(x: 80, y: 0), CGPoint(x: -80, y: 0), CGPoint(x: 0, y: 80), CGPoint(x: 0, y: -80)] {
                if let edge = proxy.convert(CGPoint(x: point.x + offset.x, y: point.y + offset.y), from: .local) {
                    let radius = origin.distance(from: CLLocation(latitude: edge.latitude, longitude: edge.longitude))
                    if radius.isFinite && radius > 0 { return min(radius, 5_000_000) }
                }
            }
        }
        return max(1, min((latestCamera?.distance ?? 5_000) * 0.12, 5_000_000))
    }

    private var deviceStatusKey: String {
        switch device.status {
        case .disconnected: return "device.disconnected"
        case .untrusted: return "device.untrusted"
        case .developerModeOff: return "device.developerModeOff"
        case .ready: return "device.ready"
        case .error: return "device.error"
        }
    }
    private var actionKey: String {
        if device.busy { return "device.busy" }
        switch device.status {
        case .ready: return device.simulated ? "device.update" : "device.simulate"
        case .developerModeOff: return "device.developerMode"
        case .untrusted: return "device.trust"
        case .error where !device.deviceName.isEmpty: return "device.refresh"
        default: return "device.connect"
        }
    }
    private func primaryAction() {
        switch device.status {
        case .ready:
            guard let selected else { return }
            Task { await device.simulate(latitude: selected.latitude, longitude: selected.longitude) }
        case .error where !device.deviceName.isEmpty:
            Task { await device.refresh() }
        default: guide = true
        }
    }

    private var connectionGuide: some View {
        let developerMode = device.status == .developerModeOff
        return VStack(alignment: .leading, spacing: 20) {
            Text(t(developerMode ? "device.devGuide.title" : "device.guide.title"))
                .font(.headline)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(t(developerMode ? "device.devGuide.body" : "device.guide.body"))
                        .fixedSize(horizontal: false, vertical: true)
                    if !developerMode {
                        Text(t("device.guide.reconnect"))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let imageURL = Bundle.main.url(forResource: developerMode ? "enable-devmode" : "trust-computer", withExtension: "png", subdirectory: "Help"),
                   let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image)
                        .resizable().scaledToFit().frame(width: 190)
                        .accessibilityLabel(t(developerMode ? "device.devGuide.title" : "device.guide.title"))
                }
            }
            HStack {
                Spacer()
                if developerMode {
                    Button(t("device.developerMode")) { Task { await device.enableDeveloperMode() }; guide = false }
                        .disabled(device.busy)
                }
                Button(t("action.done")) { guide = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 550)
    }

}

private struct LocationFeedback {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let startedAt: Date
}

private struct DevicePanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension Coordinates {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct CoordinateEditor: View {
    @EnvironmentObject private var language: LanguageStore
    @Environment(\.dismiss) private var dismiss
    @State private var latitude: String
    @State private var longitude: String
    @State private var invalid = false
    @FocusState private var focused: Bool
    let apply: (Coordinates) -> Void

    init(coordinate: Coordinates?, apply: @escaping (Coordinates) -> Void) {
        _latitude = State(initialValue: coordinate.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: coordinate.map { String($0.longitude) } ?? "")
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(language.t("coordinate.title")).font(.headline)
            Text(language.t("coordinate.hint")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(language.t("coordinate.longitude"), text: $longitude).focused($focused)
                    .help(language.t("coordinate.longitudeHint"))
                TextField(language.t("coordinate.latitude"), text: $latitude)
                    .help(language.t("coordinate.latitudeHint"))
            }
            .textFieldStyle(.roundedBorder)
            Text(language.t("coordinate.longitudeHint") + "\n" + language.t("coordinate.latitudeHint"))
                .font(.caption).foregroundStyle(.secondary)
            if invalid {
                Label(language.t("coordinate.error"), systemImage: "exclamationmark.circle.fill")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(language.t("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(language.t("action.save")) {
                    do {
                        let coordinate = try Coordinates.parse(latitude: latitude, longitude: longitude)
                        apply(coordinate)
                        dismiss()
                    } catch { invalid = true }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 420)
        .onAppear { focused = true }
    }
}
