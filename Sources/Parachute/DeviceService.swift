import Foundation
import Combine
import Darwin

/// Owns bundled helper sessions without configuring sudoers, elevating privileges,
/// pausing system services, or stopping another app's tunnel.
@MainActor
final class DeviceService: ObservableObject {
    enum Status: String { case disconnected, untrusted, developerModeOff, connected, error }
    struct SuccessfulSimulation: Identifiable, Equatable {
        let id: UUID
        let latitude: Double
        let longitude: Double
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var deviceName = ""
    /// The selected transport, also enforced by each targeted helper command.
    @Published private(set) var connectionType = ""
    /// Localization key, translated by the view at render time.
    @Published private(set) var message: String?
    @Published private(set) var recommendsUSB = false
    @Published private(set) var busy = false
    @Published private(set) var simulated = false
    /// A command acknowledgement, tied to its original requested coordinates.
    /// Each successful attempt gets a new identity, including repeats of the same location.
    @Published private(set) var lastSuccessfulSimulation: SuccessfulSimulation?
    @Published private(set) var diagnostic = ""

    private let binaryURL: URL
    private let runtimeURL: URL
    private let diagnosticLog: DiagnosticLog
    var diagnosticLogURL: URL { diagnosticLog.url }
    var lastFailureLogURL: URL { diagnosticLog.lastFailureURL }
    private var udid: String?
    private var needsDeviceName = false
    private var pollingTask: Task<Void, Never>?
    private var refreshing = false
    private var sessions: [UUID: CommandSession] = [:]
    private var locationSession: CommandSession?
    private var stoppingLocation: Process?
    private var locationRequest: SuccessfulSimulation?
    private var acknowledgedLocationSession: UUID?
    private var tunnelSession: CommandSession?
    private var tunnelPort: Int?
    private var productVersion = ""
    private let tunnelStartupTimeout: TimeInterval
    private var stopped = false

    init(binaryURL: URL? = nil, runtimeURL: URL? = nil, tunnelStartupTimeout: TimeInterval = 20) {
        self.binaryURL = binaryURL ?? Bundle.main.resourceURL!.appendingPathComponent("ios")
        let runtimeName = Bundle.main.bundleIdentifier == "com.electron.parachute"
            ? "Parachute" : "ParachuteNativePrototype"
        let runtime = runtimeURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(runtimeName)/go-ios-runtime", isDirectory: true)
        self.runtimeURL = runtime
        self.diagnosticLog = DiagnosticLog(directory: runtime)
        self.tunnelStartupTimeout = tunnelStartupTimeout
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        stopped = false
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        stopped = true
        pollingTask?.cancel()
        pollingTask = nil
        let locationWasRunning = stopLocation()
        stopOwnedTunnel(after: locationWasRunning ? 0.3 : 0)
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        locationSession = nil
        tunnelSession = nil
        tunnelPort = nil
        simulated = false
    }

    func refresh() async {
        await refreshDevice(allowWhileBusy: false)
    }

