import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';

const project = resolve(import.meta.dir, '..');
const base = process.env.APPLE_COMPLETION_URL ?? 'http://127.0.0.1:8765';
const records: Record<string, unknown>[] = [];

function fim(prefix: string, suffix = ''): string {
  return `<|fim_prefix|>${prefix}<|fim_suffix|>${suffix}<|fim_middle|>`;
}

function nes(target: string, history: string): string {
  return `<|edit_diff_history|>\n${history}\n<|/edit_diff_history|>\n<|area_code_prefix|>\n\n<|/area_code_prefix|>\n<|code_to_edit|>\n###remain edit start boundary line###\n${target}\n###remain edit end boundary line###\n<|/code_to_edit|>\n<|area_code_suffix|>\n\n<|/area_code_suffix|>`;
}

async function post(url: string, endpoint: string, body: unknown): Promise<{status: number; data: any; ms: number}> {
  const start = performance.now();
  const response = await fetch(url + '/v1/' + endpoint, {
    method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(body),
    signal: AbortSignal.timeout(40_000),
  });
  return {status: response.status, data: await response.json(), ms: Math.round(performance.now() - start)};
}

async function evaluate(): Promise<void> {
  const models = await (await fetch(base + '/v1/models')).json() as any;
  assert.deepEqual(models.data.map((model: any) => model.id).sort(), ['apple-inline', 'apple-nes']);
  const cases = [
    {name: 'python-inline', model: 'apple-inline', prompt: fim('def add(a: int, b: int) -> int:\n    return ', '\n'), expected: /a\s*\+\s*b/},
    {name: 'markdown-inline', model: 'apple-inline', prompt: fim('# 手順\n\n1. 準備する\n2. 実行する\n3. ', '\n'), expected: /確認|結果|完了|検証/},
    {name: 'shell-inline', model: 'apple-inline', prompt: fim('#!/usr/bin/env bash\nname="world"\nprintf "%s\\n" "Hello, ', '"\n'), expected: /\$\{?name\}?/},
    {name: 'python-nes', model: 'apple-nes', target: 'def greet(user_name: str) -> str:\n    return "Hello, " + name<|cursor|>', history: '-def greet(name: str) -> str:\n+def greet(user_name: str) -> str:', expected: /\+ user_name/},
    {name: 'markdown-nes', model: 'apple-nes', target: '# インストール\n\n実行コマンド: pnpm install\n\n次に npm run dev を実行する。<|cursor|>', history: '-実行コマンド: npm install\n+実行コマンド: pnpm install', expected: /pnpm (run )?dev/},
    {name: 'shell-nes', model: 'apple-nes', target: 'user_name="world"\nprintf "%s\\n" "$name"<|cursor|>', history: '-name="world"\n+user_name="world"', expected: /\$\{?user_name\}?/},
    {name: 'markdown-prose', model: 'apple-inline', prompt: fim('# バックアップ\n\n大切なデータを失わないよう、定期的に', '\n'), expected: /バックアップ/},
    {name: 'markdown-terminology', model: 'apple-nes', target: '# ユーザーの管理\n\n利用者は設定画面から名前を変更できます。<|cursor|>', history: '-# 利用者の管理\n+# ユーザーの管理', expected: /ユーザーは設定画面/},
    {name: 'markdown-table', model: 'apple-nes', target: '# 開発手順\n\n| 操作 | コマンド |\n| --- | --- |\n| 起動 | npm run dev |\n\n```sh\necho ok\n```<|cursor|>', history: '-npm install\n+pnpm install', expected: /pnpm run dev/},
  ];
  const exact: Record<string, string> = {
    'python-nes': 'def greet(user_name: str) -> str:\n    return "Hello, " + user_name',
    'shell-nes': 'user_name="world"\nprintf "%s\\n" "$user_name"',
    'markdown-nes': '# インストール\n\n実行コマンド: pnpm install\n\n次に pnpm run dev を実行する。',
    'markdown-terminology': '# ユーザーの管理\n\nユーザーは設定画面から名前を変更できます。',
    'markdown-table': '# 開発手順\n\n| 操作 | コマンド |\n| --- | --- |\n| 起動 | pnpm run dev |\n\n```sh\necho ok\n```',
  };
  for (const example of cases) {
    const chat = example.model === 'apple-nes';
    const body = chat
      ? {model: example.model, language: example.name.split('-')[0], messages: [{role: 'user', content: nes(example.target!, example.history!)}], temperature: 0}
      : {model: example.model, language: example.name.split('-')[0], prompt: example.prompt, temperature: 0, max_tokens: 64};
    const result = await post(base, chat ? 'chat/completions' : 'completions', body);
    const text = chat ? result.data.choices?.[0]?.message?.content : result.data.choices?.[0]?.text;
    const expectedText = exact[example.name];
    const passed = result.status === 200 && example.expected.test(text ?? '') &&
      (!expectedText || text === `###remain edit start boundary line###\n${expectedText}\n###remain edit end boundary line###`);
    records.push({case: example.name, status: result.status, ms: result.ms, text, error: result.data.error, passed});
    console.log(JSON.stringify(records.at(-1)));
  }
}

