import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repo = path.join(root, 'code-oss');
const bundleArgument = process.argv.indexOf('--bundle');
if (bundleArgument !== -1 && (!process.argv[bundleArgument + 1] || process.argv[bundleArgument + 1].startsWith('--'))) {
	throw new Error('--bundle requires the path to the Windows application directory.');
}
const bundle = bundleArgument === -1
	? path.join(root, 'VSCode-win32-x64')
	: path.resolve(process.argv[bundleArgument + 1]);
const app = path.join(bundle, 'resources', 'app');
const releaseInventory = process.argv.includes('--release-inventory');
const peExtensions = new Set(['.exe', '.dll', '.node', '.ocx', '.cpl', '.scr', '.sys']);
const scriptExtensions = new Set(['.ps1', '.psm1', '.psd1']);

function getReleaseInventory(directory) {
	const binaries = [];
	const scripts = [];
	const header = Buffer.alloc(64);
	const signature = Buffer.alloc(4);
	function visit(folder) {
		for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
			const file = path.join(folder, entry.name);
			const relative = path.relative(directory, file);
			if (entry.isSymbolicLink()) {
				throw new Error(`Release payload contains a junction or symbolic link: ${relative}`);
			}
			if (entry.isDirectory()) {
				visit(file);
				continue;
			}
			if (!entry.isFile()) {
				throw new Error(`Unexpected release payload entry: ${relative}`);
			}
			const extension = path.extname(entry.name).toLowerCase();
			const expectedPE = peExtensions.has(extension);
			const fd = fs.openSync(file, 'r');
			let isPE;
			try {
				isPE = fs.readSync(fd, header, 0, header.length, 0) === header.length &&
					header.readUInt16LE(0) === 0x5a4d &&
					fs.readSync(fd, signature, 0, signature.length, header.readUInt32LE(0x3c)) === signature.length &&
					signature.readUInt32LE(0) === 0x4550;
			} finally {
				fs.closeSync(fd);
			}
			if (isPE !== expectedPE) {
				throw new Error(isPE ? `PE file has an unsupported extension: ${relative}`
					: `Expected a Windows PE file: ${relative}`);
			}
			if (isPE) {
				binaries.push(relative);
			} else if (scriptExtensions.has(extension)) {
				scripts.push(relative);
			}
		}
	}
	visit(directory);
	return { binaries, scripts };
}

const source = JSON.parse(fs.readFileSync(path.join(repo, 'package.json'), 'utf8'));
const product = JSON.parse(fs.readFileSync(path.join(app, 'product.json'), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.join(app, 'package.json'), 'utf8'));
const commit = execFileSync('git', ['-c', `safe.directory=${repo.replaceAll('\\', '/')}`, 'rev-parse', 'HEAD'],
	{ cwd: repo, encoding: 'utf8', windowsHide: true }).trim();
if (manifest.version !== source.version || product.commit !== commit) {
	throw new Error('The packaged version or commit does not match its source.');
}
for (const relative of ['Code - OSS.exe', 'resources/app/out/main.js', 'resources/app/out/cli.js',
	'resources/app/node_modules.asar', 'resources/app/LICENSE.txt',
	'resources/app/extensions/git/package.json',
	'resources/app/extensions/typescript-language-features/package.json',
	'resources/app/extensions/copilot/package.json',
	'resources/app/extensions/ms-vscode.js-debug/package.json']) {
	if (!fs.statSync(path.join(bundle, relative)).isFile()) { throw new Error(`Missing packaged file: ${relative}`); }
}
const checksums = Object.entries(product.checksums ?? {});
if (checksums.length < 10) { throw new Error('Packaged workbench integrity checksums are missing.'); }
for (const [relative, expected] of checksums) {
	const file = path.resolve(app, 'out', relative);
	if (!file.startsWith(path.join(app, 'out') + path.sep)) { throw new Error('Invalid integrity file path.'); }
	const actual = createHash('sha256').update(fs.readFileSync(file)).digest('base64').replace(/=+$/, '');
	if (actual !== expected) { throw new Error(`Packaged checksum mismatch: ${relative}`); }
}
const native = ['node-pty/build/Release/conpty.node', 'node-pty/build/Release/conpty_console_list.node',
	'@vscode/spdlog/build/Release/spdlog.node', '@vscode/sqlite3/build/Release/vscode-sqlite3.node',
	'@parcel/watcher/build/Release/watcher.node', '@vscode/windows-registry/build/Release/winregistry.node',
	'@github/copilot-sdk-win32-x64/prebuilds/win32-x64/copilot-runtime.exe'];
function assertX64PE(data, relative) {
	const pe = data.length >= 64 ? data.readUInt32LE(0x3c) : 0;
	if (pe < 64 || pe > data.length - 6 || data.readUInt16LE(0) !== 0x5a4d ||
		data.readUInt32LE(pe) !== 0x4550 || data.readUInt16LE(pe + 4) !== 0x8664) {
		throw new Error(`Not a Windows x64 PE file: ${relative}`);
	}
}
for (const relative of native) {
	const file = ['node_modules.asar.unpacked', 'node_modules'].map(base => path.join(app, base, relative)).find(file => fs.existsSync(file));
	if (!file) { throw new Error(`Missing Windows native module: ${relative}`); }
	assertX64PE(fs.readFileSync(file), relative);
}
const extensionCount = fs.readdirSync(path.join(app, 'extensions')).filter(name => fs.existsSync(path.join(app, 'extensions', name, 'package.json'))).length;
if (extensionCount < 80) { throw new Error('The built-in extension collection is incomplete.'); }
const exe = fs.readFileSync(path.join(bundle, 'Code - OSS.exe'));
assertX64PE(exe, 'Code - OSS.exe');
assertX64PE(fs.readFileSync(path.join(bundle, 'dxcompiler.dll')), 'dxcompiler.dll');
const report = {
	version: manifest.version, commit, productName: product.nameLong,
	staticVerificationPassed: true, integrityFilesChecked: checksums.length,
	nativeModulesChecked: native.length, builtinExtensions: extensionCount,
	executableSha256: createHash('sha256').update(exe).digest('hex'),
	guiTestPassed: false,
};
if (!process.argv.includes('--check-only')) {
	fs.writeFileSync(path.join(root, 'evidence', 'code-oss-windows-package.json'), JSON.stringify(report, null, 2));
	fs.writeFileSync(path.join(bundle, '.code-oss-build-complete.json'), JSON.stringify(report, null, 2));
}
console.log(JSON.stringify(releaseInventory ? { ...report, ...getReleaseInventory(bundle) } : report, null, 2));
