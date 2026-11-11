import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const asset = 'CodeOSS-Web-1.140.0-07f806f.tar.gz';
const url = 'https://github.com/darisuqun-sudo/code-oss-android-downloads/releases/download/web-1.140.0-07f806f/' + asset;
const expectedHash = '1fca5cdd72ab7cb7177650da20c68398949bc0c3cac534370dc6096e083916ec';
const target = new URL('../public/workbench-runtime/', import.meta.url);
const scratch = await mkdtemp(join(tmpdir(), 'codeoss-site-'));
try {
  let archive = process.argv[2];
  if (!archive) {
    archive = join(scratch, asset);
    const response = await fetch(url, { signal: AbortSignal.timeout(180_000) });
    if (!response.ok || !response.body) throw new Error('Workbench download failed: HTTP ' + response.status);
    await pipeline(response.body, createWriteStream(archive));
  }
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(archive)) hash.update(chunk);
  if (hash.digest('hex') !== expectedHash) throw new Error('Workbench archive SHA-256 mismatch');
  await mkdir(target, { recursive: true });
  const tar = spawnSync('tar', ['-xzf', archive, '-C', fileURLToPath(target)], { stdio: 'inherit' });
  if (tar.error) throw tar.error;
  if (tar.status !== 0) throw new Error('Workbench archive extraction failed');
  const metadata = JSON.parse(await readFile(new URL('BUILD_SOURCE.json', target), 'utf8'));
  if (metadata.commit !== '07f806f999227108933c2e30515b26eecc1fda74' || metadata.target !== 'web') {
    throw new Error('Unexpected Workbench build');
  }
  console.log('Code - OSS web runtime verified and staged.');
} finally {
  await rm(scratch, { recursive: true, force: true });
}
