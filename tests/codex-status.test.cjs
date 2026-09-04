const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { EventEmitter } = require('node:events');
const vm = require('node:vm');

const source = readFileSync(join(__dirname, '..', 'accio_codex_status.js'), 'utf8');

// Run the actual entrypoint with an in-memory JSON-RPC peer. Never spawn Codex.
async function readStatus(overrides = {}) {
  const responses = {
    initialize: {},
    'account/read': { account: { type: 'chatgpt', planType: 'pro' } },
    'model/list': { data: [{ id: 'test-model', isDefault: true,
      defaultReasoningEffort: 'high', supportedReasoningEfforts: ['low', { reasoningEffort: 'high' }] }] },
    'modelProvider/capabilities/read': { imageGeneration: true },
    'account/rateLimits/read': { rateLimitsByLimitId: {
      codex: { limitId: 'codex', primary: { usedPercent: 0, windowDurationMins: 300, resetsAt: 0 } },
      extra: { limitId: 'extra', primary: { usedPercent: null }, secondary: null },
    } },
    'account/usage/read': { summary: { lifetimeTokens: 0 }, dailyUsageBuckets: [] },
    ...overrides,
  };
  const calls = [];
  let stdout = '';
  let stderr = '';
  const fakeProcess = {
    env: {}, cwd: () => '.', exitCode: 0,
    stdout: { write: (value) => { stdout += value; } },
    stderr: { write: (value) => { stderr += value; } },
  };
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.killed = false;
  child.kill = () => { child.killed = true; child.emit('exit', 0); };
  child.stdin = {
    writable: true,
    write(line) {
      const message = JSON.parse(line);
      calls.push(message);
      if (!Object.hasOwn(message, 'id')) return;
      assert.ok(Object.hasOwn(responses, message.method), `Unexpected RPC: ${message.method}`);
      const result = responses[message.method];
      const reply = result instanceof Error
        ? { id: message.id, error: { message: result.message } }
        : { id: message.id, result };
      queueMicrotask(() => {
        // Notifications and fragmented frames must not consume a pending response.
        child.stdout.emit('data', Buffer.from('{"method":"notice"}\n'));
        const encoded = `${JSON.stringify(reply)}\r\n`;
        const split = Math.floor(encoded.length / 2);
        child.stdout.emit('data', Buffer.from(encoded.slice(0, split)));
        child.stdout.emit('data', Buffer.from(encoded.slice(split)));
      });
    },
  };
  await vm.runInNewContext(source, {
    require(name) {
      assert.equal(name, 'node:child_process');
      return { spawn: () => child };
    },
    process: fakeProcess, setTimeout, clearTimeout,
  });
  assert.equal(child.killed, true, 'Child must always be stopped');
  return { status: stdout ? JSON.parse(stdout) : null, stderr, exitCode: fakeProcess.exitCode, calls };
}

test('Multiple limit groups preserve zero, null and model reasoning metadata', async () => {
  const { status, stderr, exitCode, calls } = await readStatus();
  assert.equal(exitCode, 0);
  assert.equal(stderr, '');
  assert.equal(status.rateLimits.length, 2);
  assert.equal(status.rateLimits[0].primary.usedPercent, 0);
  assert.equal(status.rateLimits[0].primary.resetsAt, 0);
  assert.equal(status.rateLimits[1].primary.usedPercent, null);
  assert.equal(status.rateLimits[1].primary.windowDurationMins, null);
  assert.equal(status.rateLimits[1].secondary, null);
  assert.equal(status.usageSummary.lifetimeTokens, 0);
  assert.deepEqual(status.models[0].supportedReasoningEfforts, ['low', 'high']);
  assert.equal(Object.hasOwn(calls.find((x) => x.method === 'account/usage/read'), 'params'), false);
});

test('Legacy single rate-limit group remains supported', async () => {
  const { status } = await readStatus({
    'account/rateLimits/read': { rateLimits: { limitId: 'codex', primary: { usedPercent: 25 } } },
  });
  assert.equal(status.rateLimits.length, 1);
  assert.equal(status.rateLimits[0].primary.usedPercent, 25);
});

test('Missing quota stays unavailable instead of becoming zero', async () => {
  const { status } = await readStatus({ 'account/rateLimits/read': {}, 'account/usage/read': {} });
  assert.deepEqual(status.rateLimits, []);
  assert.equal(status.usageSummary, null);
  assert.equal(status.dailyUsageBuckets, null);
});

test('Usage failure keeps models and limits', async () => {
  const { status, exitCode } = await readStatus({ 'account/usage/read': new Error('usage unavailable') });
  assert.equal(exitCode, 0);
  assert.equal(status.usageError, 'usage unavailable');
  assert.equal(status.rateLimits.length, 2);
  assert.equal(status.models[0].id, 'test-model');
});

test('Both usage endpoints failing still keeps login and models', async () => {
  const { status, exitCode } = await readStatus({
    'account/usage/read': new Error('usage unavailable'),
    'account/rateLimits/read': new Error('limits unavailable'),
  });
  assert.equal(exitCode, 0);
  assert.equal(status.authenticated, true);
  assert.equal(status.rateLimitsError, 'limits unavailable');
  assert.equal(status.models.length, 1);
});

test('Logged-out account does not query subscription usage', async () => {
  const { status, calls } = await readStatus({ 'account/read': { account: null, requiresOpenaiAuth: true } });
  assert.equal(status.authenticated, false);
  assert.equal(status.planType, null);
  assert.equal(calls.some((x) => /account\/(rateLimits|usage)\//.test(x.method)), false);
});

test('Required model query failure is surfaced and child is stopped', async () => {
  const { status, stderr, exitCode } = await readStatus({ 'model/list': new Error('models unavailable') });
  assert.equal(status, null);
  assert.equal(exitCode, 1);
  assert.match(stderr, /models unavailable/);
});