    private func refreshDevice(allowWhileBusy: Bool) async {
        guard (!busy || allowWhileBusy), !refreshing, !stopped else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let output = try await run(["list", "--details"])
            guard !stopped else { return }
            let objects = Self.jsonValues(output)
            guard let devices = objects.compactMap({ $0 as? [[String: Any]] }).first
                ?? objects.compactMap({ ($0 as? [String: Any])?["deviceList"] as? [[String: Any]] }).first else {
                throw ServiceError.commandFailed("Unexpected device-list response: " + output)
            }
            guard let device = Self.selectDevice(devices, preferredIdentifier: udid),
                  let identifier = (device["Udid"] ?? device["udid"]) as? String else {
                disconnect()
                return
            }
            let transport = (device["ConnectionType"] as? String) ?? ""
            let changedDevice = udid != identifier
            let changedTransport = !changedDevice && connectionType != transport
            if changedDevice || changedTransport {
                let locationWasRunning = stopLocation()
                stopOwnedTunnel(after: locationWasRunning ? 0.3 : 0)
                recommendsUSB = false
                message = changedTransport ? "device.connectionChanged" : nil
            }
            connectionType = transport
            if changedDevice {
                status = .disconnected
                udid = identifier
                diagnosticLog.deviceIdentifier = identifier
                deviceName = (device["DeviceName"] as? String) ?? "iOS Device"
                needsDeviceName = device["DeviceName"] as? String == nil
            }
            productVersion = (device["ProductVersion"] as? String) ?? ""
            if let error = device["Error"] as? String, !error.isEmpty {
                throw ServiceError.commandFailed(error)
            }
            if needsDeviceName {
                if let nameOutput = try? await run(["devicename", "--udid=\(identifier)"]),
                   let name = Self.jsonValues(nameOutput).compactMap({ ($0 as? [String: Any])?["devicename"] as? String }).last {
                    deviceName = name
                    needsDeviceName = false
                }
            }
            guard !stopped else { return }
            if (device["PairingStatus"] as? String) == "unpaired" {
                status = .untrusted
                message = "device.trustRequired"
                recommendsUSB = connectionType == "Network"
                return
            }
            let mode = try await run(["devmode", "get", "--udid=\(identifier)"])
            guard !stopped else { return }
            if let enabled = Self.jsonValues(mode).compactMap({ ($0 as? [String: Any])?["DeveloperModeEnabled"] as? Bool }).last {
                status = enabled ? .connected : .developerModeOff
            } else {
                let text = mode.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if text == "true" || text.contains("enabled: true") || text.contains("devmode: true") {
                    status = .connected
                } else if text == "false" || text.contains("enabled: false") || text.contains("devmode: false") {
                    status = .developerModeOff
                } else {
                    status = .error
                    message = "device.statusUnknown"
                    recommendsUSB = connectionType == "Network"
                    diagnostic = diagnosticLog.sanitize(String(mode.suffix(2_000)))
                }
            }
            if let session = locationSession { recordSuccessfulSimulationIfAcknowledged(session) }
            if let session = locationSession, !session.process.isRunning {
                let failed = session.process.terminationStatus != 0
                if failed {
                    diagnostic = diagnosticLog.sanitize("setlocation exited with code \(session.process.terminationStatus):\n" + session.output())
                    diagnosticLog.record(command: "simulate", event: "failed", exitCode: session.process.terminationStatus,
                                         output: diagnostic, preserveFailure: true)
                }
                stopLocation()
                if failed {
                    message = "device.simulationFailed"
                    recommendsUSB = connectionType == "Network"
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !stopped else { return }
            diagnostic = diagnosticLog.sanitize(error.localizedDescription)
            recommendsUSB = connectionType == "Network"
            if Self.isTrustError(diagnostic) {
                status = .untrusted
                message = "device.trustRequired"
            } else {
                status = .error
                message = FileManager.default.isExecutableFile(atPath: binaryURL.path)
                    ? "device.discoveryFailed" : "device.binaryMissing"
            }
        }
    }

    func enableDeveloperMode() async {
        guard !busy, !stopped else { return }
        busy = true
        message = nil
        recommendsUSB = false
        defer { busy = false }
        do {
            try await waitForRefresh()
            await refreshDevice(allowWhileBusy: true)
            try Task.checkCancellation()
            guard !stopped, let udid, status != .error, status != .disconnected else { return }
            _ = try? await run(["devmode", "reveal", "--udid=\(udid)"])
            try Task.checkCancellation()
            _ = try await run(["devmode", "enable", "--udid=\(udid)"], timeout: 30)
            message = "device.developerModeRequested"
        } catch is CancellationError {
            return
        } catch {
            diagnostic = diagnosticLog.sanitize(error.localizedDescription)
            diagnosticLog.record(command: "enable-developer-mode", event: "failed", output: diagnostic, preserveFailure: true)
            message = "device.developerModeFailed"
            recommendsUSB = connectionType == "Network"
        }
    }

    func simulate(latitude: Double, longitude: Double) async {
        guard !busy, !stopped else { return }
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            message = "device.invalidCoordinates"
            return
        }
        busy = true
        message = nil
        recommendsUSB = false
        defer { busy = false }
        do {
            try await waitForRefresh()
            // A cable may have been attached or removed since the last poll. Select
            // the actual transport again before creating a tunnel or sending a location.
            await refreshDevice(allowWhileBusy: true)
            try Task.checkCancellation()
            guard !stopped, status == .connected, let udid else { return }
            diagnostic = ""
            try await waitForStoppedLocation()
            try await ensureTunnel(for: udid)
            stopLocation()
            // Let the old command send StopSimulateLocation before issuing the next location.
            try await waitForStoppedLocation()
            let session = try launch(["setlocation", "--udid=\(udid)", "--lat=\(latitude)", "--lon=\(longitude)"])
            locationSession = session
            locationRequest = SuccessfulSimulation(id: UUID(), latitude: latitude, longitude: longitude)
            acknowledgedLocationSession = nil
            do {
                // The command may remain alive for iOS location simulation. A live process is
                // reported as pending verification, never treated as proof of device location.
                let deadline = Date().addingTimeInterval(2)
                while session.process.isRunning && Date() < deadline {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try Task.checkCancellation()
                    if Self.hasFatalOutput(session.output()) {
                        throw ServiceError.commandFailed(session.output())
                    }
                    recordSuccessfulSimulationIfAcknowledged(session)
                }
                if !session.process.isRunning {
                    let output = session.output()
                    guard session.process.terminationStatus == 0 else { throw ServiceError.commandFailed("\(session.commandLabel) exited with code \(session.process.terminationStatus):\n" + output) }
                    recordSuccessfulSimulationIfAcknowledged(session)
                    stopLocation()
                    simulated = true
                    message = "device.commandCompleted"
                } else {
                    recordSuccessfulSimulationIfAcknowledged(session)
                    simulated = true
                    message = acknowledgedLocationSession == session.id ? "device.success" : "device.simulationUnverified"
                }
            } catch {
                stopLocation()
                throw error
            }
        } catch is CancellationError {
            return
        } catch {
            diagnostic = diagnosticLog.sanitize(error.localizedDescription)
            diagnosticLog.record(command: "simulate", event: "failed", output: diagnostic, preserveFailure: true)
            message = "device.simulationFailed"
            recommendsUSB = connectionType == "Network"
        }
    }