async function contracts(): Promise<void> {
  const events = await fetch(base + '/health/events', {signal: AbortSignal.timeout(5000)});
  assert.equal(events.status, 200);
  assert.match(events.headers.get('content-type') ?? '', /^text\/event-stream/);
  const eventReader = events.body!.getReader();
  const firstEvent = await eventReader.read();
  const eventText = new TextDecoder().decode(firstEvent.value);
  const eventData = eventText.split('\n').find(line => line.startsWith('data: '));
  assert.ok(eventData);
  const initialHealth = JSON.parse(eventData.slice(6));
  assert.equal(initialHealth.service, 'vscode-apple-intelligence-api');
  assert.equal(initialHealth.apiVersion, 1);
  await eventReader.cancel();

  const invalid = await post(base, 'completions', {model: 'not-a-model', prompt: 'x'});
  assert.equal(invalid.status, 404);
  const wrong = await post(base, 'chat/completions', {model: 'apple-inline', messages: []});
  assert.equal(wrong.status, 400);
  const excessive = await post(base, 'chat/completions', {
    model: 'apple-nes', messages: [{role: 'user', content: nes('行'.repeat(5000), '')}],
  });
  assert.equal(excessive.data.error.code, 'context_length_exceeded');
  const truncated = await post(base, 'chat/completions', {
    model: 'apple-nes', max_tokens: 1,
    messages: [{role: 'user', content: nes('def greet(user_name: str) -> str:\n    return name', '-name\n+user_name')}],
  });
  assert.equal(truncated.status, 422);
  assert.equal(truncated.data.choices, undefined);

  const response = await fetch(base + '/v1/completions', {
    method: 'POST', headers: {'content-type': 'application/json'},
    body: JSON.stringify({model: 'apple-inline', prompt: fim('def add(a: int, b: int) -> int:\n    return ', '\n'), stream: true, temperature: 0, max_tokens: 32}),
  });
  const wire = await response.text();
  assert.match(wire, /data: \[DONE\]/);
  const chunks = wire.split('\n').filter(line => line.startsWith('data: {')).map(line => JSON.parse(line.slice(6)));
  assert.ok(chunks.every(chunk => !chunk.error));
  const text = chunks.map(chunk => chunk.choices[0].text).join('');
  assert.match(text, /^a\s*\+\s*b$/);
  assert.equal(chunks.at(-1).choices[0].finish_reason, 'stop');

  const cancel = new AbortController();
  const pending = await fetch(base + '/v1/chat/completions', {
    method: 'POST', headers: {'content-type': 'application/json'}, signal: cancel.signal,
    body: JSON.stringify({model: 'apple-nes', stream: true, messages: [{role: 'user', content: nes('def greet(user_name: str) -> str:\n    return name', '-name\n+user_name')}]}),
  });
  assert.equal(pending.status, 200);
  cancel.abort();
  await Bun.sleep(2500);
  const health = await (await fetch(base + '/health')).json() as any;
  assert.equal(health.active, false);
  assert.equal(health.queued, 0);
  records.push({case: 'api-contracts-and-cancellation', passed: true});
}

async function hotReload(): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), 'apple-completion-e2e-'));
  const config = JSON.parse(await readFile(join(project, 'resources/defaults/config.json'), 'utf8'));
  config.port = 18765;
  await cp(join(project, 'resources/defaults/prompts'), join(directory, 'prompts'), {recursive: true});
  await writeFile(join(directory, 'config.json'), JSON.stringify(config));
  const child = Bun.spawn([join(project, '.build/release/apple-intelligence-api'), '--config-dir', directory], {stdout: 'ignore', stderr: 'pipe'});
  const url = 'http://127.0.0.1:18765';
  try {
    let ready = false;
    for (let i = 0; i < 50; i++) {
      try { ready = (await fetch(url + '/health')).ok; } catch {}
      if (ready) break;
      await Bun.sleep(100);
    }
    assert.ok(ready, '分離した検証サーバーの起動');
    const promptPath = join(directory, 'prompts/apple-inline.md');
    const request = {model: 'apple-inline', prompt: fim('one, two, '), max_tokens: 16};
    await writeFile(promptPath, 'Respond with exactly APPLE_FIRST and nothing else.');
    const first = await post(url, 'completions', request);
    assert.match(first.data.choices?.[0]?.text ?? '', /APPLE_FIRST/);
    await writeFile(promptPath, 'Respond with exactly APPLE_SECOND and nothing else.');
    const second = await post(url, 'completions', request);
    assert.match(second.data.choices?.[0]?.text ?? '', /APPLE_SECOND/);
    const stopped = await post(url, 'completions', {...request, stop: '_SECOND'});
    assert.equal(stopped.data.choices[0].text, 'APPLE');
    await writeFile(join(directory, 'config.json'), '{');
    assert.equal((await fetch(url + '/health')).status, 503);
    await writeFile(join(directory, 'config.json'), JSON.stringify(config));
    assert.equal((await fetch(url + '/health')).status, 200);
    records.push({case: 'prompt-hot-reload-stop-and-config-recovery', passed: true});
  } finally {
    child.kill();
    await child.exited;
    await rm(directory, {recursive: true});
  }
}

try {
  let ready = false;
  for (let attempt = 0; attempt < 50; attempt++) {
    try { ready = (await fetch(base + '/health')).ok; } catch {}
    if (ready) break;
    await Bun.sleep(100);
  }
  assert.ok(ready, '補完サーバーの起動');
  await evaluate();
  await contracts();
  if (process.argv.includes('--hot-reload')) await hotReload();
} catch (error) {
  records.push({case: 'contract-failure', passed: false, error: String(error)});
  console.error(error);
} finally {
  const report = join(project, '.build/evaluation.json');
  await mkdir(dirname(report), {recursive: true});
  await writeFile(report, JSON.stringify({at: new Date().toISOString(), records}, null, 2));
}
if (records.some(record => record.passed === false)) process.exitCode = 1;
