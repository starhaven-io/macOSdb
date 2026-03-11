import Foundation

/// Bump when scanner logic changes in a way that would produce different output from the same IPSW.
public let scannerVersion = "1.0.0"

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
