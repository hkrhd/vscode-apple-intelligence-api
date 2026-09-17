import * as vscode from 'vscode';
import {ChildProcessWithoutNullStreams, spawn} from 'node:child_process';
import {constants} from 'node:fs';
import {access, cp, mkdir, open, readFile, readdir, rename, rm, writeFile} from 'node:fs/promises';
import * as path from 'node:path';
import * as readline from 'node:readline';

const SERVICE = 'vscode-apple-intelligence-api';
const API_VERSION = 1;
const DEFAULT_PORT = 8765;
const PROMPT_SETTING_KEYS = [
  'inline.instructions', 'inline.languageInstructions', 'inline.promptTemplate', 'inline.languagePromptTemplates',
  'nes.instructions', 'nes.languageInstructions', 'nes.promptTemplate', 'nes.languagePromptTemplates',
  'nes.renameHintTemplate', 'nes.languageRenameHintTemplates',
] as const;

type PromptProfile = {
  instructions: string;
  language_instructions: Record<string, string>;
  prompt_template: string;
  language_prompt_templates: Record<string, string>;
  rename_hint_template?: string;
  language_rename_hint_templates?: Record<string, string>;
};

type PromptSettings = {
  models: Record<'apple-inline' | 'apple-nes', PromptProfile>;
  validation_errors: string[];
};

type Health = {
  service?: string;
  apiVersion?: number;
  status?: string;
  modelAvailability?: string;
  active?: boolean;
  activeModel?: string;
  activeLanguage?: string;
  queued?: number;
  completed?: number;
  cancelled?: number;
  failed?: number;
  last?: {model: string; totalMilliseconds: number; outcome: string};
  error?: {message?: string};
};

class ServerController implements vscode.Disposable {
  private readonly output = vscode.window.createOutputChannel('Apple Intelligence API', {log: true});
  private readonly status = vscode.window.createStatusBarItem('appleIntelligenceApi.status', vscode.StatusBarAlignment.Right, 99);
  private readonly configDir: string;
  private readonly defaultsDir: string;
  private readonly lockPath: string;
  private child: ChildProcessWithoutNullStreams | undefined;
  private lockHandle: Awaited<ReturnType<typeof open>> | undefined;
  private wanted = false;
  private disposed = false;
  private restartTimer: NodeJS.Timeout | undefined;
  private eventReconnectTimer: NodeJS.Timeout | undefined;
  private eventController: AbortController | undefined;
  private restartDelay = 1000;
  private eventReconnectDelay = 1000;
  private health: Health | undefined;
  private state: 'starting' | 'disabled' | 'restarting' | 'conflict' | 'config-error' | undefined;
  private promptConfigurationError: string | undefined;
  private promptSync: Promise<void> = Promise.resolve();
  private lastKnownPort = DEFAULT_PORT;

  constructor(private readonly context: vscode.ExtensionContext) {
    this.configDir = path.join(context.globalStorageUri.fsPath, 'config');
    this.defaultsDir = context.asAbsolutePath(path.join('resources', 'defaults'));
    this.lockPath = path.join(context.globalStorageUri.fsPath, 'server.lock');
    this.status.name = 'Apple Intelligence API';
    this.status.command = 'appleIntelligenceApi.toggle';
    this.status.text = '$(sync~spin) Apple: 準備中';
    this.status.show();
  }

  async initialize(): Promise<void> {
    await mkdir(this.context.globalStorageUri.fsPath, {recursive: true});
    await this.syncMissing(this.defaultsDir, this.configDir);
    await this.syncPromptSettings(true);
    this.wanted = vscode.workspace.getConfiguration('appleIntelligenceApi').get('enabled', true);
    if (this.wanted) {
      await this.ensureServer();
      void this.connectHealthEvents();
    } else this.state = 'disabled';
    this.render();
  }

  private async syncMissing(source: string, destination: string): Promise<void> {
    await mkdir(destination, {recursive: true});
    for (const entry of await readdir(source, {withFileTypes: true})) {
      const from = path.join(source, entry.name);
      const to = path.join(destination, entry.name);
      if (entry.isDirectory()) await this.syncMissing(from, to);
      else {
        try { await access(to, constants.F_OK); }
        catch { await cp(from, to); }
      }
    }
  }

