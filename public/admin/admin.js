import { downloadLinks, releaseRepo, tagPattern, validateRelease } from '../releases.js';

const owner = 'darisuqun-sudo';
const source = '/repos/' + owner + '/vs-code/contents/public/android-release.json';
const github = 'https://api.github.com';
const $ = id => document.getElementById(id);
const login = $('login');
const manager = $('manager');
const status = $('status');
const select = $('candidate');
const save = $('save');
let session;

async function request(path, token, options) {
  const headers = { Accept: 'application/vnd.github+json' };
  if (token) headers.Authorization = 'Bearer ' + token;
  if (options?.body) headers['Content-Type'] = 'application/json';
  const response = await fetch(github + path, {
    ...options, headers, cache: 'no-store', credentials: 'omit', redirect: 'error',
  });
  if (!response.ok) throw new Error('GitHub HTTP ' + response.status, { cause: response.status });
  return response.json();
}

function candidates(releases) {
  return releases.flatMap(release => {
    if (release.draft || !tagPattern.test(release.tag_name) ||
        !release.assets?.some(asset => asset.state === 'uploaded' && asset.name === 'SHA256SUMS.txt')) return [];
    return release.assets.filter(asset => asset.state === 'uploaded' &&
      /^[0-9A-Za-z._-]+\.apk$/i.test(asset.name) && /^sha256:[0-9a-f]{64}$/i.test(asset.digest))
      .map(asset => validateRelease({ tag: release.tag_name, asset: asset.name, bytes: asset.size }));
  });
}

function showRelease(release) {
  const links = downloadLinks(release);
  $('current').textContent = release.tag;
  $('checksum').href = links.checksum;
  $('notes').href = links.notes;
}

function updateButton() {
  const next = session?.choices[select.value];
  save.disabled = !next || (next.tag === session.release.tag && next.asset === session.release.asset);
}

login.addEventListener('submit', async event => {
  event.preventDefault();
  const field = $('token');
  const releaseField = $('release-token');
  const button = login.querySelector('button');
  const token = field.value.trim();
  const releaseToken = releaseField.value.trim();
  field.value = '';
  releaseField.value = '';
  if (![token, releaseToken].every(value => /^github_pat_[0-9A-Za-z_]+$/.test(value))) {
    status.textContent = 'ھەر ئىككى ئامبارغا ماس GitHub ئاچقۇچىنى كىرگۈزۈڭ.';
    return;
  }
  button.disabled = true;
  status.textContent = 'GitHub ھوقۇقى تەكشۈرۈلۈۋاتىدۇ…';
  try {
    const user = await request('/user', token);
    if (user.login?.toLowerCase() !== owner) throw new Error('Wrong GitHub account', { cause: 403 });
    const [file, releases] = await Promise.all([
      request(source + '?ref=main', token),
      request('/repos/' + releaseRepo + '/releases?per_page=50', releaseToken),
    ]);
    const release = validateRelease(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(file.content), c => c.charCodeAt(0)))));
    const choices = candidates(releases);
    session = { token, release, sha: file.sha, choices };
    showRelease(release);
    select.replaceChildren(new Option('—', ''));
    choices.forEach((choice, index) => select.add(new Option(choice.tag + ' · ' + choice.asset, String(index))));
    updateButton();
    login.hidden = true;
    manager.hidden = false;
    status.textContent = choices.length ? '' : 'تاللايدىغان نەشر تېپىلمىدى.';
    select.focus();
  } catch {
    status.textContent = 'كىرىش مەغلۇپ بولدى. GitHub ھېساباتى ۋە ئامبار ھوقۇقىنى تەكشۈرۈڭ.';
    field.focus();
  } finally {
    button.disabled = false;
  }
});

select.addEventListener('change', updateButton);

$('publish').addEventListener('submit', async event => {
  event.preventDefault();
  if (!session || save.disabled) return;
  const current = session;
  const next = current.choices[select.value];
  save.disabled = true;
  select.disabled = true;
  $('logout').disabled = true;
  status.textContent = 'GitHub غا ساقلىنىۋاتىدۇ…';
  try {
    const result = await request(source, current.token, {
      method: 'PUT',
      body: JSON.stringify({
        message: 'Select Android download ' + next.tag,
        branch: 'main',
        sha: current.sha,
        content: btoa(JSON.stringify(next, null, 2) + '\n'),
      }),
    });
    current.release = next;
    current.sha = result.content.sha;
    showRelease(next);
    status.textContent = 'GitHub غا ساقلاندى. Vercel يېڭى نەشرنى ئېلان قىلغاندىن كېيىن چۈشۈرۈش بېتى يېڭىلىنىدۇ.';
  } catch (error) {
    status.textContent = error.cause === 409 || error.cause === 422
      ? 'نەشرنى باشقا بىر جەريان ئۆزگەرتكەن بولۇشى مۇمكىن. قايتا كىرىپ يېڭى ھالىتىنى ئېلىڭ.'
      : 'ساقلانمىدى. ئاچقۇچنىڭ يېزىش ھوقۇقى ۋە GitHub نىڭ شاخچە تەڭشىكىنى تەكشۈرۈڭ.';
  } finally {
    select.disabled = false;
    $('logout').disabled = false;
    updateButton();
  }
});

$('logout').addEventListener('click', () => {
  session = undefined;
  select.replaceChildren();
  manager.hidden = true;
  login.hidden = false;
  status.textContent = '';
  $('token').focus();
});
