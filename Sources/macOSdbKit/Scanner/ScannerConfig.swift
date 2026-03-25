import Foundation

public struct ComponentDefinition: Sendable {
    public let name: String
    public let path: String
    public let source: ComponentSource
    public let pattern: String
    public let normalize: @Sendable (String) -> String
    public let strategy: ExtractionStrategy
}

public enum ExtractionStrategy: Sendable, Equatable {
    case regex
    /// Decode as MAJOR*10000 + MINOR*100 + PATCH (used for libxml2).
    case integerDecode
}

// MARK: - Normalization helpers

private func stripPrefix(_ prefixes: [String]) -> @Sendable (String) -> String {
    { raw in
        var result = raw
        for prefix in prefixes where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            break
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

private let identity: @Sendable (String) -> String = { $0 }

/// Strips " (Apple Git-NNN)" or " (Apple Git-NNN.N)" suffix to extract the upstream Git version.
private func stripAppleGitSuffix() -> @Sendable (String) -> String {
    { raw in
        if let range = raw.range(of: #" \(Apple Git-[0-9]+[0-9.]*\)"#, options: .regularExpression) {
            return String(raw[raw.startIndex..<range.lowerBound])
        }
        return raw
    }
}

// MARK: - Filesystem component definitions

public let filesystemComponents: [ComponentDefinition] = [
    ComponentDefinition(
        name: "httpd",
        path: "usr/sbin/httpd",
        source: .filesystem,
        pattern: #"Apache/[0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["Apache/"]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "curl",
        path: "usr/bin/curl",
        source: .filesystem,
        pattern: #"curl [0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["curl "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "LibreSSL",
        path: "usr/bin/openssl",
        source: .filesystem,
        pattern: #"LibreSSL [0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["LibreSSL "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "OpenSSH",
        path: "usr/bin/ssh",
        source: .filesystem,
        pattern: #"OpenSSH_[0-9]+\.[0-9]+p[0-9]+"#,

        normalize: stripPrefix(["OpenSSH_"]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "rsync",
        path: "usr/bin/rsync",
        source: .filesystem,
        pattern: #"rsync  *version [0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: { raw in
            // "rsync  version 2.6.9" -> "2.6.9"
            guard let range = raw.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else {
                return raw
            }
            return String(raw[range])
        },
        strategy: .regex
    ),
    ComponentDefinition(
        name: "Ruby",
        path: "usr/bin/ruby",
        source: .filesystem,
        // Matches "2.6.10p210", "ruby 2.6.10", or bare "2.6.10"
        pattern: #"[0-9]+\.[0-9]+\.[0-9]+p[0-9]+|ruby [0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["ruby "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "SQLite",
        path: "usr/bin/sqlite3",
        source: .filesystem,
        pattern: #"3\.[0-9]+\.[0-9]+"#,

        normalize: identity,
        strategy: .regex
    ),
    ComponentDefinition(
        name: "vim",
        path: "usr/bin/vim",
        source: .filesystem,
        pattern: #"VIM - Vi IMproved [0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["VIM - Vi IMproved "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "zip",
        path: "usr/bin/zip",
        source: .filesystem,
        pattern: #"Zip [0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["Zip "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "zsh",
        path: "bin/zsh",
        source: .filesystem,
        // zsh embeds a git-tag-style string "zsh-5.9-0-g73d3173"; extract the version portion
        pattern: #"zsh-[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["zsh-"]),
        strategy: .regex
    )
]

// MARK: - dyld shared cache component definitions

public let dyldCacheComponents: [ComponentDefinition] = [
    ComponentDefinition(
        name: "libbz2 (bzip2)",
        path: "/usr/lib/libbz2.1.0.dylib",
        source: .dyldCache,
        pattern: #"1\.[0-9]+\.[0-9]+"#,

        normalize: identity,
        strategy: .regex
    ),
    ComponentDefinition(
        name: "libcurl",
        path: "/usr/lib/libcurl.4.dylib",
        source: .dyldCache,
        pattern: #"libcurl [0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["libcurl "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "libexpat",
        path: "/usr/lib/libexpat.1.dylib",
        source: .dyldCache,
        // Only match upstream "expat_X.Y.Z"; bare X.Y.Z matches Apple internal versions
        pattern: #"expat_[0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["expat_"]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "libncurses",
        path: "/usr/lib/libncurses.5.4.dylib",
        source: .dyldCache,
        // Upstream embeds "ncurses X.Y.YYYYMMDD"; bare 6.X.Y matches Apple internal versions
        pattern: #"ncurses [0-9]+\.[0-9]+(?:\.[0-9]+)?"#,

        normalize: stripPrefix(["ncurses "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "libpcap",
        path: "/usr/lib/libpcap.A.dylib",
        source: .dyldCache,
        // Upstream embeds "libpcap version X.Y.Z"; bare X.Y.Z matches Apple internal versions
        pattern: #"libpcap version [0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["libpcap version "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "libsqlite3",
        path: "/usr/lib/libsqlite3.dylib",
        source: .dyldCache,
        pattern: #"3\.[0-9]+\.[0-9]+"#,

        normalize: identity,
        strategy: .regex
    ),
    ComponentDefinition(
        name: "libssl (LibreSSL)",
        path: "/usr/lib/libssl.35.dylib",
        source: .dyldCache,
        pattern: #"LibreSSL [0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["LibreSSL "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "libxml2",
        path: "/usr/lib/libxml2.2.dylib",
        source: .dyldCache,
        // Matches integer version constants like 20913, 21209
        pattern: #"2[01][0-9]{3}"#,

        normalize: identity,
        strategy: .integerDecode
    )
]

// MARK: - Toolchain component definitions (Xcode)

/// Components found in the Xcode toolchain.
/// Paths are relative to the toolchain root (e.g. `XcodeDefault.xctoolchain/`).
public let toolchainComponents: [ComponentDefinition] = [
    ComponentDefinition(
        name: "Apple Clang",
        path: "usr/bin/clang",
        source: .filesystem,
        // All versions embed "LLVM X.Y.Z" (e.g. "LLVM 13.0.0", "LLVM 21.0.0")
        pattern: #"LLVM [0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["LLVM "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "Swift",
        // swift is a driver; swift-frontend has the actual version string
        path: "usr/bin/swift-frontend",
        source: .filesystem,
        // Embeds "Swift version X.Y[.Z]" (e.g. "Swift version 6.3", "Swift version 5.5.2")
        pattern: #"Swift version [0-9]+\.[0-9]+(?:\.[0-9]+)?"#,

        normalize: stripPrefix(["Swift version "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "ld",
        path: "usr/bin/ld",
        source: .filesystem,
        // Older: "PROJECT:ld64-711", newer: "PROJECT:ld-1230.1", transitional: "PROJECT:dyld-1022.1"
        pattern: #"PROJECT:(?:dyld|ld64|ld)-[0-9]+[0-9.]*"#,

        normalize: stripPrefix(["PROJECT:dyld-", "PROJECT:ld64-", "PROJECT:ld-"]),
        strategy: .regex
    )
]

/// Components found in the Xcode Developer directory.
/// Paths are relative to the Developer root.
public let developerComponents: [ComponentDefinition] = [
    ComponentDefinition(
        name: "Git",
        path: "usr/bin/git",
        source: .filesystem,
        // Embeds "X.Y.Z (Apple Git-NNN)" or "X.Y.Z (Apple Git-NNN.N)" — extract upstream version
        pattern: #"[0-9]+\.[0-9]+\.[0-9]+ \(Apple Git-[0-9]+[0-9.]*\)"#,

        normalize: stripAppleGitSuffix(),
        strategy: .regex
    )
]

// MARK: - Framework component definitions (Xcode)

/// Components found in frameworks bundled with Xcode.
/// Paths are relative to Xcode.app.
public let frameworkComponents: [ComponentDefinition] = [
    ComponentDefinition(
        name: "lldb",
        // Xcode: Contents/SharedFrameworks/LLDB.framework/LLDB
        path: "Contents/SharedFrameworks/LLDB.framework/LLDB",
        source: .filesystem,
        // Embeds "lldb-2100.0.16.4" style version strings
        pattern: #"lldb-[0-9]+\.[0-9]+[0-9.]*"#,

        normalize: stripPrefix(["lldb-"]),
        strategy: .regex
    )
]
