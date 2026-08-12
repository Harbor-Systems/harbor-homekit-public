import AppKit
import Network
import SwiftUI

private enum HarborBrand {
    static let primary = Color(red: 168 / 255, green: 94 / 255, blue: 138 / 255)
    static let highlight = Color(red: 237 / 255, green: 244 / 255, blue: 249 / 255)
}

private final class HomeKitDiscoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<Bool, Never>
    var browser: NWBrowser?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        browser?.cancel()
        continuation.resume(returning: result)
    }
}

private struct HarborHeader: View {
    private var logo: NSImage? {
        guard let url = Bundle.main.url(forResource: "HarborLogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        HStack(spacing: 14) {
            if let logo {
                Image(nsImage: logo).resizable().scaledToFit().frame(width: 174, height: 42)
            }
            Text("HomeKit setup").font(.headline).foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class SetupModel: ObservableObject {
    enum Step { case moveToApplications, camera, installing, harborApp, network, discovery, homeKit, bridge }

    @Published var step: Step = .camera
    @Published var bridgeRunning = false
    @Published var bridgeManaged = false
    @Published var bridgeBusy = false
    @Published var installedSetupCode = ""
    @Published var configuredSerials: [String] = []
    @Published var networkReservationConfirmed = false

    // On a read-only volume (the mounted disk image, or Gatekeeper's
    // translocation mount) installation is the only sensible path forward.
    let mustMove = (try? Bundle.main.bundleURL
        .resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false

    init() {
        if !Self.isInApplicationsFolder {
            step = .moveToApplications
        } else if Self.isBridgeInstalled {
            showBridgePanel()
        }
    }

    private nonisolated static var serviceTarget: String { "gui/\(getuid())/co.harbor.homekit" }

    private nonisolated static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/co.harbor.homekit.plist")
    }

    nonisolated static var isBridgeInstalled: Bool {
        FileManager.default.fileExists(atPath: agentPlist.path)
    }

    func showBridgePanel() {
        errorMessage = ""
        loadInstalledSetupCode()
        refreshBridgeStatus()
        step = .bridge
    }

    private func loadInstalledSetupCode() {
        installedSetupCode = ""
        configuredSerials = []
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Harbor HomeKit/go2rtc.yaml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return }
        var inStreams = false
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "streams:" {
                inStreams = true
                continue
            }
            if inStreams && !line.hasPrefix(" ") && !trimmed.hasPrefix("#") {
                inStreams = false
            }
            if inStreams, line.hasPrefix("  \""), trimmed.hasSuffix("\":") {
                let value = trimmed.dropFirst().dropLast(2)
                configuredSerials.append(String(value))
            }
            guard trimmed.hasPrefix("pin:") else { continue }
            let digits = trimmed.dropFirst(4).prefix { $0 != "#" }.filter(\.isNumber)
            if digits.count == 8 {
                installedSetupCode = Self.formatSetupCode(String(digits))
            }
            return
        }
    }

    func refreshBridgeStatus() {
        Task.detached {
            await self.updateBridgeStatus()
        }
    }

    // Keep the panel truthful while it is visible; the task is cancelled when
    // the view goes away.
    func autoRefreshBridge() async {
        while !Task.isCancelled && step == .bridge {
            await updateBridgeStatus()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private nonisolated func updateBridgeStatus() async {
        let result = Self.runLaunchctl(["print", Self.serviceTarget])
        let managed = result.status == 0 && result.output.contains("state = running")
        // The bridge may also run outside launchd (run-native.sh in a
        // terminal); the local API is the ground truth for "running".
        let responding = await Self.probeBridgeAPI()
        await MainActor.run {
            self.bridgeManaged = managed
            self.bridgeRunning = managed || responding
        }
    }

    private nonisolated static func probeBridgeAPI() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:1985/api/streams") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func toggleBridge() {
        bridgeBusy = true
        errorMessage = ""
        let starting = !bridgeRunning
        let managed = bridgeManaged
        Task.detached {
            let failure: String
            if starting {
                _ = Self.runLaunchctl(["enable", Self.serviceTarget])
                _ = Self.runLaunchctl(["bootstrap", "gui/\(getuid())", Self.agentPlist.path])
                let kick = Self.runLaunchctl(["kickstart", Self.serviceTarget])
                failure = kick.status == 0 ? "" : "The bridge could not be started: \(kick.output)"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            } else if managed {
                // Disable so a stopped bridge stays stopped across logins
                // until it is started again.
                _ = Self.runLaunchctl(["disable", Self.serviceTarget])
                _ = Self.runLaunchctl(["bootout", Self.serviceTarget])
                failure = ""
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } else {
                // Started outside launchd (for example run-native.sh in a
                // terminal): stop whatever owns the bridge ports, matching
                // the same ground truth the status probe uses.
                await Self.terminateUnmanagedBridge()
                failure = ""
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await self.updateBridgeStatus()
            await MainActor.run {
                self.bridgeBusy = false
                if !failure.isEmpty {
                    self.errorMessage = failure
                } else if !starting && self.bridgeRunning {
                    self.errorMessage = "The bridge could not be stopped. Stop it from the session that started it."
                }
            }
        }
    }

    private nonisolated static func bridgePortOwners() -> [pid_t] {
        let result = runCommand(
            "/usr/sbin/lsof",
            ["-t", "-sTCP:LISTEN", "-i", "tcp:1984", "-i", "tcp:1985"]
        )
        let pids = result.output.split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        return Array(Set(pids)).filter { $0 > 0 && $0 != ProcessInfo.processInfo.processIdentifier }
    }

    private nonisolated static func terminateUnmanagedBridge() async {
        for pid in bridgePortOwners() {
            kill(pid, SIGTERM)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for pid in bridgePortOwners() {
            kill(pid, SIGKILL)
        }
    }

    private nonisolated static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        runCommand("/bin/launchctl", arguments)
    }

    private nonisolated static func runCommand(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (1, error.localizedDescription)
        }
    }
    @Published var serial = ""
    @Published var endpoint = ""
    @Published var setupCode = ""
    @Published var detail = ""
    @Published var errorMessage = ""

    var serialIsValid: Bool {
        !serial.isEmpty && serial.allSatisfy { $0.isNumber || $0 == "-" || $0 == "_" }
    }

    var bridgeIPAddress: String {
        URL(string: endpoint)?.host ?? "the IP address shown in the WHIP endpoint"
    }

    func install() {
        guard serialIsValid else { return }
        step = .installing
        detail = "Installing and starting the Harbor HomeKit bridge…"
        errorMessage = ""

        Task.detached {
            let result = Self.runInstaller(serial: await self.serial)
            let installed = await MainActor.run {
                if result.status == 0,
                   let endpoint = Self.value(after: "Harbor camera WHIP endpoint:", in: result.output),
                   let code = Self.inlineValue(after: "HomeKit setup code:", in: result.output) {
                    self.endpoint = endpoint
                    self.setupCode = Self.formatSetupCode(code)
                    self.step = .harborApp
                    self.detail = ""
                    return true
                } else {
                    self.step = .camera
                    self.errorMessage = result.output.isEmpty ? "Installation failed without an error message." : result.output
                    return false
                }
            }
            guard installed else { return }
            // Starting an NWBrowser from this foreground, signed app is what
            // causes macOS to request Local Network access. The setup app and
            // installed background bridge intentionally share a bundle ID, so
            // the grant applies when launchd starts the bridge later.
            _ = await Self.waitForHomeKitAdvertisement(timeout: 2)
        }
    }

    // Gatekeeper runs quarantined downloads from a randomized, read-only
    // translocation path, so anything outside a real Applications folder —
    // including the mounted disk image — should prompt a move.
    private static var isInApplicationsFolder: Bool {
        let bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let applicationDirectories =
            NSSearchPathForDirectoriesInDomains(.applicationDirectory, .localDomainMask, true)
            + NSSearchPathForDirectoriesInDomains(.applicationDirectory, .userDomainMask, true)
        return applicationDirectories.contains { bundlePath.hasPrefix($0 + "/") }
    }

    func moveToApplications() {
        errorMessage = ""
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        do {
            let fileManager = FileManager.default
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(source.lastPathComponent).\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(at: source, to: staging)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            errorMessage = "Could not move the app automatically (\(error.localizedDescription)). In Finder, drag Harbor HomeKit Bridge into the Applications folder, then open it from there."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            Task { @MainActor in
                if error == nil {
                    NSApp.terminate(nil)
                } else {
                    self.errorMessage = "Moved the app into Applications, but it could not be reopened automatically. Open Harbor HomeKit Bridge from the Applications folder to continue."
                }
            }
        }
    }

    func continueWithoutMoving() {
        errorMessage = ""
        if Self.isBridgeInstalled {
            showBridgePanel()
        } else {
            step = .camera
        }
    }

    func verifyCamera() {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Harbor HomeKit/.harbor-whip-connected.\(serial)")
        if FileManager.default.fileExists(atPath: marker.path) {
            if !configuredSerials.contains(serial) {
                configuredSerials.append(serial)
            }
            step = networkReservationConfirmed ? .homeKit : .network
            errorMessage = ""
        } else {
            errorMessage = "No camera stream has reached this Mac yet. Save the complete WHIP URL in the Harbor app, wait a few seconds, then check again."
        }
    }

    func confirmNetworkReservation() {
        networkReservationConfirmed = true
        step = .discovery
        detail = "Checking that Apple Home can discover the camera…"
        errorMessage = ""
        Task.detached {
            let visible = await Self.waitForHomeKitAdvertisement(timeout: 12)
            await MainActor.run {
                self.detail = ""
                if visible {
                    self.step = .homeKit
                } else {
                    self.step = .network
                    self.errorMessage = "HomeKit discovery is blocked. Open System Settings > Privacy & Security > Local Network, enable Harbor HomeKit Bridge, then click Check Discovery Again."
                }
            }
        }
    }

    func retryDiscovery() { confirmNetworkReservation() }

    private nonisolated static func waitForHomeKitAdvertisement(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: "_hap._tcp", domain: "local."), using: .tcp)
            let queue = DispatchQueue(label: "co.harbor.homekit.discovery")
            let probe = HomeKitDiscoveryProbe(continuation)
            probe.browser = browser
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { probe.finish(true) }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { probe.finish(false) }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { probe.finish(false) }
        }
    }

    func addAnotherCamera() {
        serial = ""
        endpoint = ""
        detail = ""
        errorMessage = ""
        networkReservationConfirmed = false
        step = .camera
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private nonisolated static func runInstaller(serial: String) -> (status: Int32, output: String) {
        guard let resources = Bundle.main.resourceURL else {
            return (1, "The setup application is missing its installer resources.")
        }
        let installer = resources.appendingPathComponent("installer/install-macos-service.sh")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installer.path, "--camera-serial", serial,
                             resources.appendingPathComponent("installer/go2rtc.yaml").path]
        process.currentDirectoryURL = resources.appendingPathComponent("installer")
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (1, "Could not start the installer: \(error.localizedDescription)")
        }
    }

    // Match the Home app's code-entry grouping (####-####) so the displayed
    // code mirrors what the user sees while typing it.
    private static func formatSetupCode(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 8 else { return raw }
        return "\(digits.prefix(4))-\(digits.suffix(4))"
    }

    private static func inlineValue(after label: String, in output: String) -> String? {
        output.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard text.hasPrefix(label) else { return nil }
            return text.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        }.first
    }

    private static func value(after label: String, in output: String) -> String? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(of: label), lines.indices.contains(index + 1) else { return nil }
        let value = lines[index + 1].trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("http://") ? value : nil
    }
}

