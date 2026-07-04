/// Fallback device mapping for kernelcache filenames that use board codenames
/// instead of device model identifiers. macOS 11-13 IPSWs use names like
/// `kernelcache.release.mac13g` rather than `kernelcache.release.MacBookAir10,1_...`.
/// These mappings are derived from BuildManifest data in later macOS versions.
let boardCodeNameDevices: [String: [String]] = [
    // M1 (H13G) - all M1 base-tier Macs
    "kernelcache.release.mac13g": [
        "MacBookAir10,1", "MacBookPro17,1", "Macmini9,1",
        "iMac21,1", "iMac21,2"
    ],
    // M1 Pro/Max (H13J) - all M1 Pro and M1 Max Macs
    "kernelcache.release.mac13j": [
        "Mac13,1", "Mac13,2",
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4"
    ],
    // M2 (H14G) - all M2 base-tier Macs
    "kernelcache.release.mac14g": [
        "Mac14,2", "Mac14,3", "Mac14,7", "Mac14,15"
    ],
    // M2 Pro/Max (H14J) - all M2 Pro and M2 Max Macs
    "kernelcache.release.mac14j": [
        "Mac14,5", "Mac14,6", "Mac14,8", "Mac14,9",
        "Mac14,10", "Mac14,12", "Mac14,13", "Mac14,14"
    ],
    // Virtual Mac
    "kernelcache.release.vma2": ["VirtualMac2,1"]
]