  private readPromptSettings(): {value: PromptSettings; errors: string[]} {
    const configuration = vscode.workspace.getConfiguration('appleIntelligenceApi');
    const errors: string[] = [];
    const readString = (key: string): string => {
      const value = configuration.get<unknown>(key);
      if (typeof value !== 'string') {
        errors.push(`${key}は文字列で指定してください。`);
        return '';
      }
      return value;
    };
    const readMap = (key: string): Record<string, string> => {
      const value = configuration.get<unknown>(key);
      if (!value || typeof value !== 'object' || Array.isArray(value)) {
        errors.push(`${key}は言語IDと文字列のオブジェクトで指定してください。`);
        return {};
      }
      const result: Record<string, string> = {};
      for (const [language, prompt] of Object.entries(value)) {
        if (!language.trim()) errors.push(`${key}の言語IDを空にできません。`);
        if (typeof prompt !== 'string') errors.push(`${key}.${language}は文字列で指定してください。`);
        else result[language] = prompt;
      }
      return result;
    };
    const profile = (name: 'inline' | 'nes'): PromptProfile => ({
      instructions: readString(`${name}.instructions`),
      language_instructions: readMap(`${name}.languageInstructions`),
      prompt_template: readString(`${name}.promptTemplate`),
      language_prompt_templates: readMap(`${name}.languagePromptTemplates`),
      ...(name === 'nes' ? {
        rename_hint_template: readString('nes.renameHintTemplate'),
        language_rename_hint_templates: readMap('nes.languageRenameHintTemplates'),
      } : {}),
    });
    const value: PromptSettings = {
      models: {'apple-inline': profile('inline'), 'apple-nes': profile('nes')},
      validation_errors: errors,
    };
    for (const [model, prompt] of Object.entries(value.models)) {
      const strings: Array<[string, string]> = [[`${model}の指示プロンプト`, prompt.instructions],
        ...Object.entries(prompt.language_instructions).map<[string, string]>(([language, text]) => [`${model}/${language}の指示プロンプト`, text])];
      for (const [label, text] of strings) if (!text.trim()) errors.push(`${label}を空にできません。`);
      const required = model === 'apple-inline'
        ? ['{before}', '{after}']
        : ['{recentEdits}', '{beforeTarget}', '{afterTarget}', '{target}'];
      const templates: Array<[string, string]> = [[`${model}のテンプレート`, prompt.prompt_template],
        ...Object.entries(prompt.language_prompt_templates).map<[string, string]>(([language, text]) => [`${model}/${language}のテンプレート`, text])];
      for (const [label, template] of templates) {
        for (const placeholder of required) {
          if (template.split(placeholder).length !== 2) errors.push(`${label}には${placeholder}を1回だけ指定してください。`);
        }
      }
      if (model === 'apple-nes') {
        const renameTemplates: Array<[string, string]> = [[`${model}のrenameテンプレート`, prompt.rename_hint_template ?? ''],
          ...Object.entries(prompt.language_rename_hint_templates ?? {}).map<[string, string]>(([language, text]) => [`${model}/${language}のrenameテンプレート`, text])];
        for (const [label, template] of renameTemplates) {
          for (const placeholder of ['{old}', '{new}']) {
            if (template.split(placeholder).length !== 2) errors.push(`${label}には${placeholder}を1回だけ指定してください。`);
          }
        }
      }
    }
    return {value, errors};
  }

  syncPromptSettings(notify: boolean): Promise<void> {
    const pending = this.promptSync.then(() => this.writePromptSettings(notify));
    this.promptSync = pending.catch(() => undefined);
    return pending;
  }

  private async writePromptSettings(notify: boolean): Promise<void> {
    const {value, errors} = this.readPromptSettings();
    const target = path.join(this.configDir, 'prompt-settings.json');
    const temporary = path.join(this.configDir, `prompt-settings.${process.pid}.${Date.now()}.${Math.random()}.tmp`);
    await writeFile(temporary, JSON.stringify(value, null, 2));
    await rename(temporary, target);
    const previous = this.promptConfigurationError;
    this.promptConfigurationError = errors.length ? errors.join(' ') : undefined;
    if (this.promptConfigurationError && this.promptConfigurationError !== previous) {
      this.output.error(`プロンプト設定が不正です: ${this.promptConfigurationError}`);
      if (notify) void vscode.window.showErrorMessage(`Apple Intelligence APIのプロンプト設定が不正です: ${this.promptConfigurationError}`);
    }
    this.render();
  }

  private async configuredPort(): Promise<number> {
    try {
      const config = JSON.parse(await readFile(path.join(this.configDir, 'config.json'), 'utf8')) as {port?: unknown};
      if (typeof config.port === 'number' && Number.isInteger(config.port) && config.port >= 1024 && config.port <= 65535) {
        this.lastKnownPort = config.port;
        return config.port;
      }
      throw new Error('portは1024〜65535の整数にしてください。');
    } catch (error) {
      this.state = 'config-error';
      this.output.error(`設定の読み込みに失敗しました: ${String(error)}`);
      return this.lastKnownPort;
    }
  }

