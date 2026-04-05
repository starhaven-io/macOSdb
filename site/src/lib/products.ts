import type { Product } from './api';

export interface ProductConfig {
  key: Product;
  label: string;
  includeReleaseName: boolean;
  firstRelease: string;
  indexCollection: 'macosReleases' | 'xcodeReleases';
  detailsCollection: 'macosReleaseDetails' | 'xcodeReleaseDetails';
}

export const products: Record<Product, ProductConfig> = {
  macos: {
    key: 'macos',
    label: 'macOS',
    includeReleaseName: true,
    firstRelease: 'macOS 11 Big Sur',
    indexCollection: 'macosReleases',
    detailsCollection: 'macosReleaseDetails',
  },
  xcode: {
    key: 'xcode',
    label: 'Xcode',
    includeReleaseName: false,
    firstRelease: 'Xcode 12',
    indexCollection: 'xcodeReleases',
    detailsCollection: 'xcodeReleaseDetails',
  },
};