    private func recordSuccessfulSimulationIfAcknowledged(_ session: CommandSession) {
        guard !stopped, !Task.isCancelled, locationSession?.id == session.id,
              acknowledgedLocationSession != session.id, let request = locationRequest else { return }
        let output = session.output()
        guard !Self.hasFatalOutput(output) else { return }
        let exited = !session.process.isRunning
        if exited && session.process.terminationStatus != 0 { return }
        // The stock long-running CLI is silent after its DTX reply. Never infer success from age.
        // A same-version instrumented CLI may emit this event only after that reply succeeds.
        let hasAcknowledgement = Self.jsonValues(output).contains {
            ($0 as? [String: Any])?["event"] as? String == "location-simulation-started"
        }
        guard exited || hasAcknowledgement else { return }
        acknowledgedLocationSession = session.id
        lastSuccessfulSimulation = request
        message = "device.success"
        recommendsUSB = false
        diagnosticLog.record(command: "setlocation", event: "acknowledged",
                             exitCode: exited ? session.process.terminationStatus : nil)
    }

    private static func hasFatalOutput(_ output: String) -> Bool {
        let lower = output.lowercased()
        if lower.contains("invalidservice") || lower.contains("permission denied") { return true }
        return Self.jsonValues(output).contains {
            guard let level = ($0 as? [String: Any])?["level"] as? String else { return false }
            return level.lowercased() == "fatal" || level.lowercased() == "panic"
        }
    }