  private async fetchHealth(): Promise<{kind: 'ours' | 'other' | 'offline'; health?: Health}> {
    const port = await this.configuredPort();
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 1500);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`, {signal: controller.signal});
      const health = await response.json() as Health;
      if (health.service === SERVICE && health.apiVersion === API_VERSION) return {kind: 'ours', health};
      return {kind: 'other', health};
    } catch {
      return {kind: 'offline'};
    } finally {
      clearTimeout(timeout);
    }
  }

  private async acquireLock(): Promise<boolean> {
    try {
      this.lockHandle = await open(this.lockPath, 'wx', 0o600);
      await this.lockHandle.writeFile(JSON.stringify({pid: process.pid, createdAt: new Date().toISOString()}));
      return true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
    }
    try {
      const lock = JSON.parse(await readFile(this.lockPath, 'utf8')) as {pid?: unknown};
      if (typeof lock.pid === 'number') process.kill(lock.pid, 0);
      return false;
    } catch {
      await rm(this.lockPath, {force: true});
      return this.acquireLock();
    }
  }

  private pipe(stream: NodeJS.ReadableStream, level: 'info' | 'error'): void {
    readline.createInterface({input: stream}).on('line', line => {
      if (level === 'error') this.output.error(line);
      else this.output.info(line);
    });
  }

  async ensureServer(): Promise<void> {
    if (this.disposed || !this.wanted || this.child) return;
    const existing = await this.fetchHealth();
    if (existing.kind === 'ours') {
      if (this.lockHandle && !this.child) await this.releaseLock();
      this.health = existing.health;
      this.state = undefined;
      return;
    }
    if (existing.kind === 'other') {
      this.state = 'conflict';
      return;
    }
    if (!this.lockHandle && !await this.acquireLock()) {
      this.state = 'starting';
      return;
    }
    const binary = this.context.asAbsolutePath(path.join('bin', 'apple-intelligence-api'));
    try {
      await access(binary, constants.X_OK);
    } catch (error) {
      this.state = 'config-error';
      this.output.error(`同梱サーバーを実行できません: ${String(error)}`);
      await this.releaseLock();
      return;
    }
    this.state = this.restartDelay > 1000 ? 'restarting' : 'starting';
    this.output.info(`サーバーを開始します: ${binary}`);
    const child = spawn(binary, ['--config-dir', this.configDir], {
      cwd: this.context.extensionPath,
      env: {...process.env, LOG_LEVEL: 'critical'},
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    this.child = child;
    if (this.lockHandle && child.pid) {
      await writeFile(this.lockPath, JSON.stringify({pid: process.pid, serverPid: child.pid, createdAt: new Date().toISOString()}));
    }
    this.pipe(child.stdout, 'info');
    this.pipe(child.stderr, 'error');
    child.once('error', error => this.output.error(`起動エラー: ${String(error)}`));
    child.once('exit', (code, signal) => {
      if (this.child !== child) return;
      this.child = undefined;
      this.health = undefined;
      this.disconnectHealthEvents(false);
      this.output.warn(`サーバーが終了しました: code=${String(code)} signal=${String(signal)}`);
      if (this.wanted && !this.disposed) {
        this.state = 'restarting';
        const delay = this.restartDelay;
        this.restartDelay = Math.min(this.restartDelay * 2, 30_000);
        this.restartTimer = setTimeout(() => {
          void (async () => {
            await this.ensureServer();
            await this.connectHealthEvents();
          })();
        }, delay);
      }
      this.render();
    });
  }

  private async releaseLock(): Promise<void> {
    if (!this.lockHandle) return;
    await this.lockHandle.close().catch(() => undefined);
    this.lockHandle = undefined;
    await rm(this.lockPath, {force: true});
  }

  private async terminateOwned(): Promise<void> {
    clearTimeout(this.restartTimer);
    this.restartTimer = undefined;
    const child = this.child;
    this.child = undefined;
    if (child && child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM');
      await Promise.race([
        new Promise<void>(resolve => child.once('exit', () => resolve())),
        new Promise<void>(resolve => setTimeout(resolve, 5000)),
      ]);
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
    await this.releaseLock();
  }

  private disconnectHealthEvents(resetDelay = true): void {
    clearTimeout(this.eventReconnectTimer);
    this.eventReconnectTimer = undefined;
    this.eventController?.abort();
    this.eventController = undefined;
    if (resetDelay) this.eventReconnectDelay = 1000;
  }

  private scheduleHealthReconnect(): void {
    if (this.disposed || !this.wanted || this.eventReconnectTimer) return;
    const delay = this.eventReconnectDelay;
    this.eventReconnectDelay = Math.min(this.eventReconnectDelay * 2, 30_000);
    this.eventReconnectTimer = setTimeout(() => {
      this.eventReconnectTimer = undefined;
      void (async () => {
        await this.ensureServer();
        await this.connectHealthEvents();
      })();
    }, delay);
  }

  private async connectHealthEvents(): Promise<void> {
    if (this.disposed || !this.wanted || this.eventController) return;
    const port = await this.configuredPort();
    const controller = new AbortController();
    this.eventController = controller;
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health/events`, {signal: controller.signal});
      if (!response.ok || !response.body) throw new Error(`health events: HTTP ${response.status}`);
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      while (!this.disposed && this.wanted) {
        const part = await reader.read();
        if (part.done) break;
        buffer += decoder.decode(part.value, {stream: true}).replaceAll('\r\n', '\n');
        let boundary: number;
        while ((boundary = buffer.indexOf('\n\n')) >= 0) {
          const event = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + 2);
          const payload = event.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
          if (!payload) continue;
          const health = JSON.parse(payload) as Health;
          if (health.service !== SERVICE || health.apiVersion !== API_VERSION) {
            this.state = 'conflict';
            this.render();
            controller.abort();
            return;
          }
          this.health = health;
          this.state = undefined;
          this.eventReconnectDelay = 1000;
          this.render();
        }
      }
    } catch (error) {
      if (!controller.signal.aborted) this.output.warn(`状態通知が切断されました: ${String(error)}`);
    } finally {
      if (this.eventController === controller) this.eventController = undefined;
      if (!controller.signal.aborted) this.scheduleHealthReconnect();
    }
  }

  async start(persist = true): Promise<void> {
    if (persist) await vscode.workspace.getConfiguration('appleIntelligenceApi').update('enabled', true, vscode.ConfigurationTarget.Global);
    this.wanted = true;
    this.restartDelay = 1000;
    await this.ensureServer();
    void this.connectHealthEvents();
  }

  async stop(persist = true): Promise<void> {
    if (persist) await vscode.workspace.getConfiguration('appleIntelligenceApi').update('enabled', false, vscode.ConfigurationTarget.Global);
    this.wanted = false;
    this.disconnectHealthEvents();
    await this.terminateOwned();
    this.health = undefined;
    this.state = 'disabled';
    this.render();
  }

  async toggle(): Promise<void> {
    if (this.wanted) await this.stop();
    else await this.start();
  }

  async restart(): Promise<void> {
    this.wanted = true;
    this.disconnectHealthEvents();
    if (!this.child && !this.lockHandle) {
      const current = await this.fetchHealth();
      if (current.kind === 'ours') {
        try {
          const lock = JSON.parse(await readFile(this.lockPath, 'utf8')) as {serverPid?: unknown};
          if (typeof lock.serverPid === 'number') {
            process.kill(lock.serverPid, 'SIGTERM');
            this.state = 'restarting';
            this.render();
            this.scheduleHealthReconnect();
            return;
          }
        } catch {}
        void vscode.window.showInformationMessage('サーバーは別ウインドウが管理しています。管理元で再起動してください。');
        return;
      }
    }
    await this.terminateOwned();
    this.restartDelay = 1000;
    this.state = 'starting';
    await this.ensureServer();
    void this.connectHealthEvents();
  }

  private render(): void {
    this.status.backgroundColor = undefined;
    if (this.promptConfigurationError) {
      this.status.text = '$(warning) Apple: プロンプト設定エラー';
      this.status.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    } else if (this.state === 'conflict') {
      this.status.text = '$(error) Apple: ポート競合';
      this.status.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
    } else if (this.state === 'config-error') {
      this.status.text = '$(warning) Apple: 設定エラー';
      this.status.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    } else if (this.state === 'restarting') {
      this.status.text = '$(sync~spin) Apple: 再起動中';
    } else if (this.state === 'starting') {
      this.status.text = '$(sync~spin) Apple: 起動中';
    } else if (this.state === 'disabled') {
      this.status.text = '$(circle-slash) Apple: 無効';
    } else if (this.health?.status !== 'ok') {
      this.status.text = '$(warning) Apple: 利用不可';
      this.status.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    } else if (this.health.active) {
      const mode = this.health.activeModel === 'apple-nes' ? 'NES' : 'inline';
      const queued = this.health.queued ? `・${this.health.queued}件待機` : '';
      this.status.text = `$(loading~spin) Apple: ${mode} 推論中${queued}`;
    } else {
      this.status.text = '$(check) Apple: 待機';
    }
    const language = this.health?.activeLanguage && this.health.activeLanguage !== 'unknown' ? `\n言語: ${this.health.activeLanguage}` : '';
    const last = this.health?.last ? `\n直近: ${this.health.last.model} / ${this.health.last.totalMilliseconds}ms / ${this.health.last.outcome}` : '';
    const action = this.wanted ? 'クリックで無効化（サーバーを終了）' : 'クリックで有効化';
    this.status.tooltip = `Apple Intelligence（オンデバイス）\nhttp://127.0.0.1:${this.lastKnownPort}${language}${last}\n${action}`;
  }

  async openConfig(): Promise<void> {
    await this.syncMissing(this.defaultsDir, this.configDir);
    await vscode.window.showTextDocument(vscode.Uri.file(path.join(this.configDir, 'config.json')));
  }

  async openPrompts(): Promise<void> {
    await vscode.commands.executeCommand('workbench.action.openSettings', '@ext:hkrhd.vscode-apple-intelligence-api prompt');
  }

  showLogs(): void { this.output.show(true); }

  async showStatus(): Promise<void> {
    const message = this.health
      ? `Apple Intelligence: ${this.health.active ? '推論中' : this.health.status === 'ok' ? '待機' : '利用不可'} / 完了 ${this.health.completed ?? 0} / キャンセル ${this.health.cancelled ?? 0} / 失敗 ${this.health.failed ?? 0}`
      : `Apple Intelligence API: ${this.state ?? '未接続'}`;
    const selected = await vscode.window.showInformationMessage(message, '設定を開く', 'ログを表示');
    if (selected === '設定を開く') await this.openConfig();
    if (selected === 'ログを表示') this.showLogs();
  }

  async resetDefaults(): Promise<void> {
    const answer = await vscode.window.showWarningMessage(
      '編集済みの設定とプロンプトをデフォルトへ戻します。元に戻せません。',
      {modal: true}, '初期化'
    );
    if (answer !== '初期化') return;
    await this.stop(false);
    await rm(this.configDir, {recursive: true, force: true});
    await this.syncMissing(this.defaultsDir, this.configDir);
    const configuration = vscode.workspace.getConfiguration('appleIntelligenceApi');
    for (const key of PROMPT_SETTING_KEYS) await configuration.update(key, undefined, vscode.ConfigurationTarget.Global);
    await this.syncPromptSettings(false);
    await this.start(false);
  }

  async disposeAsync(): Promise<void> {
    this.disposed = true;
    this.wanted = false;
    clearTimeout(this.restartTimer);
    this.disconnectHealthEvents();
    await this.terminateOwned();
    this.status.dispose();
    this.output.dispose();
  }

  dispose(): void { void this.disposeAsync(); }
}

