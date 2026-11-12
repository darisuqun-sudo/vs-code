const base = new URL('/workbench-runtime/', location.origin);
const locales = {
  en: ['English', 'Android: Download the app', 'Display language'],
  ug: ['ئۇيغۇرچە', 'Android نۇسخىسىنى چۈشۈرۈش', 'كۆرۈنمە يۈز تىلى'],
  tr: ['Türkçe', 'Android uygulamasını indir', 'Görüntüleme dili'],
  ar: ['العربية', 'تنزيل تطبيق أندرويد', 'لغة العرض'],
};

function rememberLocale(locale) {
  try { localStorage.setItem('vscode.nls.locale', locale); } catch { /* The URL also carries the preference. */ }
}

function changeLocale(locale) {
  rememberLocale(locale);
  const url = new URL(location.href);
  url.searchParams.set('lang', locale);
  location.assign(url);
}

function addLanguageSelector(locale) {
  const statusItems = document.querySelector('#workspace .part.statusbar > .right-items');
  if (!statusItems) return;
  const selector = document.createElement('select');
  selector.className = 'taklimakan-language';
  selector.setAttribute('aria-label', locales[locale][2]);
  selector.title = locales[locale][2];
  for (const [id, [label]] of Object.entries(locales)) {
    const option = new Option(label, id);
    option.lang = id;
    option.dir = 'auto';
    selector.add(option);
  }
  selector.value = locale;
  selector.addEventListener('change', () => changeLocale(selector.value));
  statusItems.prepend(selector);
}

async function loadJson(path) {
  const response = await fetch(new URL(path, base));
  if (!response.ok) throw new Error('Unable to load ' + path + ': HTTP ' + response.status);
  return response.json();
}

async function start() {
  let stored;
  try { stored = localStorage.getItem('vscode.nls.locale'); } catch { /* Use the default. */ }
  const requested = new URL(location.href).searchParams.get('lang');
  const locale = [requested, stored, 'en'].find(value => Object.hasOwn(locales, value));
  rememberLocale(locale);
  document.documentElement.lang = locale;
  document.documentElement.dataset.uiDirection = ['ug', 'ar'].includes(locale) ? 'rtl' : 'ltr';
  globalThis._VSCODE_FILE_ROOT = new URL('out/', base).href;
  globalThis._VSCODE_NLS_LANGUAGE = locale;

  const [names, gallery] = await Promise.all([
    loadJson('extensions.json'),
    loadJson('gallery.json'),
    import(new URL('locales/' + locale + '/nls.messages.js', base)),
  ]);
  const { create, env, commands } = await import(new URL('out/vs/workbench/workbench.web.main.internal.js', base));
  const compact = matchMedia('(max-width: 600px)').matches;
  const languageCommands = Object.entries(locales).map(([id, [label]]) => ({
    id: 'taklimakan.language.' + id,
    label: 'Language: ' + label,
    handler: () => changeLocale(id),
  }));
  create(document.getElementById('workspace'), {
    productConfiguration: { extensionsGallery: gallery },
    additionalBuiltinExtensions: names.map(name => ({
      scheme: location.protocol.slice(0, -1),
      authority: location.host,
      path: new URL('extensions/' + encodeURIComponent(name), base).pathname,
    })),
    configurationDefaults: {
      'workbench.startupEditor': 'welcomePage',
      'window.menuBarVisibility': matchMedia('(min-width: 900px)').matches ? 'visible' : 'compact',
      'workbench.colorTheme': 'Dark 2026',
      'workbench.sideBar.location': 'left',
      'workbench.secondarySideBar.defaultVisibility': 'hidden',
      ...(compact ? { 'workbench.editor.useModal': 'off', 'editor.wordWrap': 'on' } : {}),
    },
    commands: [...languageCommands, {
      id: 'taklimakan.android.download',
      label: locales[locale][1],
      handler: () => location.assign('/download'),
    }],
  });
  await env.retrievePerformanceMarks();
  addLanguageSelector(locale);
  try {
    if (!localStorage.getItem('taklimakan.layout-initialized')) {
      await commands.executeCommand(compact ? 'workbench.action.closeSidebar' : 'workbench.view.explorer');
      localStorage.setItem('taklimakan.layout-initialized', '1');
    }
  } catch { /* The Explorer remains available from the activity bar. */ }
  document.getElementById('startup').remove();
}

start().catch(error => {
  console.error(error);
  document.getElementById('startup-message').textContent = 'Code - OSS could not load. Refresh to retry.';
});
