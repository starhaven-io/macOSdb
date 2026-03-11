import Foundation

/// Resolves per-device chip families (Apple bundles multiple chip tiers into a
/// single kernelcache) and filters device lists by introduction date.
public enum DeviceRegistry {

    public struct DeviceInfo: Sendable {
        public let model: String
        public let chip: ChipFamily
        public let marketingName: String
        /// "YYYY-MM" format for lexicographic comparison.
        public let introduced: String
    }

    public static func chip(for model: String) -> ChipFamily? {
        allDevices[model]?.chip
    }

    public static func info(for model: String) -> DeviceInfo? {
        allDevices[model]
    }

    public static func filterByIntroductionDate(
        _ devices: [String],
        onOrBefore cutoff: String
    ) -> [String] {
        devices.filter { model in
            guard let info = allDevices[model] else { return true }
            return info.introduced <= cutoff
        }
    }

    // MARK: - Device database

    /// Sources: EveryMac, Apple Support (HT201862), The Apple Wiki.
    public static let allDevices: [String: DeviceInfo] = { // swiftlint:disable:this closure_body_length
        let entries: [DeviceInfo] = [
            // MARK: M1 (Late 2020 – Mid 2021)
            DeviceInfo(model: "MacBookAir10,1", chip: .m1,
                       marketingName: "MacBook Air (M1, Late 2020)", introduced: "2020-11"),
            DeviceInfo(model: "MacBookPro17,1", chip: .m1,
                       marketingName: "MacBook Pro (13-inch, M1, Late 2020)", introduced: "2020-11"),
            DeviceInfo(model: "Macmini9,1", chip: .m1,
                       marketingName: "Mac mini (M1, Late 2020)", introduced: "2020-11"),
            DeviceInfo(model: "iMac21,1", chip: .m1,
                       marketingName: "iMac (24-inch, M1, 2021) 2-port", introduced: "2021-05"),
            DeviceInfo(model: "iMac21,2", chip: .m1,
                       marketingName: "iMac (24-inch, M1, 2021) 4-port", introduced: "2021-05"),

            // MARK: M1 Pro (Late 2021)
            DeviceInfo(model: "MacBookPro18,1", chip: .m1Pro,
                       marketingName: "MacBook Pro (16-inch, M1 Pro, Late 2021)", introduced: "2021-10"),
            DeviceInfo(model: "MacBookPro18,3", chip: .m1Pro,
                       marketingName: "MacBook Pro (14-inch, M1 Pro, Late 2021)", introduced: "2021-10"),

            // MARK: M1 Max (Late 2021 – 2022)
            DeviceInfo(model: "MacBookPro18,2", chip: .m1Max,
                       marketingName: "MacBook Pro (16-inch, M1 Max, Late 2021)", introduced: "2021-10"),
            DeviceInfo(model: "MacBookPro18,4", chip: .m1Max,
                       marketingName: "MacBook Pro (14-inch, M1 Max, Late 2021)", introduced: "2021-10"),
            DeviceInfo(model: "Mac13,1", chip: .m1Max,
                       marketingName: "Mac Studio (M1 Max, 2022)", introduced: "2022-03"),

            // MARK: M1 Ultra (2022)
            DeviceInfo(model: "Mac13,2", chip: .m1Ultra,
                       marketingName: "Mac Studio (M1 Ultra, 2022)", introduced: "2022-03"),

            // MARK: M2 (2022–2023)
            DeviceInfo(model: "Mac14,2", chip: .m2,
                       marketingName: "MacBook Air (13-inch, M2, 2022)", introduced: "2022-06"),
            DeviceInfo(model: "Mac14,7", chip: .m2,
                       marketingName: "MacBook Pro (13-inch, M2, 2022)", introduced: "2022-06"),
            DeviceInfo(model: "Mac14,3", chip: .m2,
                       marketingName: "Mac mini (M2, 2023)", introduced: "2023-01"),
            DeviceInfo(model: "Mac14,15", chip: .m2,
                       marketingName: "MacBook Air (15-inch, M2, 2023)", introduced: "2023-06"),

            // MARK: M2 Pro (2023)
            DeviceInfo(model: "Mac14,9", chip: .m2Pro,
                       marketingName: "MacBook Pro (14-inch, M2 Pro, 2023)", introduced: "2023-01"),
            DeviceInfo(model: "Mac14,10", chip: .m2Pro,
                       marketingName: "MacBook Pro (16-inch, M2 Pro, 2023)", introduced: "2023-01"),
            DeviceInfo(model: "Mac14,12", chip: .m2Pro,
                       marketingName: "Mac mini (M2 Pro, 2023)", introduced: "2023-01"),

            // MARK: M2 Max (2023)
            DeviceInfo(model: "Mac14,5", chip: .m2Max,
                       marketingName: "MacBook Pro (14-inch, M2 Max, 2023)", introduced: "2023-01"),
            DeviceInfo(model: "Mac14,6", chip: .m2Max,
                       marketingName: "MacBook Pro (16-inch, M2 Max, 2023)", introduced: "2023-01"),
            DeviceInfo(model: "Mac14,13", chip: .m2Max,
                       marketingName: "Mac Studio (M2 Max, 2023)", introduced: "2023-06"),

            // MARK: M2 Ultra (2023)
            DeviceInfo(model: "Mac14,14", chip: .m2Ultra,
                       marketingName: "Mac Studio (M2 Ultra, 2023)", introduced: "2023-06"),
            DeviceInfo(model: "Mac14,8", chip: .m2Ultra,
                       marketingName: "Mac Pro (M2 Ultra, 2023)", introduced: "2023-06"),

            // MARK: M3 (Late 2023 – 2024)
            DeviceInfo(model: "Mac15,3", chip: .m3,
                       marketingName: "MacBook Pro (14-inch, M3, Late 2023)", introduced: "2023-11"),
            DeviceInfo(model: "Mac15,4", chip: .m3,
                       marketingName: "iMac (24-inch, M3, 2023) 2-port", introduced: "2023-11"),
            DeviceInfo(model: "Mac15,5", chip: .m3,
                       marketingName: "iMac (24-inch, M3, 2023) 4-port", introduced: "2023-11"),
            DeviceInfo(model: "Mac15,12", chip: .m3,
                       marketingName: "MacBook Air (13-inch, M3, 2024)", introduced: "2024-03"),
            DeviceInfo(model: "Mac15,13", chip: .m3,
                       marketingName: "MacBook Air (15-inch, M3, 2024)", introduced: "2024-03"),

            // MARK: M3 Pro (Late 2023)
            DeviceInfo(model: "Mac15,6", chip: .m3Pro,
                       marketingName: "MacBook Pro (14-inch, M3 Pro, Late 2023)", introduced: "2023-11"),
            DeviceInfo(model: "Mac15,7", chip: .m3Pro,
                       marketingName: "MacBook Pro (16-inch, M3 Pro, Late 2023)", introduced: "2023-11"),

            // MARK: M3 Max (Late 2023)
            DeviceInfo(model: "Mac15,8", chip: .m3Max,
                       marketingName: "MacBook Pro (14-inch, M3 Max, Late 2023)", introduced: "2023-11"),
            DeviceInfo(model: "Mac15,9", chip: .m3Max,
                       marketingName: "MacBook Pro (16-inch, M3 Max, Late 2023)", introduced: "2023-11"),
            DeviceInfo(model: "Mac15,10", chip: .m3Max,
                       marketingName: "MacBook Pro (14-inch, M3 Max, Late 2023)", introduced: "2023-11"),
            DeviceInfo(model: "Mac15,11", chip: .m3Max,
                       marketingName: "MacBook Pro (16-inch, M3 Max, Late 2023)", introduced: "2023-11"),

            // MARK: M3 Ultra (2025)
            DeviceInfo(model: "Mac15,14", chip: .m3Ultra,
                       marketingName: "Mac Studio (M3 Ultra, 2025)", introduced: "2025-03"),

            // MARK: M4 (Late 2024 – 2025)
            DeviceInfo(model: "Mac16,1", chip: .m4,
                       marketingName: "MacBook Pro (14-inch, M4, Late 2024)", introduced: "2024-11"),
            DeviceInfo(model: "Mac16,2", chip: .m4,
                       marketingName: "iMac (24-inch, M4, 2024) 2-port", introduced: "2024-11"),
            DeviceInfo(model: "Mac16,3", chip: .m4,
                       marketingName: "iMac (24-inch, M4, 2024) 4-port", introduced: "2024-11"),
            DeviceInfo(model: "Mac16,10", chip: .m4,
                       marketingName: "Mac mini (M4, 2024)", introduced: "2024-11"),
            DeviceInfo(model: "Mac16,12", chip: .m4,
                       marketingName: "MacBook Air (13-inch, M4, 2025)", introduced: "2025-03"),
            DeviceInfo(model: "Mac16,13", chip: .m4,
                       marketingName: "MacBook Air (15-inch, M4, 2025)", introduced: "2025-03"),

            // MARK: M4 Pro (Late 2024)
            DeviceInfo(model: "Mac16,7", chip: .m4Pro,
                       marketingName: "MacBook Pro (16-inch, M4 Pro, Late 2024)", introduced: "2024-11"),
            DeviceInfo(model: "Mac16,8", chip: .m4Pro,
                       marketingName: "MacBook Pro (14-inch, M4 Pro, Late 2024)", introduced: "2024-11"),
            DeviceInfo(model: "Mac16,11", chip: .m4Pro,
                       marketingName: "Mac mini (M4 Pro, 2024)", introduced: "2024-11"),

            // MARK: M4 Max (Late 2024 – 2025)
            DeviceInfo(model: "Mac16,5", chip: .m4Max,
                       marketingName: "MacBook Pro (16-inch, M4 Max, Late 2024)", introduced: "2024-11"),
            DeviceInfo(model: "Mac16,6", chip: .m4Max,
                       marketingName: "MacBook Pro (14-inch, M4 Max, Late 2024)", introduced: "2024-11"),
            DeviceInfo(model: "Mac16,9", chip: .m4Max,
                       marketingName: "Mac Studio (M4 Max, 2025)", introduced: "2025-03"),

            // MARK: M5 (2025–2026)
            DeviceInfo(model: "Mac17,2", chip: .m5,
                       marketingName: "MacBook Pro (14-inch, M5, 2025)", introduced: "2025-10"),
            DeviceInfo(model: "Mac17,3", chip: .m5,
                       marketingName: "MacBook Air (13-inch, M5, 2026)", introduced: "2026-03"),
            DeviceInfo(model: "Mac17,4", chip: .m5,
                       marketingName: "MacBook Air (15-inch, M5, 2026)", introduced: "2026-03"),

            // MARK: M5 Pro (2026)
            DeviceInfo(model: "Mac17,6", chip: .m5Pro,
                       marketingName: "MacBook Pro (16-inch, M5 Pro, 2026)", introduced: "2026-03"),
            DeviceInfo(model: "Mac17,7", chip: .m5Pro,
                       marketingName: "MacBook Pro (14-inch, M5 Pro, 2026)", introduced: "2026-03"),

            // MARK: M5 Max (2026)
            DeviceInfo(model: "Mac17,8", chip: .m5Max,
                       marketingName: "MacBook Pro (16-inch, M5 Max, 2026)", introduced: "2026-03"),
            DeviceInfo(model: "Mac17,9", chip: .m5Max,
                       marketingName: "MacBook Pro (14-inch, M5 Max, 2026)", introduced: "2026-03"),

            // MARK: Virtual Mac
            DeviceInfo(model: "VirtualMac2,1", chip: .virtualMac,
                       marketingName: "Apple Virtual Machine", introduced: "2022-06")
        ]

        return Dictionary(uniqueKeysWithValues: entries.map { ($0.model, $0) })
    }()
}
