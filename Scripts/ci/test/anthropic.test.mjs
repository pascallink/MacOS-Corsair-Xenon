// Tests fuer scripts/lib/anthropic.js. Kein Netz: globales fetch wird je Test
// durch eine Attrappe ersetzt. Geprueft wird vor allem die Einteilung der
// Fehler - nur was vom Modell kommt, darf einen CI-Job gruen lassen.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import anthropic from '../lib/anthropic.js';

const { askClaude, isModelUnavailable, ModelUnavailableError } = anthropic;

function withFetch(handler, fn, { apiKey = 'test-key' } = {}) {
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.ANTHROPIC_API_KEY;
  globalThis.fetch = async (url, init) => handler(url, init);
  if (apiKey === null) delete process.env.ANTHROPIC_API_KEY;
  else process.env.ANTHROPIC_API_KEY = apiKey;
  return Promise.resolve(fn()).finally(() => {
    globalThis.fetch = originalFetch;
    if (originalKey === undefined) delete process.env.ANTHROPIC_API_KEY;
    else process.env.ANTHROPIC_API_KEY = originalKey;
  });
}

function response(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  };
}

test('Antworttext wird aus den text-Bloecken zusammengesetzt', async () => {
  await withFetch(
    () => response(200, { content: [{ type: 'text', text: '- a: b' }] }),
    async () => {
      const text = await askClaude({ system: 's', user: 'u', maxTokens: 10 });
      assert.strictEqual(text, '- a: b');
    },
  );
});

test('leeres Guthaben ist ein Modellfehler, kein Codefehler', async () => {
  await withFetch(
    () => response(400, { error: { message: 'Your credit balance is too low' } }),
    async () => {
      const err = await askClaude({ system: 's', user: 'u', maxTokens: 10 }).catch((e) => e);
      assert.ok(isModelUnavailable(err), 'nicht als Modellfehler markiert');
      assert.match(err.message, /400/);
    },
  );
});

test('abgelehnter Schluessel ist ein Modellfehler', async () => {
  await withFetch(
    () => response(401, { error: { message: 'invalid x-api-key' } }),
    async () => {
      const err = await askClaude({ system: 's', user: 'u', maxTokens: 10 }).catch((e) => e);
      assert.ok(isModelUnavailable(err));
    },
  );
});

test('fehlender Schluessel ist ein Modellfehler', async () => {
  await withFetch(
    () => {
      throw new Error('fetch haette nicht laufen duerfen');
    },
    async () => {
      const err = await askClaude({ system: 's', user: 'u', maxTokens: 10 }).catch((e) => e);
      assert.ok(isModelUnavailable(err));
      assert.match(err.message, /ANTHROPIC_API_KEY/);
    },
    { apiKey: null },
  );
});

test('Antwort ohne Text ist ein Modellfehler', async () => {
  await withFetch(
    () => response(200, { content: [] }),
    async () => {
      const err = await askClaude({ system: 's', user: 'u', maxTokens: 10 }).catch((e) => e);
      assert.ok(isModelUnavailable(err));
    },
  );
});

test('isModelUnavailable haelt fremde Fehler auseinander', () => {
  assert.strictEqual(isModelUnavailable(new ModelUnavailableError('x')), true);
  assert.strictEqual(isModelUnavailable(new Error('Kaputt im eigenen Code')), false);
  assert.strictEqual(isModelUnavailable(new TypeError('undefined is not a function')), false);
  assert.strictEqual(isModelUnavailable(null), false);
  assert.strictEqual(isModelUnavailable(undefined), false);
});
