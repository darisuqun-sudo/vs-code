const vscode = require('vscode');

exports.activate = function (context) {
  context.subscriptions.push(vscode.commands.registerCommand('taklimakan.layout.restoreTopMenu', async () => {
    const config = vscode.workspace.getConfiguration('window');
    if (!context.globalState.get('topMenuRestored')) {
      const setting = config.inspect('menuBarVisibility');
      // Remove an old compact override so this device's viewport default applies.
      if (setting?.globalValue === 'compact') {
        await config.update('menuBarVisibility', undefined, vscode.ConfigurationTarget.Global);
      }
      await context.globalState.update('topMenuRestored', true);
    }
  }));
};
