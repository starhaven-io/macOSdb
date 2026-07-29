import Foundation

/// Writes a small local data store for CLI subprocess tests.
enum LocalDataStore {
    static func make() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macosdb-cli-data-\(UUID().uuidString)", isDirectory: true)
        let macosDir = root.appendingPathComponent("macos", isDirectory: true)
        let releases14 = macosDir.appendingPathComponent("releases/14", isDirectory: true)
        let releases15 = macosDir.appendingPathComponent("releases/15", isDirectory: true)
        try FileManager.default.createDirectory(at: releases14, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: releases15, withIntermediateDirectories: true)

        try writeIndex(to: macosDir)
        try writeReleases(releases14: releases14, releases15: releases15)
        return root
    }

    private static func writeIndex(to macosDir: URL) throws {
        try writeJSONObject([
            indexEntry(
                version: "14.0",
                build: "23A344",
                releaseName: "Sonoma",
                dataFile: "releases/14/macOS-14.0-23A344.json"
            ),
            indexEntry(
                version: "15.0",
                build: "24A335",
                releaseName: "Sequoia",
                dataFile: "releases/15/macOS-15.0-24A335.json"
            ),
            indexEntry(
                version: "15.1",
                build: "24B2083",
                releaseName: "Sequoia",
                dataFile: "releases/15/macOS-15.1-24B2083.json",
                isDeviceSpecific: true
            ),
            indexEntry(
                version: "15.1",
                build: "24B83",
                releaseName: "Sequoia",
                dataFile: "releases/15/macOS-15.1-24B83.json"
            )
        ], to: macosDir.appendingPathComponent("releases.json"))
    }

    private static func writeReleases(releases14: URL, releases15: URL) throws {
        try writeJSONObject(
            release(
                version: "14.0",
                build: "23A344",
                releaseName: "Sonoma",
                components: [
                    component(name: "curl", version: "8.7.1", path: "/usr/bin/curl"),
                    component(name: "httpd", version: "2.4.59", path: "/usr/sbin/httpd"),
                    component(name: "libbz2 (bzip2)", version: "1.0.8", path: "/usr/lib/libbz2.dylib"),
                    component(name: "libbz2-extra", version: "1.0.8", path: "/usr/lib/libbz2-extra.dylib")
                ]
            ),
            to: releases14.appendingPathComponent("macOS-14.0-23A344.json")
        )
        try writeJSONObject(
            release(
                version: "15.0",
                build: "24A335",
                releaseName: "Sequoia",
                components: [
                    component(name: "curl", version: "8.7.1", path: "/usr/bin/curl"),
                    component(name: "httpd", version: "2.4.62", path: "/usr/sbin/httpd"),
                    component(name: "libbz2 (bzip2)", version: "1.0.8", path: "/usr/lib/libbz2.dylib"),
                    component(name: "libbz2-extra", version: "1.0.8", path: "/usr/lib/libbz2-extra.dylib"),
                    component(name: "newtool", version: "1.0", path: "/usr/bin/newtool")
                ]
            ),
            to: releases15.appendingPathComponent("macOS-15.0-24A335.json")
        )
        try writeJSONObject(
            release(
                version: "15.1",
                build: "24B83",
                releaseName: "Sequoia",
                components: [
                    component(name: "curl", version: "8.7.1", path: "/usr/bin/curl")
                ]
            ),
            to: releases15.appendingPathComponent("macOS-15.1-24B83.json")
        )
        try writeJSONObject(
            release(
                version: "15.1",
                build: "24B2083",
                releaseName: "Sequoia",
                components: [
                    component(name: "curl", version: "8.7.1", path: "/usr/bin/curl")
                ],
                isDeviceSpecific: true
            ),
            to: releases15.appendingPathComponent("macOS-15.1-24B2083.json")
        )
    }

    private static func indexEntry(
        version: String,
        build: String,
        releaseName: String,
        dataFile: String,
        isDeviceSpecific: Bool = false
    ) -> [String: Any] {
        [
            "osVersion": version,
            "buildNumber": build,
            "releaseName": releaseName,
            "releaseDate": "2025-01-01",
            "isBeta": false,
            "isRC": false,
            "isDeviceSpecific": isDeviceSpecific,
            "dataFile": dataFile
        ]
    }

    private static func release(
        version: String,
        build: String,
        releaseName: String,
        components: [[String: Any]],
        isDeviceSpecific: Bool = false
    ) -> [String: Any] {
        [
            "osVersion": version,
            "buildNumber": build,
            "releaseName": releaseName,
            "releaseDate": "2025-01-01",
            "isBeta": false,
            "isRC": false,
            "isDeviceSpecific": isDeviceSpecific,
            "kernels": [],
            "components": components
        ]
    }

    private static func component(name: String, version: String, path: String) -> [String: Any] {
        [
            "name": name,
            "version": version,
            "path": path,
            "source": "filesystem"
        ]
    }

    private static func writeJSONObject(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
