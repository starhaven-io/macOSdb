export function hasUnknownComparisonRelease(url: URL, releaseIds: ReadonlySet<string>): boolean {
  return ['from', 'to'].some((name) => {
    const id = url.searchParams.get(name);
    return id !== null && id !== '' && !releaseIds.has(id);
  });
}
