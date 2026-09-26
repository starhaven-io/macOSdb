import Foundation
import Testing

@testable import macOSdbCore

@Suite("DMG mounter tests")
struct DMGMounterTests {

    @Test("Parses the mounted entity from hdiutil plist output")
    func parsesMountedEntity() async throws {
        let data = try plistData([
            "system-entities": [
                ["dev-entry": "/dev/disk4"],
                ["dev-entry": "/dev/disk4s1", "mount-point": "/Volumes/System"]
            ]
        ])

        let mount = try await DMGMounter().parseMountOutput(data, dmgPath: "/tmp/System.dmg")

        #expect(mount.path == "/Volumes/System")
        #expect(mount.deviceNode == "/dev/disk4s1")
    }

    @Test("Falls back to the image device for an entity without a device node")
    func fallsBackToImageDevice() async throws {
        let data = try plistData([
            "system-entities": [
                ["dev-entry": "/dev/disk5"],
                ["mount-point": "/Volumes/Cryptex"]
            ]
        ])

        let mount = try await DMGMounter().parseMountOutput(data, dmgPath: "/tmp/Cryptex.dmg")

        #expect(mount.path == "/Volumes/Cryptex")
        #expect(mount.deviceNode == "/dev/disk5")
    }

    @Test("Rejects malformed and mountless hdiutil output")
    func rejectsInvalidOutput() async throws {
        let invalidOutputs = [
            Data("not a plist".utf8),
            try plistData(["unexpected": true]),
            try plistData(["system-entities": [["dev-entry": "/dev/disk6"]]])
        ]

        for data in invalidOutputs {
            do {
                _ = try await DMGMounter().parseMountOutput(data, dmgPath: "/tmp/Invalid.dmg")
                Issue.record("Expected invalid hdiutil output to fail")
            } catch ScannerError.dmgMountFailed(let path, _) {
                #expect(path == "/tmp/Invalid.dmg")
            } catch {
                Issue.record("Expected a DMG mount failure, got \(error)")
            }
        }
    }

    @Test("A scan cancelled during attach detaches the image the attach mounted")
    func cancelledAttachIsDetached() async throws {
        let calls = HdiutilCalls()
        let attached = try plistData([
            "system-entities": [
                ["dev-entry": "/dev/disk4"],
                ["dev-entry": "/dev/disk4s1", "mount-point": "/Volumes/System"]
            ]
        ])
        let mounter = DMGMounter { arguments, _ in
            await calls.record(arguments)
            if arguments.first == "attach" {
                withUnsafeCurrentTask { $0?.cancel() }
                return ProcessRunResult(terminationStatus: 0, stdout: attached, stderr: Data())
            }
            return ProcessRunResult(terminationStatus: 0, stdout: Data(), stderr: Data())
        }

        let mount = Task { try await mounter.mount(dmgPath: URL(fileURLWithPath: "/tmp/System.dmg")) }
        await #expect(throws: CancellationError.self) { try await mount.value }
        #expect(await calls.commands == ["attach", "detach /dev/disk4s1"])
        #expect(await mounter.unreleasedImages.isEmpty)
    }

    enum FailedAttach: CaseIterable { case timedOut, failedExit, unparsedOutput }

    @Test("A failed attach detaches any image attached from the same backing file", arguments: FailedAttach.allCases)
    func failedAttachDetachesBackingImage(_ failure: FailedAttach) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macosdb-dmg-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dmg = directory.appendingPathComponent("System.dmg")
        let other = directory.appendingPathComponent("Other.dmg")
        try Data("dmg".utf8).write(to: dmg)
        try Data("other".utf8).write(to: other)
        let info = try plistData(["images": [
            ["image-path": other.path, "system-entities": [["dev-entry": "/dev/disk9"]]],
            ["image-path": dmg.path, "system-entities": [["dev-entry": "/dev/disk6s1"], ["dev-entry": "/dev/disk6"]]]
        ]])
        let unmounted = try plistData(["system-entities": [["dev-entry": "/dev/disk6"]]])
        let calls = HdiutilCalls()
        let mounter = DMGMounter { arguments, _ in
            await calls.record(arguments)
            switch (arguments.first, failure) {
            case ("attach", .timedOut): throw ScannerError.processTimedOut(tool: "hdiutil", seconds: 300)
            case ("attach", .failedExit): return ProcessRunResult(terminationStatus: 1, stdout: Data(), stderr: Data())
            case ("attach", .unparsedOutput): return ProcessRunResult(terminationStatus: 0, stdout: unmounted, stderr: Data())
            case ("info", _): return ProcessRunResult(terminationStatus: 0, stdout: info, stderr: Data())
            default: return ProcessRunResult(terminationStatus: 0, stdout: Data(), stderr: Data())
            }
        }

        await #expect(throws: ScannerError.self) { try await mounter.mount(dmgPath: dmg) }
        #expect(await calls.commands == ["attach", "info", "detach /dev/disk6"])
        #expect(await mounter.unreleasedImages.isEmpty)
    }

    @Test("Images that may still be attached are reported as unreleased")
    func reportsUnreleasedImages() async throws {
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("macosdb-dmg-\(UUID().uuidString).dmg")
        try Data("dmg".utf8).write(to: dmg)
        defer { try? FileManager.default.removeItem(at: dmg) }
        let mounter = DMGMounter { arguments, _ in
            if arguments.first == "attach" { throw ScannerError.processTimedOut(tool: "hdiutil", seconds: 300) }
            return ProcessRunResult(terminationStatus: 1, stdout: Data(), stderr: Data())
        }

        await #expect(throws: ScannerError.self) { try await mounter.mount(dmgPath: dmg) }
        await mounter.unmount(DMGMounter.MountPoint(path: "/Volumes/System", deviceNode: "/dev/disk4s1"))
        #expect(await mounter.unreleasedImages == [dmg.path, "/dev/disk4s1"])
    }

    @Test("An unreadable backing file preserves the workspace after a failed attach")
    func missingBackingFileIsUnreleased() async throws {
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("macosdb-missing-\(UUID().uuidString).dmg")
        let mounter = DMGMounter { _, _ in
            throw ScannerError.processTimedOut(tool: "hdiutil", seconds: 300)
        }

        await #expect(throws: ScannerError.self) { try await mounter.mount(dmgPath: dmg) }
        #expect(await mounter.unreleasedImages == [dmg.path])
    }

    @Test("An attached image without device identity preserves its workspace")
    func missingDeviceIdentityIsUnreleased() async throws {
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("macosdb-dmg-\(UUID().uuidString).dmg")
        try Data("dmg".utf8).write(to: dmg)
        defer { try? FileManager.default.removeItem(at: dmg) }
        let info = try plistData(["images": [["image-path": dmg.path, "system-entities": []]]])
        let calls = HdiutilCalls()
        let mounter = DMGMounter { arguments, _ in
            await calls.record(arguments)
            if arguments.first == "attach" { throw ScannerError.processTimedOut(tool: "hdiutil", seconds: 300) }
            return ProcessRunResult(terminationStatus: 0, stdout: info, stderr: Data())
        }

        await #expect(throws: ScannerError.self) { try await mounter.mount(dmgPath: dmg) }
        #expect(await calls.commands == ["attach", "info"])
        #expect(await mounter.unreleasedImages == [dmg.path])
    }

    private actor HdiutilCalls {
        private(set) var commands: [String] = []

        func record(_ arguments: [String]) {
            commands.append(arguments.first == "detach" ? "detach \(arguments[1])" : arguments[0])
        }
    }

    private func plistData(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
    }
}