    private func ensureTunnel(for identifier: String) async throws {
        // Pre-iOS 17 uses the legacy USB service and does not need RSD tunneling.
        let version = productVersion.split(separator: ".").compactMap { Int($0) }
        if let major = version.first, major < 17 { return }

        if tunnelSession?.process.isRunning == true, let port = tunnelPort,
           await tunnelReady(identifier: identifier, port: port) { return }
        stopOwnedTunnel()
        // Reuse only a tunnel whose transport is verified; never reconfigure another app's tunnel.
        if await tunnelReady(identifier: identifier, port: 60105) { return }

        if version.first == 17 {
            let minor = version.count > 1 ? version[1] : 0
            let patch = version.count > 2 ? version[2] : 0
            if minor < 4 || (minor == 4 && patch == 0) {
                throw ServiceError.commandFailed("This go-ios build supports unprivileged userspace tunnels only after iOS 17.4. An existing kernel tunnel from a compatible helper that reports the selected connection type is required for this device.")
            }
        }

        try Task.checkCancellation()
        if stopped { throw CancellationError() }
        let port = try Self.availableLoopbackPort()
        tunnelPort = port
        let session: CommandSession
        do {
            session = try launch(["tunnel", "start", "--userspace", "--tunnel-info-port=\(port)"])
            tunnelSession = session
        } catch {
            tunnelPort = nil
            throw error
        }
        do {
            let deadline = Date().addingTimeInterval(tunnelStartupTimeout)
            while Date() < deadline {
                try Task.checkCancellation()
                if stopped { throw CancellationError() }
                guard session.process.isRunning else {
                    throw ServiceError.commandFailed("Userspace tunnel exited with code \(session.process.terminationStatus):\n" + session.output())
                }
                if await tunnelReady(identifier: identifier, port: port), session.process.isRunning {
                    diagnosticLog.record(command: "tunnel start", event: "device-ready")
                    return
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw ServiceError.commandFailed("Timed out waiting for the selected device's userspace tunnel.\n" + session.output())
        } catch {
            stopOwnedTunnel()
            throw error
        }
    }

    private func tunnelReady(identifier: String, port: Int) async -> Bool {
        guard !stopped, !Task.isCancelled else { return false }
        do {
            let output = try await run(["tunnel", "ls", "--udid=\(identifier)", "--tunnel-info-port=\(port)"], timeout: 3, agentPort: port)
            let records = Self.jsonValues(output).compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
            return records.contains {
                ($0["udid"] as? String) == identifier && ($0["rsdPort"] as? Int ?? 0) > 0
                    && !($0["address"] as? String ?? "").isEmpty
                    && ($0["connectionType"] as? String) == connectionType
            }
        } catch { return false }
    }

    private func stopOwnedTunnel(after delay: TimeInterval = 0) {
        if let session = tunnelSession {
            session.stop(after: delay)
            sessions.removeValue(forKey: session.id)
        }
        tunnelSession = nil
        tunnelPort = nil
    }

    private static func availableLoopbackPort() throws -> Int {
        // Probe a random high port; go-ios additionally allocates userspace ports above it.
        for _ in 0..<20 {
            let port = UInt16.random(in: 49152...59000)
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            Darwin.close(fd)
            if result == 0 { return Int(port) }
        }
        throw ServiceError.commandFailed("Could not reserve a local port for the userspace tunnel.")
    }

    private func waitForRefresh() async throws {
        while refreshing {
            try await Task.sleep(nanoseconds: 50_000_000)
            if stopped { throw CancellationError() }
        }
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
    }

    private func disconnect() {
        let locationWasRunning = stopLocation()
        stopOwnedTunnel(after: locationWasRunning ? 0.3 : 0)
        status = .disconnected
        udid = nil
        needsDeviceName = false
        deviceName = ""
        connectionType = ""
        message = nil
        recommendsUSB = false
    }

    @discardableResult
    private func stopLocation() -> Bool {
        let wasRunning = locationSession?.process.isRunning == true
        if let session = locationSession {
            if wasRunning { stoppingLocation = session.process }
            session.stop()
            sessions.removeValue(forKey: session.id)
        }
        locationSession = nil
        locationRequest = nil
        acknowledgedLocationSession = nil
        simulated = false
        return wasRunning
    }

    private func waitForStoppedLocation() async throws {
        while stoppingLocation?.isRunning == true {
            try await Task.sleep(nanoseconds: 50_000_000)
            try Task.checkCancellation()
            if stopped { throw CancellationError() }
        }
        stoppingLocation = nil
    }

    private func launch(_ arguments: [String], agentPort: Int? = nil) throws -> CommandSession {
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        // Explicit child ownership: never let go-ios spawn a detached automatic agent.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ENABLE_GO_IOS_AGENT")
        // Discovery must see every transport. All other commands, including the tunnel
        // daemon's enumeration, are scoped to the selected device and connection type.
        environment.removeValue(forKey: "PARACHUTE_CONNECTION_TYPE")
        environment.removeValue(forKey: "GO_IOS_UDID")
        environment.removeValue(forKey: "udid")
        if arguments.first != "list", let udid, !connectionType.isEmpty {
            environment["PARACHUTE_CONNECTION_TYPE"] = connectionType
            environment["GO_IOS_UDID"] = udid
        }
        environment["GO_IOS_AGENT_HOST"] = "127.0.0.1"
        environment["GO_IOS_AGENT_PORT"] = String(agentPort ?? tunnelPort ?? 60105)
        let session = try CommandSession(binaryURL: binaryURL, arguments: arguments, runtimeURL: runtimeURL,
                                         diagnosticLog: diagnosticLog, environment: environment)
        sessions[session.id] = session
        return session
    }

    private func run(_ arguments: [String], timeout: TimeInterval = 10, agentPort: Int? = nil) async throws -> String {
        try Task.checkCancellation()
        let session = try launch(arguments, agentPort: agentPort)
        defer {
            session.stop()
            sessions.removeValue(forKey: session.id)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while session.process.isRunning {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
            if stopped { throw CancellationError() }
            if Date() > deadline { throw ServiceError.timedOut }
        }
        let output = session.output()
        guard session.process.terminationStatus == 0 else { throw ServiceError.commandFailed("\(session.commandLabel) exited with code \(session.process.terminationStatus):\n" + output) }
        return output
    }

    /// Prefer USB globally, retaining the selected phone when it still has USB.
    /// With no USB devices, preserve the selected wireless phone across list reordering.
    private static func selectDevice(_ devices: [[String: Any]], preferredIdentifier: String?) -> [String: Any]? {
        var byIdentifier: [String: [String: Any]] = [:]
        for device in devices {
            guard let identifier = (device["Udid"] ?? device["udid"]) as? String, !identifier.isEmpty,
                  let connection = device["ConnectionType"] as? String,
                  connection == "USB" || connection == "Network" else { continue }
            if byIdentifier[identifier] == nil || connection == "USB" {
                byIdentifier[identifier] = device
            }
        }
        if let preferredIdentifier, let selected = byIdentifier[preferredIdentifier],
           selected["ConnectionType"] as? String == "USB" { return selected }
        let identifiers = byIdentifier.keys.sorted()
        if let identifier = identifiers.first(where: { byIdentifier[$0]?["ConnectionType"] as? String == "USB" }) {
            return byIdentifier[identifier]
        }
        if let preferredIdentifier, let selected = byIdentifier[preferredIdentifier] { return selected }
        return identifiers.first.flatMap { byIdentifier[$0] }
    }

    private static func jsonValues(_ output: String) -> [Any] {
        if let data = output.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            return [object]
        }
        return output.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
    }

    private static func isTrustError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["readpair failed", "is the device paired", "invalidhostid", "lockdown", "pairingdialogresponsepending"]
            .contains { lower.contains($0) }
    }
}

private enum ServiceError: LocalizedError {
    case timedOut
    case commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .timedOut: return "go-ios command timed out."
        case .commandFailed(let output): return String(output.suffix(2_000))
        }
    }
}

