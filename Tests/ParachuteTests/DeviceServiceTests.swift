import Foundation
import Darwin
import Combine

/// Standalone integration checks using a temporary fake executable only.
/// No connected device commands, privilege prompts, or system configuration changes.
/// swiftc -swift-version 5 Sources/Parachute/DeviceService.swift Tests/ParachuteTests/DeviceServiceTests.swift -o /tmp/device-service-tests
/// /tmp/device-service-tests
@main
struct DeviceServiceTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parachute-device-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("fake-ios")
        let script = #"""
        #!/bin/sh
        ROOT=${0%/*}
        MODE=$(cat "$ROOT/mode")
        case "$1" in
            list) [ -z "$PARACHUTE_CONNECTION_TYPE" ] && [ -z "$GO_IOS_UDID" ] && [ -z "$udid" ] || exit 94;;
            *) [ "$PARACHUTE_CONNECTION_TYPE" = USB ] || [ "$PARACHUTE_CONNECTION_TYPE" = Network ] || exit 95
               [ -n "$GO_IOS_UDID" ] || exit 96;;
        esac
        printf '%s|%s|%s\n' "$1" "$PARACHUTE_CONNECTION_TYPE" "$GO_IOS_UDID" >> "$ROOT/commands"
        if [ "$MODE" = hang ]; then
            echo $$ > "$ROOT/pid"
            exec /bin/sleep 20
        fi
        case "$1" in
        list)
            if [ "$MODE" = ios16 ]; then
                echo '{"deviceList":[{"Udid":"00008130-000C3DD901E0001C","ConnectionType":"USB","ProductVersion":"16.6"}]}'
            elif [ "$MODE" = network-discovery-fail ]; then
                echo '{"deviceList":[{"Udid":"00008130-000C3DD901E0001C","ConnectionType":"Network","Error":"wireless metadata unavailable"}]}'
            elif [ "$MODE" = duplicate-error ]; then
                echo '{"deviceList":[{"Udid":"00008130-000C3DD901E0001C","ConnectionType":"Network","Error":"wireless metadata unavailable"},{"Udid":"00008130-000C3DD901E0001C","ConnectionType":"USB"}]}'
            elif [ "$MODE" = network ] || [ "$MODE" = network-untrusted ] || [ "$MODE" = network-simulate-fail ] || [ "$MODE" = network-ack ]; then
                echo '{"deviceList":[{"Udid":"00008130-000C3DD901E0001C","ConnectionType":"Network"}]}'
            elif [ "$MODE" = disconnected ]; then
                echo '{"deviceList":[]}'
            elif [ "$MODE" = unknown ]; then
                echo '{"deviceList":[{"Udid":"unknown","ConnectionType":"Bluetooth"},{"Udid":"missing"}]}'
            elif [ "$MODE" = duplicate ] || [ "$MODE" = usb-arrived ]; then
                echo '{"deviceList":[{"Udid":"00008130-000C3DD901E0001C","ConnectionType":"Network"},{"Udid":"00008130-000C3DD901E0001C","ConnectionType":"USB"}]}'
            elif [ "$MODE" = multi ]; then
                echo '{"deviceList":[{"Udid":"device-a","ConnectionType":"Network"},{"Udid":"device-b","ConnectionType":"USB"}]}'
            elif [ "$MODE" = dual-usb ]; then
                echo '{"deviceList":[{"Udid":"device-a","ConnectionType":"USB"},{"Udid":"device-b","ConnectionType":"USB"}]}'
            elif [ "$MODE" = reordered ]; then
                echo '{"deviceList":[{"Udid":"device-b","ConnectionType":"Network"},{"Udid":"device-a","ConnectionType":"USB"}]}'
            elif [ "$MODE" = malformed ]; then
                echo 'service returned an unexpected payload'
            else
                echo '{"deviceList":[{"Udid":"00008130-000C3DD901E0001C","ConnectionType":"USB"}]}'
            fi;;
        devicename)
            echo called >> "$ROOT/name-lookups"
            case " $* " in
                *" --udid=device-a "*) echo '{"devicename":"Phone A"}';;
                *" --udid=device-b "*) echo '{"devicename":"Phone B"}';;
                *) echo '{"devicename":"Test iPhone"}';;
            esac;;
        devmode)
            if [ "$MODE" = untrusted ] || [ "$MODE" = network-untrusted ]; then echo 'InvalidHostID'; exit 1; fi
            if [ "$MODE" = dev-off ]; then echo '{"DeveloperModeEnabled":false}'; exit 0; fi
            echo '{"DeveloperModeEnabled":true}';;
        tunnel)
            if [ "$2" = start ]; then
                if [ "$MODE" = auto-tunnel ] || [ "$MODE" = tunnel-timeout ]; then
                    echo $$ > "$ROOT/tunnel-pid"
                    echo "$GO_IOS_AGENT_PORT" > "$ROOT/tunnel-port"
                    echo started >> "$ROOT/tunnel-starts"
                    [ -z "$ENABLE_GO_IOS_AGENT" ] || exit 91
                    case " $* " in *" --userspace "*) ;; *) exit 92;; esac
                    exec /bin/sleep 30
                fi
                echo 'tunnel startup fixture failed'; exit 23
            fi
            if [ "$MODE" = unknown-tunnel ]; then
                echo '[{"udid":"00008130-000C3DD901E0001C","rsdPort":1234,"address":"fd00::1"}]'
            elif [ "$MODE" = wrong-tunnel ]; then
                echo '[{"udid":"00008130-000C3DD901E0001C","rsdPort":1234,"address":"fd00::1","connectionType":"Network"}]'
            elif [ "$MODE" = simulate-fail ] || [ "$MODE" = ack ] || [ "$MODE" = ack-late ] || [ "$MODE" = no-ack ] || [ "$MODE" = no-ack-zero-exit ] || [ "$MODE" = ack-nonzero ] || [ "$MODE" = text-ack ] || [ "$MODE" = network-simulate-fail ] || [ "$MODE" = network-ack ] || [ "$MODE" = usb-arrived ]; then
                printf '[{"udid":"00008130-000C3DD901E0001C","rsdPort":1234,"address":"fd00::1","connectionType":"%s"}]\n' "$PARACHUTE_CONNECTION_TYPE"
            elif [ "$MODE" = auto-tunnel ] && [ "$GO_IOS_AGENT_PORT" != 60105 ] && [ -f "$ROOT/tunnel-pid" ] && kill -0 "$(cat "$ROOT/tunnel-pid")" 2>/dev/null; then
                printf '[{"udid":"00008130-000C3DD901E0001C","rsdPort":1234,"address":"fd00::1","userspaceTun":true,"connectionType":"%s"}]\n' "$PARACHUTE_CONNECTION_TYPE"
            else echo '[]'; fi;;
        setlocation)
            echo $$ > "$ROOT/location-pid"
            case "$MODE" in
                ack|network-ack) echo '{"event":"location-simulation-started","level":"info"}'; exec /bin/sleep 30;;
                usb-arrived) echo '{"event":"location-simulation-started","level":"info"}'; exit 0;;
                ack-late) /bin/sleep 2.4; echo '{"event":"location-simulation-started","level":"info"}'; exec /bin/sleep 30;;
                no-ack) exec /bin/sleep 30;;
                no-ack-zero-exit) trap 'exit 0' INT; while :; do /bin/sleep 0.1; done;;
                text-ack) echo 'location-simulation-started'; exec /bin/sleep 30;;
                ack-nonzero) echo '{"event":"location-simulation-started","level":"info"}'; exit 7;;
            esac
            if [ "$MODE" = auto-tunnel ]; then
                [ "$GO_IOS_AGENT_PORT" = "$(cat "$ROOT/tunnel-port")" ] || exit 93
                echo 'fake location request completed'; exit 0
            fi
            echo '{"level":"fatal","msg":"failure-fixture","udid":"00008130-000C3DD901E0001C","lat":37.3346,"lon":-122.009}'
            echo 'argv --udid=00008130-000C3DD901E0001C --lat=37.3346 --lon=-122.009'
            exit 7;;
        *) echo 'Unexpected device-mutating command in test'; exit 55;;
        esac
        """#
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        func mode(_ value: String) throws {
            try value.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        }
        func commands() -> [String] {
            guard let text = try? String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8) else {
                fatalError("The fake helper did not record any commands")
            }
            return text.split(separator: "\n").map(String.init)
        }
        // Only this test process inherits these sentinel values. Discovery must clear
        // them, and targeted commands must replace them with the actual selection.
        setenv("PARACHUTE_CONNECTION_TYPE", "invalid-inherited-transport", 1)
        setenv("GO_IOS_UDID", "wrong-inherited-device", 1)
        setenv("udid", "wrong-legacy-device", 1)
        let device = DeviceService(binaryURL: binary, runtimeURL: root.appendingPathComponent("runtime"), tunnelStartupTimeout: 0.8)
        defer { device.stop() }
        try mode("network")
        await device.refresh()
        precondition(device.status == .connected && device.connectionType == "Network", "Developer Mode confirms connection, not location-service readiness")
        precondition(commands().contains("devmode|Network|00008130-000C3DD901E0001C"), "Wireless commands must select the wireless device explicitly")
        try mode("duplicate")
        await device.refresh()
        precondition(device.status == .connected && device.connectionType == "USB", "Duplicate transports should prefer the USB record for the same device")
        precondition(commands().contains("devmode|USB|00008130-000C3DD901E0001C"), "USB preference must reach the helper, not only the displayed label")
        try mode("network")
        await device.refresh()
        let lookups = try String(contentsOf: root.appendingPathComponent("name-lookups"), encoding: .utf8).split(separator: "\n")
        precondition(device.connectionType == "Network" && lookups.count == 1, "Same-device USB to network fallback must not reset identity")
        try mode("usb-arrived")
        await device.simulate(latitude: 0, longitude: 0)
        precondition(device.connectionType == "USB" && device.simulated && commands().last == "setlocation|USB|00008130-000C3DD901E0001C", "A cable attached between polls must be preferred by the next location request")

        try mode("disconnected")
        await device.refresh()
        precondition(device.status == .disconnected && device.connectionType.isEmpty, "No devices should clear the transport")
        try mode("multi")
        await device.refresh()
        precondition(device.deviceName == "Phone B" && device.connectionType == "USB", "New selection should prefer a USB device over a network device")
        try mode("dual-usb")
        await device.refresh()
        precondition(device.deviceName == "Phone B" && device.connectionType == "USB", "An existing USB selection should remain stable when another USB device appears")
        try mode("reordered")
        await device.simulate(latitude: 0, longitude: 0)
        precondition(device.deviceName == "Phone A" && device.connectionType == "USB" && commands().contains("devmode|USB|device-a"), "A different USB phone must take precedence over a retained wireless phone at request time")
        try mode("unknown")
        await device.refresh()
        precondition(device.status == .disconnected && device.connectionType.isEmpty, "Unknown or missing transport types must be ignored")

        try mode("network-discovery-fail")
        await device.refresh()
        precondition(device.status == .error && device.recommendsUSB && device.message == "device.discoveryFailed", "A failed wireless discovery record must show USB guidance")
        try mode("network")
        await device.refresh()
        precondition(device.status == .connected && device.recommendsUSB && device.message == "device.discoveryFailed", "Polling must preserve failure guidance until the user retries or reconnects")
        try mode("network-untrusted")
        await device.refresh()
        precondition(device.status == .untrusted && device.recommendsUSB, "Wireless trust failures must recommend a USB connection")
        try mode("network")
        await device.refresh()
        await device.simulate(latitude: 0, longitude: 0)
        precondition(device.message == "device.simulationFailed" && device.recommendsUSB, "Wireless tunnel failures must recommend USB")
        try mode("network-simulate-fail")
        await device.refresh()
        await device.simulate(latitude: 0, longitude: 0)
        precondition(device.message == "device.simulationFailed" && device.recommendsUSB && device.diagnostic.contains("failure-fixture"), "Wireless location-command failures must preserve details and recommend USB")
        try mode("network-ack")
        await device.refresh()
        await device.simulate(latitude: 0, longitude: 0)
        precondition(device.message == "device.success" && device.simulated && !device.recommendsUSB, "A confirmed wireless simulation must clear the previous USB recommendation")
        let wirelessPID = Int32(try String(contentsOf: root.appendingPathComponent("location-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        let startsBeforeTransportChange = commands().filter { $0.hasPrefix("setlocation|") }.count
        try mode("duplicate-error")
        await device.refresh()
        precondition(device.status == .connected && device.connectionType == "USB" && !device.simulated && !device.recommendsUSB, "A bad network record must not hide its healthy USB record; switching transports stops simulation")
        precondition(device.message == "device.connectionChanged", "Transport changes must tell the user to start a new session")
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(kill(wirelessPID, 0) != 0, "Switching from wireless to USB must stop the old location process")
        precondition(commands().filter { $0.hasPrefix("setlocation|") }.count == startsBeforeTransportChange, "Transport changes must not silently resume simulation")

        try mode("ready")
        await device.refresh()
        precondition(device.status == .connected && device.deviceName == "Test iPhone", "USB device should be connected without promising tunnel readiness")

        await device.simulate(latitude: 0, longitude: 0)
        precondition(device.message == "device.simulationFailed" && !device.simulated && device.diagnostic.contains("tunnel startup fixture failed"), "A failed tunnel startup must never be reported as simulation success")

        await device.simulate(latitude: 91, longitude: 0)
        precondition(device.message == "device.invalidCoordinates", "Invalid coordinates must not reach the executable")

        for invalidTunnel in ["unknown-tunnel", "wrong-tunnel"] {
            try mode(invalidTunnel)
            await device.refresh()
            let priorLocationCommands = commands().filter { $0.hasPrefix("setlocation|") }.count
            await device.simulate(latitude: 0, longitude: 0)
            precondition(!device.simulated && device.diagnostic.contains("tunnel startup fixture failed"), "An external tunnel with unknown or mismatched transport must not be reused")
            precondition(commands().filter { $0.hasPrefix("setlocation|") }.count == priorLocationCommands, "A rejected external tunnel must not receive a location request")
        }

        try mode("simulate-fail")
        await device.refresh()
        await device.simulate(latitude: 37.3346, longitude: -122.009)
        precondition(device.message == "device.simulationFailed" && device.diagnostic.contains("failure-fixture"), "Preserve actual command failure detail")
        let failure = try String(contentsOf: device.lastFailureLogURL, encoding: .utf8)
        let log = try String(contentsOf: device.diagnosticLogURL, encoding: .utf8)
        for value in [failure, log, device.diagnostic] {
            precondition(!value.contains("00008130-000C3DD901E0001C") && !value.contains("37.3346") && !value.contains("-122.009"), "Diagnostics must redact device IDs and coordinates")
        }
        precondition(log.contains("exit=7") && failure.contains("failure-fixture"), "Durable log should include exit status and failure evidence")
        try Data(repeating: 65, count: 300_000).write(to: device.diagnosticLogURL)
        try mode("ready")
        await device.refresh()
        let boundedLog = try Data(contentsOf: device.diagnosticLogURL)
        precondition(boundedLog.count <= 262_144, "Diagnostic log must remain bounded")
        let preservedFailure = try String(contentsOf: device.lastFailureLogURL, encoding: .utf8)
        precondition(preservedFailure == failure, "Polling must not overwrite last action failure")

        try mode("auto-tunnel")
        await device.refresh()
        await device.simulate(latitude: 0, longitude: 0)
        precondition(device.simulated && device.message == "device.commandCompleted", "Owned tunnel must become device-ready before location is sent")
        precondition(device.lastSuccessfulSimulation?.latitude == 0 && device.lastSuccessfulSimulation?.longitude == 0, "Uncancelled successful exit should publish the original coordinates")
        let ownedPort = try String(contentsOf: root.appendingPathComponent("tunnel-port"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(ownedPort != "60105", "Owned tunnel must use an isolated port")
        await device.simulate(latitude: 0, longitude: 0)
        let starts = try String(contentsOf: root.appendingPathComponent("tunnel-starts"), encoding: .utf8).split(separator: "\n")
        precondition(starts.count == 1, "Updating location must reuse the owned tunnel")
        let ownedPIDText = try String(contentsOf: root.appendingPathComponent("tunnel-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try mode("network")
        await device.refresh()
        precondition(device.status == .connected && device.connectionType == "Network" && !device.simulated && device.message == "device.connectionChanged", "USB-to-wireless fallback must require an explicit new simulation")
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(kill(Int32(ownedPIDText)!, 0) != 0, "A transport change must stop the app-owned tunnel instead of reusing stale metadata")
        try mode("disconnected")
        await device.refresh()
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(kill(Int32(ownedPIDText)!, 0) != 0, "Disconnect must stop the app-owned tunnel")

        try mode("tunnel-timeout")
        await device.refresh()
        await device.simulate(latitude: 0, longitude: 0)
        precondition(!device.simulated && device.diagnostic.contains("Timed out waiting"), "A live tunnel process without a matching ready device must time out")
        let timeoutPIDText = try String(contentsOf: root.appendingPathComponent("tunnel-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(kill(Int32(timeoutPIDText)!, 0) != 0, "Timed-out startup must clean its owned tunnel")

        try mode("dev-off")
        await device.refresh()
        precondition(device.status == .developerModeOff, "Disabled Developer Mode must be reflected in the UI")

        try mode("untrusted")
        await device.refresh()
        precondition(device.status == .untrusted, "Pairing errors should produce a trust prompt")

        let missing = DeviceService(binaryURL: root.appendingPathComponent("nonexistent"), runtimeURL: root.appendingPathComponent("missing-runtime"))
        await missing.refresh()
        precondition(missing.status == .error && missing.message == "device.binaryMissing", "Missing go-ios must be explicit")
        missing.stop()

        try mode("malformed")
        await device.refresh()
        precondition(device.status == .error && device.message == "device.discoveryFailed", "Malformed discovery must not masquerade as an empty device list")

        try mode("hang")
        let refresh = Task { await device.refresh() }
        let pidURL = root.appendingPathComponent("pid")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pidURL.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let pidText = try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(pidText) else { fatalError("Invalid fake process ID") }
        device.stop()
        await refresh.value
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(kill(pid, 0) != 0, "Owned subprocess must be gone after stop")
        let events = DeviceService(binaryURL: binary, runtimeURL: root.appendingPathComponent("events-runtime"))
        defer { events.stop() }
        var emittedEvents: [DeviceService.SuccessfulSimulation] = []
        let subscription = events.$lastSuccessfulSimulation.compactMap { $0 }.sink { emittedEvents.append($0) }
        defer { subscription.cancel() }
        try mode("no-ack-zero-exit")
        await events.refresh()
        await events.simulate(latitude: 12.25, longitude: -45.75)
        precondition(events.lastSuccessfulSimulation == nil, "A running child without acknowledgement must never emit success")

        try mode("ack")
        await events.simulate(latitude: 12.25, longitude: -45.75)
        guard let first = events.lastSuccessfulSimulation else { fatalError("Structured acknowledgement should emit success") }
        precondition(emittedEvents.count == 1, "An intentionally interrupted previous command exiting zero must not emit an event")
        precondition(first.latitude == 12.25 && first.longitude == -45.75, "Event coordinates must belong to the acknowledged request")
        await events.simulate(latitude: 12.25, longitude: -45.75)
        guard let repeated = events.lastSuccessfulSimulation else { fatalError("Repeat acknowledgement should emit success") }
        precondition(repeated.id != first.id && repeated.latitude == first.latitude && repeated.longitude == first.longitude, "Repeating the same coordinate must still have a distinct event identity")

        try mode("ack-nonzero")
        await events.simulate(latitude: 9, longitude: 10)
        precondition(events.lastSuccessfulSimulation == repeated, "Nonzero exit must not emit a success event")
        try mode("text-ack")
        await events.simulate(latitude: 9, longitude: 10)
        precondition(events.lastSuccessfulSimulation == repeated, "An unstructured text match is not an acknowledgement")

        try mode("ack-late")
        await events.simulate(latitude: -23.5, longitude: 167.25)
        precondition(events.lastSuccessfulSimulation == repeated, "A late acknowledgement must not be guessed after two seconds")
        try await Task.sleep(nanoseconds: 800_000_000)
        await events.refresh()
        guard let delayed = events.lastSuccessfulSimulation else { fatalError("Delayed acknowledgement should be observed by polling") }
        precondition(delayed.id != repeated.id && delayed.latitude == -23.5 && delayed.longitude == 167.25, "Late acknowledgement must retain the original requested coordinates")
        try mode("disconnected")
        await events.refresh()
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(events.lastSuccessfulSimulation == delayed, "Disconnect cleanup must neither emit success nor erase the previous event")

        try mode("ios16")
        await events.refresh()
        precondition(events.status == .connected, "Prepare a connected pre-tunnel device for cancellation")
        let locationCommandsBeforeCancel = commands().filter { $0.hasPrefix("setlocation|") }.count
        try? FileManager.default.removeItem(at: pidURL)
        try mode("hang")
        let cancelledAction = Task { await events.simulate(latitude: 0, longitude: 0) }
        let cancellationDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: pidURL.path) && Date() < cancellationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let cancelledPID = Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        cancelledAction.cancel()
        await cancelledAction.value
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(commands().filter { $0.hasPrefix("setlocation|") }.count == locationCommandsBeforeCancel, "Cancelling fresh discovery must not send a location using a previously connected device")
        precondition(kill(cancelledPID, 0) != 0 && !events.busy, "Cancelled action discovery must clean its child and release the busy state")
        print("Passed fake-device checks for explicit USB/network selection, isolated discovery, honest connection status, wireless failure guidance and recovery, transport-change cleanup, strict tunnel transport matching, command acknowledgements, cancellation, bounded diagnostics and existing device behavior.")
    }
}