let controller: ServerController | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  controller = new ServerController(context);
  context.subscriptions.push(
    controller,
    vscode.commands.registerCommand('appleIntelligenceApi.toggle', () => controller?.toggle()),
    vscode.commands.registerCommand('appleIntelligenceApi.start', () => controller?.start()),
    vscode.commands.registerCommand('appleIntelligenceApi.stop', () => controller?.stop()),
    vscode.commands.registerCommand('appleIntelligenceApi.restart', () => controller?.restart()),
    vscode.commands.registerCommand('appleIntelligenceApi.openConfig', () => controller?.openConfig()),
    vscode.commands.registerCommand('appleIntelligenceApi.openPrompts', () => controller?.openPrompts()),
    vscode.commands.registerCommand('appleIntelligenceApi.showLogs', () => controller?.showLogs()),
    vscode.commands.registerCommand('appleIntelligenceApi.showStatus', () => controller?.showStatus()),
    vscode.commands.registerCommand('appleIntelligenceApi.resetDefaults', () => controller?.resetDefaults()),
    vscode.workspace.onDidChangeConfiguration(event => {
      if (event.affectsConfiguration('appleIntelligenceApi.enabled')) {
        const enabled = vscode.workspace.getConfiguration('appleIntelligenceApi').get('enabled', true);
        if (enabled) void controller?.start(false);
        else void controller?.stop(false);
      }
      if (event.affectsConfiguration('appleIntelligenceApi.inline') || event.affectsConfiguration('appleIntelligenceApi.nes')) {
        void controller?.syncPromptSettings(true);
      }
    }),
  );
  await controller.initialize();
}

export async function deactivate(): Promise<void> {
  await controller?.disposeAsync();
  controller = undefined;
}
