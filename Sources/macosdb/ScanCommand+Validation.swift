import ArgumentParser
import Foundation
import macOSdbCore

extension ScanCommand {
    func validate() throws {
        let archiveExtension = URL(fileURLWithPath: archivePath).pathExtension.lowercased()
        guard ["ipsw", "xip", "aea"].contains(archiveExtension) else {
            throw ValidationError("Archive must have an .ipsw, .xip, or .aea extension")
        }
        if updateIndex && releaseDate == nil {
            throw ValidationError("--release-date is required when using --update-index")
        }
        if let releaseDate, !Self.isValidDate(releaseDate) {
            throw ValidationError("--release-date must be a valid ISO 8601 date (YYYY-MM-DD), got '\(releaseDate)'")
        }
        if beta || betaNumber != nil || betaRevision != nil, rc || rcNumber != nil {
            throw ValidationError("Beta and release-candidate options are mutually exclusive")
        }
        if let betaNumber, betaNumber < 1 {
            throw ValidationError("--beta-number must be greater than zero")
        }
        if let rcNumber, rcNumber < 1 {
            throw ValidationError("--rc-number must be greater than zero")
        }
        if betaRevision != nil, betaNumber == nil {
            throw ValidationError("--beta-revision requires --beta-number")
        }
        if let betaRevision, betaRevision < 2 {
            throw ValidationError("--beta-revision must be 2 or greater")
        }
        if keyOnly && updateIndex {
            throw ValidationError("--key-only cannot be combined with --update-index")
        }
        if archiveExtension != "ipsw", deviceSpecific || saveAeaKey || aeaKeyPath != nil || keyOnly {
            throw ValidationError("AEA key and device-specific options are available only for IPSW archives")
        }
        if archiveExtension != "ipsw", let downloadURL, !Self.url(downloadURL, namesArchiveWithExtension: archiveExtension) {
            throw ValidationError("The download URL must name an .\(archiveExtension) archive, the format being scanned")
        }
    }

    /// An Xcode release records the source pair of the archive that was scanned,
    /// so a URL naming the other format would publish a mislabeled source.
    private static func url(_ url: String, namesArchiveWithExtension pathExtension: String) -> Bool {
        guard let filename = XcodeScanner.archiveFilename(fromURLString: url) else { return false }
        return URL(fileURLWithPath: filename).pathExtension.lowercased() == pathExtension
    }

    private static func isValidDate(_ value: String) -> Bool {
        guard value.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let date = components.date else { return false }
        let resolved = components.calendar?.dateComponents([.year, .month, .day], from: date)
        return resolved?.year == parts[0] && resolved?.month == parts[1] && resolved?.day == parts[2]
    }
}