struct SetupView: View {
    @StateObject private var model = SetupModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HarborHeader()
            Divider()
            switch model.step {
            case .moveToApplications: moveToApplicationsStep
            case .camera: cameraStep
            case .installing: installingStep
            case .harborApp: harborAppStep
            case .network: networkStep
            case .discovery: discoveryStep
            case .homeKit: homeKitStep
            case .bridge: bridgeStep
            }
            if !model.errorMessage.isEmpty {
                Text(model.errorMessage).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxHeight: 130).padding(.top, 4)
            }
            Spacer()
        }
        .padding(28)
        .frame(width: 620, height: 480)
        .tint(HarborBrand.primary)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var moveToApplicationsStep: some View {
        Group {
            Text("Install Harbor HomeKit Bridge").font(.title2).bold()
            if model.mustMove {
                Text("Harbor HomeKit Bridge needs to be installed in your Applications folder before it can set up your camera.")
                Text("Drag Harbor HomeKit Bridge into Applications in the download window, or click Move to Applications to install it now.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Harbor HomeKit Bridge is running from a temporary location. Keeping it in Applications means it stays on this Mac after the download is cleaned up, so you can reopen it any time to see your camera details.")
                Text("Click the button below, or drag Harbor HomeKit Bridge onto the Applications folder in Finder and reopen it.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Move to Applications") { model.moveToApplications() }
                    .buttonStyle(.borderedProminent)
                if model.mustMove {
                    Button("Quit") { NSApp.terminate(nil) }
                } else {
                    Button("Continue Without Moving") { model.continueWithoutMoving() }
                }
            }
        }
    }

    private var cameraStep: some View {
        Group {
            Text(model.configuredSerials.isEmpty
                 ? "Connect your Harbor cameras to Apple Home. The bridge will start automatically whenever you log into this Mac."
                 : "Add another Harbor camera to this HomeKit bridge.")
            if !model.configuredSerials.isEmpty {
                Text("Already configured: \(model.configuredSerials.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Camera serial number").font(.headline)
            TextField("For example, 2400000000", text: $model.serial)
                .textFieldStyle(.roundedBorder)
            Text("You can find the serial in the Harbor app under Camera Settings.")
                .foregroundStyle(.secondary)
            Button(model.configuredSerials.isEmpty ? "Install Bridge" : "Add Camera") { model.install() }
                .buttonStyle(.borderedProminent).disabled(!model.serialIsValid)
        }
    }

    private var installingStep: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text(model.detail)
        }
    }

    private var harborAppStep: some View {
        Group {
            Label("Bridge installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Now point your camera at this Mac").font(.title2).bold()
            VStack(alignment: .leading, spacing: 7) {
                Text("1. Open the Harbor app and tap Live.")
                Text("2. Open Camera Settings, then Advanced Settings.")
                Text("3. Copy the complete WHIP endpoint below.")
                Text("4. Paste it into the WHIP endpoint field and save.")
                Text("5. Wait a few seconds, then click Check Camera Connection.")
            }
            Text(model.endpoint).font(.system(.body, design: .monospaced))
                .textSelection(.enabled).padding(10).background(HarborBrand.highlight.opacity(0.7)).cornerRadius(8)
            HStack {
                Button("Copy WHIP Endpoint") { model.copy(model.endpoint) }
                Button("Check Camera Connection") { model.verifyCamera() }
                    .buttonStyle(.borderedProminent)
            }
            Text("Treat this URL like a password. It only permits this camera to publish to this bridge.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var homeKitStep: some View {
        Group {
            Label("Camera connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Add Harbor Camera to Apple Home").font(.title2).bold()
            VStack(alignment: .leading, spacing: 7) {
                Text("1. Open the Home app on your iPhone or iPad.")
                Text("2. Tap +, then Add Accessory.")
                Text("3. Tap More Options and select Harbor Camera.")
                Text("4. Choose Enter code and type the setup code below.")
            }
            Text(model.setupCode).font(.system(size: 34, weight: .bold, design: .monospaced))
                .padding(.vertical, 8)
            HStack {
                Button("Copy Setup Code") { model.copy(model.setupCode) }
                Button("Add Another Camera") { model.addAnotherCamera() }
                Button("Done") { model.showBridgePanel() }
                    .buttonStyle(.borderedProminent)
            }
            Text("Keep this code private. Reinstalling preserves it so the camera remains paired.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var networkStep: some View {
        Group {
            Label("Camera connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Keep this Mac at the same IP address").font(.title2).bold()
            Text("Required before you continue")
                .font(.headline).foregroundStyle(.orange)
            Text("Your camera connects to this Mac at \(model.bridgeIPAddress). If your router gives the Mac a different address after a restart, the camera will stop working in Apple Home.")
            VStack(alignment: .leading, spacing: 7) {
                Text("1. Open your router or Wi-Fi system's app.")
                Text("2. Find this Mac under connected devices.")
                Text("3. Create a DHCP/IP reservation for \(model.bridgeIPAddress).")
                Text("4. Save the reservation. Do not create a port-forwarding rule.")
            }
            Text("This may be called DHCP reservation, IP reservation, reserved address, or static lease. It keeps the address stable without manually changing macOS network settings.")
                .font(.caption).foregroundStyle(.secondary)
            Button("I've Reserved This IP") { model.confirmNetworkReservation() }
                .buttonStyle(.borderedProminent)
            if !model.errorMessage.isEmpty {
                Button("Check Discovery Again") { model.retryDiscovery() }
            }
        }
    }

    private var discoveryStep: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text(model.detail)
        }
    }

    private var bridgeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.bridgeRunning ? "Bridge is running" : "Bridge is stopped",
                  systemImage: model.bridgeRunning ? "checkmark.circle.fill" : "pause.circle.fill")
                .foregroundStyle(model.bridgeRunning ? .green : .orange)
                .font(.title3)
            if model.bridgeRunning && !model.bridgeManaged {
                Text("The bridge is running outside the managed background service — for example from a terminal session. Stopping it here ends those processes; starting it again runs it as the managed background service.")
            } else {
                Text(model.bridgeRunning
                     ? "Your Harbor camera is available in Apple Home while the bridge runs. The bridge starts automatically when you log into this Mac."
                     : "Apple Home cannot reach your Harbor camera while the bridge is stopped. It stays stopped, including after a restart, until you start it again.")
            }
            if !model.installedSetupCode.isEmpty {
                Text("HomeKit setup code").font(.headline)
                HStack(spacing: 12) {
                    Text(model.installedSetupCode)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                    Button("Copy") { model.copy(model.installedSetupCode) }
                }
            }
            HStack {
                Button(model.bridgeRunning ? "Stop Bridge" : "Start Bridge") { model.toggleBridge() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.bridgeBusy)
                Button("Run Setup Again") { model.step = .camera }
                    .disabled(model.bridgeBusy)
                if model.bridgeBusy { ProgressView().controlSize(.small) }
            }
        }
        .task { await model.autoRefreshBridge() }
    }
}

@main
struct HarborHomeKitSetupApp: App {
    var body: some Scene {
        WindowGroup { SetupView() }
            .windowResizability(.contentSize)
    }
}
