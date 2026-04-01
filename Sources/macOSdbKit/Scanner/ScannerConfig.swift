import Foundation

public struct ComponentDefinition: Sendable {
    public let name: String
    public let path: String
    /// Alternative path to try if `path` is not found (e.g. older toolchain layouts).
    public let fallbackPath: String?
    public let source: ComponentSource
    public let pattern: String
    public let normalize: @Sendable (String) -> String
    public let strategy: ExtractionStrategy
    /// Minimum printable-ASCII run length for binary string extraction (default: 4).
    public let minLength: Int?

    public init(
        name: String,
        path: String,
        fallbackPath: String? = nil,
        source: ComponentSource,
        pattern: String,
        normalize: @Sendable @escaping (String) -> String,
        strategy: ExtractionStrategy,
        minLength: Int? = nil
    ) {
        self.name = name
        self.path = path
        self.fallbackPath = fallbackPath
        self.source = source
        self.pattern = pattern
        self.normalize = normalize
        self.strategy = strategy
        self.minLength = minLength
    }
}

/// A component extracted from SDK text files (headers, .tbd files).
/// Paths are relative to the SDK `usr/` directory.
public struct SDKComponentDefinition: Sendable {
    public let name: String
    public let path: String
    public let pattern: String
    public let normalize: @Sendable (String) -> String
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
        name: "Ruby",
        path: "usr/bin/ruby",
        source: .filesystem,
        // Matches "2.6.10p210", "ruby 2.6.10", or bare "2.6.10"
        pattern: #"[0-9]+\.[0-9]+\.[0-9]+p[0-9]+|ruby [0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+"#,

        normalize: stripPrefix(["ruby "]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "sudo",
        path: "usr/bin/sudo",
        source: .filesystem,
        pattern: #"[0-9]+\.[0-9]+\.[0-9]+p[0-9]+"#,

        normalize: identity,
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
        // Matches standalone integer version constants like 20913, 21209.
        // Lookaround prevents matching substrings of larger numbers (e.g. 2147483647).
        pattern: #"(?<!\d)2[01][0-9]{3}(?!\d)"#,

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
        pattern: #"clang-[0-9]{3,}\.[0-9]+[0-9.]*"#,

        normalize: stripPrefix(["clang-"]),
        strategy: .regex
    ),
    ComponentDefinition(
        name: "Swift",
        path: "usr/bin/swift-frontend",
        fallbackPath: "usr/bin/swift",
        source: .filesystem,
        // Newer Xcodes: "swiftlang-6.3.0.123.5"; older: "Swift version 5.5.2"
        // swiftlang major < 100 = real version; >= 100 = Apple project number (e.g. 1300.0.47.5)
        pattern: #"swiftlang-[0-9]{1,2}\.[0-9]+[0-9.]*|Swift version [0-9]+\.[0-9]+(?:\.[0-9]+)?"#,

        normalize: { raw in
            if raw.hasPrefix("swiftlang-") {
                return String(raw.dropFirst("swiftlang-".count))
            }
            return String(raw.dropFirst("Swift version ".count))
        },
        strategy: .regex
    ),
    ComponentDefinition(
        name: "cctools",
        path: "usr/bin/otool",
        source: .filesystem,
        pattern: #"cctools-[0-9]+"#,

        normalize: stripPrefix(["cctools-"]),
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

// MARK: - SDK component definitions (Xcode)

/// Extracts a quoted string from a `#define NAME "version"` line.
private func extractDefine(_ defineName: String) -> (pattern: String, normalize: @Sendable (String) -> String) {
    let pattern = #"#\s*define\s+"# + defineName + #"\s+"[^"]+""#
    let normalize: @Sendable (String) -> String = { raw in
        guard let open = raw.firstIndex(of: "\""),
              let close = raw[raw.index(after: open)...].firstIndex(of: "\"") else { return raw }
        return String(raw[raw.index(after: open)..<close])
    }
    return (pattern, normalize)
}

/// Extracts `current-version:` from a .tbd file.
private let tbdCurrentVersion: (pattern: String, normalize: @Sendable (String) -> String) = {
    let pattern = #"current-version:\s*[0-9]+[0-9.]*"#
    let normalize: @Sendable (String) -> String = { raw in
        guard let range = raw.range(of: #"[0-9]+[0-9.]*"#, options: .regularExpression) else { return raw }
        return String(raw[range])
    }
    return (pattern, normalize)
}()

/// Components extracted from macOS SDK headers and .tbd files.
/// Paths are relative to the SDK `usr/` directory.
public let sdkComponents: [SDKComponentDefinition] = buildSDKComponents()

private func buildSDKComponents() -> [SDKComponentDefinition] {
    let tbd = tbdCurrentVersion
    let libcurl = extractDefine("LIBCURL_VERSION")
    let libexslt = extractDefine("LIBEXSLT_DOTTED_VERSION")
    let libxml2 = extractDefine("LIBXML_DOTTED_VERSION")
    let libxslt = extractDefine("LIBXSLT_DOTTED_VERSION")
    let sqlite3 = extractDefine("SQLITE_VERSION")
    let zlib = extractDefine("ZLIB_VERSION")

    return [
        SDKComponentDefinition(
            name: "bzip2", path: "lib/libbz2.1.0.tbd",
            pattern: tbd.pattern, normalize: tbd.normalize
        ),
        SDKComponentDefinition(
            name: "expat", path: "include/expat.h",
            pattern: "XML_MAJOR_VERSION|XML_MINOR_VERSION|XML_MICRO_VERSION",
            normalize: identity
        ),
        SDKComponentDefinition(
            name: "libcurl", path: "include/curl/curlver.h",
            pattern: libcurl.pattern, normalize: libcurl.normalize
        ),
        SDKComponentDefinition(
            name: "libexslt", path: "include/libexslt/exsltconfig.h",
            pattern: libexslt.pattern, normalize: libexslt.normalize
        ),
        SDKComponentDefinition(
            name: "libffi", path: "include/ffi/ffi.h",
            pattern: #"libffi\s+[0-9]+\.[0-9]+[A-Za-z0-9.-]*"#,
            normalize: stripPrefix(["libffi "])
        ),
        SDKComponentDefinition(
            name: "libxml2", path: "include/libxml/xmlversion.h",
            pattern: libxml2.pattern, normalize: libxml2.normalize
        ),
        SDKComponentDefinition(
            name: "libxslt", path: "include/libxslt/xsltconfig.h",
            pattern: libxslt.pattern, normalize: libxslt.normalize
        ),
        SDKComponentDefinition(
            name: "ncurses", path: "include/curses.h",
            pattern: "NCURSES_VERSION_MAJOR|NCURSES_VERSION_MINOR|NCURSES_VERSION_PATCH",
            normalize: identity
        ),
        SDKComponentDefinition(
            name: "sqlite3", path: "include/sqlite3.h",
            pattern: sqlite3.pattern, normalize: sqlite3.normalize
        ),
        SDKComponentDefinition(
            name: "zlib", path: "include/zlib.h",
            pattern: zlib.pattern, normalize: zlib.normalize
        )
    ]
}
