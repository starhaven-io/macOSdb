import Foundation
import Testing

@testable import macOSdbCore

@Suite("Golden ordering vectors")
struct GoldenOrderingTests {
    struct Vector: Decodable {
        let lhs: String
        let rhs: String
        let expected: String
    }

    struct VectorFile: Decodable {
        let osVersions: [Vector]
        let componentVersions: [Vector]
        let builds: [Vector]
    }

    static func loadVectors() throws -> VectorFile {
        let url = try #require(
            Bundle.module.url(forResource: "ordering-vectors", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private func expectedDirection(_ expected: String) -> ChangeDirection {
        switch expected {
        case "lt": .upgraded
        case "gt": .downgraded
        default: .unchanged
        }
    }

    @Test("Version vectors match VersionComparer")
    func versionVectors() throws {
        let vectors = try Self.loadVectors()
        for vector in vectors.osVersions + vectors.componentVersions {
            let result = VersionComparer.compareVersionStrings(vector.lhs, vector.rhs)
            #expect(
                result == expectedDirection(vector.expected),
                "\(vector.lhs) vs \(vector.rhs): expected \(vector.expected), got \(result)"
            )
        }
    }

    @Test("Build vectors match BuildNumber ordering")
    func buildVectors() throws {
        let vectors = try Self.loadVectors()
        for vector in vectors.builds {
            let ascending = BuildNumber.less(vector.lhs, vector.rhs)
            let descending = BuildNumber.less(vector.rhs, vector.lhs)
            switch vector.expected {
            case "lt":
                #expect(ascending && !descending, "\(vector.lhs) should order before \(vector.rhs)")
            case "gt":
                #expect(!ascending && descending, "\(vector.lhs) should order after \(vector.rhs)")
            default:
                #expect(!ascending && !descending, "\(vector.lhs) should tie with \(vector.rhs)")
            }
        }
    }

    @Test("Version vectors drive release index ordering")
    func indexOrderingAgrees() throws {
        let vectors = try Self.loadVectors()
        for vector in vectors.osVersions {
            let lhs = ReleaseIndexEntry(
                osVersion: vector.lhs,
                buildNumber: "1A1",
                releaseName: "L",
                dataFile: "l.json"
            )
            let rhs = ReleaseIndexEntry(
                osVersion: vector.rhs,
                buildNumber: "1A1",
                releaseName: "R",
                dataFile: "r.json"
            )
            switch vector.expected {
            case "lt":
                #expect(ReleaseIndexEntry.versionAscending(lhs, rhs))
                #expect(!ReleaseIndexEntry.versionAscending(rhs, lhs))
            case "gt":
                #expect(!ReleaseIndexEntry.versionAscending(lhs, rhs))
                #expect(ReleaseIndexEntry.versionAscending(rhs, lhs))
            default:
                #expect(!ReleaseIndexEntry.versionAscending(lhs, rhs))
                #expect(!ReleaseIndexEntry.versionAscending(rhs, lhs))
            }
        }
    }
}
