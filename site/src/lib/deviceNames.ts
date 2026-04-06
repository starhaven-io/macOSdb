/**
 * Device model identifier to marketing name mapping.
 * Mirrors Sources/macOSdbKit/Models/DeviceRegistry.swift — keep in sync.
 */
const deviceNames: Record<string, string> = {
  // M1
  'MacBookAir10,1': 'MacBook Air (M1, Late 2020)',
  'MacBookPro17,1': 'MacBook Pro (13-inch, M1, Late 2020)',
  'Macmini9,1': 'Mac mini (M1, Late 2020)',
  'iMac21,1': 'iMac (24-inch, M1, 2021) 2-port',
  'iMac21,2': 'iMac (24-inch, M1, 2021) 4-port',

  // M1 Pro
  'MacBookPro18,1': 'MacBook Pro (16-inch, M1 Pro, Late 2021)',
  'MacBookPro18,3': 'MacBook Pro (14-inch, M1 Pro, Late 2021)',

  // M1 Max
  'MacBookPro18,2': 'MacBook Pro (16-inch, M1 Max, Late 2021)',
  'MacBookPro18,4': 'MacBook Pro (14-inch, M1 Max, Late 2021)',
  'Mac13,1': 'Mac Studio (M1 Max, 2022)',

  // M1 Ultra
  'Mac13,2': 'Mac Studio (M1 Ultra, 2022)',

  // M2
  'Mac14,2': 'MacBook Air (13-inch, M2, 2022)',
  'Mac14,7': 'MacBook Pro (13-inch, M2, 2022)',
  'Mac14,3': 'Mac mini (M2, 2023)',
  'Mac14,15': 'MacBook Air (15-inch, M2, 2023)',

  // M2 Pro
  'Mac14,9': 'MacBook Pro (14-inch, M2 Pro, 2023)',
  'Mac14,10': 'MacBook Pro (16-inch, M2 Pro, 2023)',
  'Mac14,12': 'Mac mini (M2 Pro, 2023)',

  // M2 Max
  'Mac14,5': 'MacBook Pro (14-inch, M2 Max, 2023)',
  'Mac14,6': 'MacBook Pro (16-inch, M2 Max, 2023)',
  'Mac14,13': 'Mac Studio (M2 Max, 2023)',

  // M2 Ultra
  'Mac14,14': 'Mac Studio (M2 Ultra, 2023)',
  'Mac14,8': 'Mac Pro (M2 Ultra, 2023)',

  // M3
  'Mac15,3': 'MacBook Pro (14-inch, M3, Late 2023)',
  'Mac15,4': 'iMac (24-inch, M3, 2023) 2-port',
  'Mac15,5': 'iMac (24-inch, M3, 2023) 4-port',
  'Mac15,12': 'MacBook Air (13-inch, M3, 2024)',
  'Mac15,13': 'MacBook Air (15-inch, M3, 2024)',

  // M3 Pro
  'Mac15,6': 'MacBook Pro (14-inch, M3 Pro, Late 2023)',
  'Mac15,7': 'MacBook Pro (16-inch, M3 Pro, Late 2023)',

  // M3 Max
  'Mac15,8': 'MacBook Pro (14-inch, M3 Max, Late 2023)',
  'Mac15,9': 'MacBook Pro (16-inch, M3 Max, Late 2023)',
  'Mac15,10': 'MacBook Pro (14-inch, M3 Max, Late 2023)',
  'Mac15,11': 'MacBook Pro (16-inch, M3 Max, Late 2023)',

  // M3 Ultra
  'Mac15,14': 'Mac Studio (M3 Ultra, 2025)',

  // M4
  'Mac16,1': 'MacBook Pro (14-inch, M4, Late 2024)',
  'Mac16,2': 'iMac (24-inch, M4, 2024) 2-port',
  'Mac16,3': 'iMac (24-inch, M4, 2024) 4-port',
  'Mac16,10': 'Mac mini (M4, 2024)',
  'Mac16,12': 'MacBook Air (13-inch, M4, 2025)',
  'Mac16,13': 'MacBook Air (15-inch, M4, 2025)',

  // M4 Pro
  'Mac16,7': 'MacBook Pro (16-inch, M4 Pro, Late 2024)',
  'Mac16,8': 'MacBook Pro (14-inch, M4 Pro, Late 2024)',
  'Mac16,11': 'Mac mini (M4 Pro, 2024)',

  // M4 Max
  'Mac16,5': 'MacBook Pro (16-inch, M4 Max, Late 2024)',
  'Mac16,6': 'MacBook Pro (14-inch, M4 Max, Late 2024)',
  'Mac16,9': 'Mac Studio (M4 Max, 2025)',

  // M5
  'Mac17,2': 'MacBook Pro (14-inch, M5, 2025)',
  'Mac17,3': 'MacBook Air (13-inch, M5, 2026)',
  'Mac17,4': 'MacBook Air (15-inch, M5, 2026)',

  // M5 Pro
  'Mac17,6': 'MacBook Pro (16-inch, M5 Pro, 2026)',
  'Mac17,7': 'MacBook Pro (14-inch, M5 Pro, 2026)',

  // M5 Max
  'Mac17,8': 'MacBook Pro (16-inch, M5 Max, 2026)',
  'Mac17,9': 'MacBook Pro (14-inch, M5 Max, 2026)',

  // A18 Pro
  'Mac17,5': 'MacBook Neo (13-inch, 2026)',

  // Virtual Mac
  'VirtualMac2,1': 'Apple Virtual Machine',
};

export function deviceDisplayName(model: string): string {
  return deviceNames[model] ?? model;
}
