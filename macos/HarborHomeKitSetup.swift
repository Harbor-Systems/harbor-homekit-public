import AppKit
import SwiftUI

@MainActor
final class SetupModel: ObservableObject {
    enum Step { case camera, installing, harborApp, homeKit }

    @Published var step: Step = .camera
    @Published var serial = ""
    @Published var endpoint = ""
    @Published var setupCode = ""
    @Published var detail = ""
    @Published var errorMessage = ""

    var serialIsValid: Bool {
        !serial.isEmpty && serial.allSatisfy { $0.isNumber || $0 == "-" || $0 == "_" }
    }

    func install() {
        guard serialIsValid else { return }
        step = .installing
        detail = "Installing and starting the Harbor HomeKit bridge…"
        errorMessage = ""

        Task.detached {
            let result = Self.runInstaller(serial: await self.serial)
            await MainActor.run {
                if result.status == 0,
                   let endpoint = Self.value(after: "Harbor camera WHIP endpoint:", in: result.output),
                   let code = Self.inlineValue(after: "HomeKit setup code:", in: result.output) {
                    self.endpoint = endpoint
                    self.setupCode = code
                    self.step = .harborApp
                    self.detail = ""
                } else {
                    self.step = .camera
                    self.errorMessage = result.output.isEmpty ? "Installation failed without an error message." : result.output
                }
            }
        }
    }

    func verifyCamera() {
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Harbor HomeKit/.harbor-whip-connected")
        if FileManager.default.fileExists(atPath: marker.path) {
            step = .homeKit
            errorMessage = ""
        } else {
            errorMessage = "No camera stream has reached this Mac yet. Save the complete WHIP URL in the Harbor app, wait a few seconds, then check again."
        }
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
            Text("Harbor HomeKit Setup").font(.largeTitle).bold()
            switch model.step {
            case .camera: cameraStep
            case .installing: installingStep
            case .harborApp: harborAppStep
            case .homeKit: homeKitStep
            }
            if !model.errorMessage.isEmpty {
                Text(model.errorMessage).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxHeight: 130).padding(.top, 4)
            }
            Spacer()
        }
        .padding(28)
        .frame(width: 620, height: 480)
    }

    private var cameraStep: some View {
        Group {
            Text("Connect your Harbor camera to Apple Home. The bridge will start automatically whenever you log into this Mac.")
            Text("Camera serial number").font(.headline)
            TextField("For example, 2400000000", text: $model.serial)
                .textFieldStyle(.roundedBorder)
            Text("You can find the serial in the Harbor app under Camera Settings.")
                .foregroundStyle(.secondary)
            Button("Install Bridge") { model.install() }
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
                .textSelection(.enabled).padding(10).background(.quaternary).cornerRadius(8)
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
            Button("Copy Setup Code") { model.copy(model.setupCode) }
            Text("Keep this code private. Reinstalling preserves it so the camera remains paired.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@main
struct HarborHomeKitSetupApp: App {
    var body: some Scene {
        WindowGroup { SetupView() }
            .windowResizability(.contentSize)
    }
}
