import { downloadLinks } from '../releases.js';

const status = document.getElementById('version');
try {
  const response = await fetch('/android-release.json');
  if (!response.ok) throw new Error('Release could not be loaded.');
  const release = await response.json();
  const link = document.getElementById('apk');
  link.href = downloadLinks(release).apk;
  link.hidden = false;
  status.textContent = release.tag.slice(1) + ' · ' + (release.bytes / 1048576).toFixed(1) + ' MiB';
} catch {
  status.textContent = 'چۈشۈرۈش ئۇلانمىسى يۈكلەنمىدى. بەتنى يېڭىلاپ قايتا سىناڭ.';
}
