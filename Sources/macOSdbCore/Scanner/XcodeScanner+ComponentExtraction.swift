import Foundation

extension XcodeScanner {
    func extractFrameworkComponents(from xcodeApp: URL) async -> [Component] {
        var components: [Component] = []

        // lldb's version is in LLDB.framework, not the lldb executable.
        for definition in frameworkComponents {
            guard !Task.isCancelled else { break }
            let binaryPath = xcodeApp.appendingPathComponent(definition.path)
            let data: Data
            do {
                data = try ScannerFileReader.data(at: binaryPath, confinedTo: xcodeApp)
            } catch {
                sendVerbose("\(definition.name): could not read binary (\(error.localizedDescription))")
                continue
            }

            if let component = await ComponentExtractor.extract(from: data, using: definition) {
                components.append(component)
            } else {
                sendVerbose("\(definition.name): no version matched (\(data.count) bytes)")
            }
        }

        let pythonFramework = xcodeApp.appendingPathComponent(
            "Contents/Developer/Library/Frameworks/Python3.framework/Versions"
        )
        if let pythonComponent = await extractPythonVersion(from: pythonFramework, confinedTo: xcodeApp) {
            components.append(pythonComponent)
        }

        return components
    }

    private func extractPythonVersion(from versionsDir: URL, confinedTo root: URL) async -> Component? {
        let fileManager = FileManager.default
        guard let safeVersionsDir = try? ScannerFileReader.resolvedDirectory(
            at: versionsDir,
            confinedTo: root
        ) else {
            sendVerbose("Python: framework not found at \(versionsDir.path)")
            return nil
        }
        guard let versions = try? fileManager.contentsOfDirectory(
            at: safeVersionsDir, includingPropertiesForKeys: nil
        ) else {
            sendVerbose("Python: framework not found at \(versionsDir.path)")
            return nil
        }

        for versionDir in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard !Task.isCancelled else { return nil }
            guard let safeVersionDir = try? ScannerFileReader.resolvedDirectory(
                at: versionDir,
                confinedTo: root
            ),
                let libDir = try? ScannerFileReader.resolvedDirectory(
                    at: safeVersionDir.appendingPathComponent("lib"),
                    confinedTo: root
                ) else { continue }
            guard let libs = try? fileManager.contentsOfDirectory(
                at: libDir, includingPropertiesForKeys: nil
            ) else { continue }

            if let dylib = libs.first(where: {
                $0.lastPathComponent.hasPrefix("libpython3") && $0.pathExtension == "dylib"
            }) {
                guard let data = try? ScannerFileReader.data(at: dylib, confinedTo: root) else { continue }

                let relativePath = "Library/Frameworks/Python3.framework/Versions/"
                    + "\(versionDir.lastPathComponent)/lib/\(dylib.lastPathComponent)"
                let definition = ComponentDefinition(
                    name: "Python",
                    path: relativePath,
                    source: .filesystem,
                    // Match a standalone 3.x.y string to avoid unrelated embedded versions.
                    pattern: #"^3\.(?:[2-9]|[1-9][0-9]+)\.[0-9]+$"#,
                    normalize: { $0 },
                    strategy: .regex
                )

                if let component = await ComponentExtractor.extract(from: data, using: definition) {
                    return component
                }
            }
        }

        sendVerbose("Python: no libpython dylib found")
        return nil
    }

    func parseSDKMetadata(from xcodeApp: URL) -> [SDKInfo] {
        let sdksDir = xcodeApp.appendingPathComponent(
            "Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs"
        )
        guard let safeSDKsDir = try? ScannerFileReader.resolvedDirectory(
            at: sdksDir,
            confinedTo: xcodeApp
        ) else { return [] }
        return SDKMetadataParser.findMacOSSDKs(in: safeSDKsDir, confinedTo: xcodeApp)
    }

    func extractSDKComponents(from xcodeApp: URL) -> [Component] {
        let sdkUsrDir = xcodeApp.appendingPathComponent(
            "Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr"
        )
        guard let safeSDKUsrDir = try? ScannerFileReader.resolvedDirectory(
            at: sdkUsrDir,
            confinedTo: xcodeApp
        ) else {
            sendVerbose("SDK usr/ directory not found")
            return []
        }
        return SDKMetadataParser.extractSDKComponents(from: safeSDKUsrDir, confinedTo: xcodeApp)
    }
}
