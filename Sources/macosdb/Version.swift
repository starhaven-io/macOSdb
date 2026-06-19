/// macosdb version — source of truth for releases.
///
/// Bump this, commit as `chore: bump version to X.Y.Z`, then trigger the
/// Release workflow, which reads this value to create the matching git tag.
enum MacosdbVersion {
    static let current = "2.0.0"
}