/// Redirect output to a private temporary file, avoiding full pipes and blocking main-thread reads.
@MainActor
private final class CommandSession {
    let id = UUID()
    let process = Process()
    private let outputURL: URL
    private let handle: FileHandle
    private var stopped = false
    let commandLabel: String
    private let diagnosticLog: DiagnosticLog

    init(binaryURL: URL, arguments: [String], runtimeURL: URL, diagnosticLog: DiagnosticLog, environment: [String: String]) throws {
        let command = arguments.first ?? "unknown"
        commandLabel = ["devmode", "tunnel"].contains(command)
            ? arguments.prefix(2).joined(separator: " ") : command
        self.diagnosticLog = diagnosticLog
        outputURL = runtimeURL.appendingPathComponent("command-\(id.uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: outputURL)
        process.executableURL = binaryURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = runtimeURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
            diagnosticLog.record(command: commandLabel, event: "started")
        }
        catch {
            diagnosticLog.record(command: commandLabel, event: "launch-failed", output: error.localizedDescription)
            try? handle.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    func output() -> String {
        guard let reader = try? FileHandle(forReadingFrom: outputURL) else { return "" }
        defer { try? reader.close() }
        let size = (try? reader.seekToEnd()) ?? 0
        try? reader.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let data = (try? reader.read(upToCount: 65_536)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func stop(after delay: TimeInterval = 0) {
        guard !stopped else { return }
        stopped = true
        if process.isRunning {
            diagnosticLog.record(command: commandLabel, event: "stop-requested", output: output())
            let child = process
            let outputHandle = handle
            let temporaryOutput = outputURL
            // go-ios setlocation handles SIGINT to send StopSimulateLocation.
            let stopSignal = commandLabel == "setlocation" ? SIGINT : SIGTERM
            let terminateOwnedChild: @Sendable () -> Void = {
                if child.isRunning { Darwin.kill(child.processIdentifier, stopSignal) }
                // Off-main: app termination can defer delivery on the main dispatch queue.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
                    try? outputHandle.close()
                    try? FileManager.default.removeItem(at: temporaryOutput)
                }
            }
            if delay > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: terminateOwnedChild)
            } else {
                terminateOwnedChild()
            }
        } else {
            diagnosticLog.record(command: commandLabel, event: "exited", exitCode: process.terminationStatus, output: output())
            try? handle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
    }
}


/// Private, bounded diagnostics survive removal of per-command temporary output.
/// Command labels never include argv values; retained output is redacted as well.
@MainActor
private final class DiagnosticLog {
    let url: URL
    let lastFailureURL: URL
    var deviceIdentifier: String?
    private let maximumBytes = 262_144

    init(directory: URL) {
        url = directory.appendingPathComponent("diagnostic.log")
        lastFailureURL = directory.appendingPathComponent("last-action-failure.log")
    }

    func sanitize(_ output: String) -> String {
        var value = output
        if let deviceIdentifier, !deviceIdentifier.isEmpty {
            value = value.replacingOccurrences(of: deviceIdentifier, with: "[device]")
        }
        let patterns = [
            #"(?i)\b[0-9a-f]{8}-[0-9a-f]{16}\b|\b[0-9a-f]{40}\b"#,
            #"(?i)(--(?:udid|lat|lon|latitude|longitude)=)[^\s,]+"#,
            #"(?i)("(?:udid|lat|lon|latitude|longitude)"\s*:\s*)(?:"[^"]*"|[-+0-9.eE]+)"#,
            #"(?i)((?:latitude|longitude)\s*[:=]\s*)[-+0-9.eE]+"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            value = value.replacingOccurrences(of: pattern,
                with: index == 0 ? "[redacted-device]" : "$1[redacted]", options: .regularExpression)
        }
        return String(value.suffix(4_096))
    }

    func record(command: String, event: String, exitCode: Int32? = nil, output: String = "", preserveFailure: Bool = false) {
        let date = ISO8601DateFormatter().string(from: Date())
        let code = exitCode.map(String.init) ?? "pending"
        let detail = sanitize(output)
        let entry = "[\(date)] \(command) \(event) exit=\(code)\n" + (detail.isEmpty ? "" : detail + "\n")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data(entry.utf8)
            var accumulated = (try? Data(contentsOf: url)) ?? Data()
            accumulated.append(bytes)
            if accumulated.count > maximumBytes {
                accumulated = Data(accumulated.suffix(maximumBytes))
            }
            try accumulated.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if preserveFailure {
                try bytes.write(to: lastFailureURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lastFailureURL.path)
            }
        } catch {
            // Logging must not turn a device command into a failed operation.
            NSLog("Parachute diagnostic log write failed: %@", error.localizedDescription)
        }
    }
}
