export const releaseRepo = 'darisuqun-sudo/code-oss-android-downloads';
export const tagPattern = /^v[0-9][0-9A-Za-z._-]{0,79}$/;
const assetPattern = /^[0-9A-Za-z._-]+\.apk$/i;

export function validateRelease(release) {
  if (!release || typeof release.tag !== 'string' || !tagPattern.test(release.tag) ||
      typeof release.asset !== 'string' || !assetPattern.test(release.asset) ||
      !Number.isSafeInteger(release.bytes) || release.bytes <= 0) {
    throw new Error('Android release metadata is invalid.');
  }
  return release;
}

export function downloadLinks(release) {
  const tag = encodeURIComponent(validateRelease(release).tag);
  const root = 'https://github.com/' + releaseRepo + '/releases';
  const download = root + '/download/' + tag + '/';
  return {
    apk: download + encodeURIComponent(release.asset),
    checksum: download + 'SHA256SUMS.txt',
    notes: root + '/tag/' + tag,
  };
}
