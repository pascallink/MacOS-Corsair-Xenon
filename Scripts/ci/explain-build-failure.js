#!/usr/bin/env node
/**
 * Laeuft im workflow_run-Kontext, nachdem "Build" fehlgeschlagen ist.
 *
 * Holt das Log des fehlgeschlagenen Jobs, laesst dessen Ende analysieren,
 * schreibt den fertigen Kommentar nach analysis.md und meldet die PR-Nummer
 * ueber GITHUB_OUTPUT zurueck. Postet selbst nichts - das macht `gh pr comment`.
 */
'use strict';

const fs = require('node:fs');
const { askClaude, isModelUnavailable } = require('./lib/anthropic');

const TAIL_LINES = 100;
const MAX_LOG_CHARS = 12000;
const MAX_TOKENS = 512;

const SYSTEM_PROMPT =
  'Du bist ein erfahrener macOS- und Swift-Entwickler. Analysiere diesen ' +
  'Fehler aus einem SwiftPM-Lauf (swift build, swift test, bundle-app.sh). ' +
  'Erkläre in maximal 3 kurzen Sätzen, was kaputt ist, und gib direkt darunter ' +
  'den korrekten Code-Fix oder Terminal-Befehl zur Lösung an. Keine Romane.';

function env(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing env var: ${name}`);
  return value;
}

/**
 * Ein Aufruf gegen die GitHub-API. Der Accept-Header ist bewusst immer JSON:
 * die Logs-Route antwortet ohnehin mit einem Redirect auf das Klartext-Log,
 * und 'text/plain' lehnt GitHub dort inzwischen mit 415 ab.
 */
async function ghRequest(path) {
  const res = await fetch(`https://api.github.com${path}`, {
    headers: {
      accept: 'application/vnd.github+json',
      authorization: `Bearer ${env('GITHUB_TOKEN')}`,
      'x-github-api-version': '2022-11-28',
    },
  });
  if (!res.ok) throw new Error(`GitHub API ${res.status} bei ${path}: ${await res.text()}`);
  return res;
}

/** Antwort als JSON - der Normalfall. */
async function gh(path) {
  return (await ghRequest(path)).json();
}

/** Antwort als Klartext - das Log hinter dem Redirect. */
async function ghText(path) {
  return (await ghRequest(path)).text();
}

/** Zeitstempel-Praefix der Runner-Logs entfernen, spart Tokens. */
function stripTimestamps(text) {
  return text
    .split('\n')
    .map((line) => line.replace(/^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s?/, ''))
    .join('\n');
}

function tail(text) {
  let out = stripTimestamps(text).trimEnd().split('\n').slice(-TAIL_LINES).join('\n');
  // Von vorne kuerzen: der eigentliche Fehler steht am Ende.
  if (out.length > MAX_LOG_CHARS) out = out.slice(-MAX_LOG_CHARS);
  return out.trim();
}

function setOutput(key, value) {
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`);
  }
}

async function main() {
  const repo = env('GITHUB_REPOSITORY');
  const runId = env('RUN_ID');
  const headSha = env('HEAD_SHA');

  // 1. Fehlgeschlagenen Job des ausloesenden Laufs finden.
  const { jobs = [] } = await gh(`/repos/${repo}/actions/runs/${runId}/jobs?per_page=100`);
  const failed = jobs.find((job) => job.conclusion === 'failure');
  if (!failed) {
    console.log('Kein fehlgeschlagener Job gefunden - nichts zu analysieren.');
    return;
  }

  // 2. Zugehoerigen offenen PR bestimmen.
  const pulls = await gh(`/repos/${repo}/commits/${headSha}/pulls`);
  const pr = pulls.find((p) => p.state === 'open');
  if (!pr) {
    console.log(`Kein offener PR zu ${headSha.slice(0, 7)} - kein Kommentar.`);
    return;
  }

  // 3. Log-Ende holen und analysieren.
  const log = tail(await ghText(`/repos/${repo}/actions/jobs/${failed.id}/logs`));
  if (!log) {
    console.log('Log ist leer - nichts zu analysieren.');
    return;
  }

  const analysis = await askClaude({
    system: SYSTEM_PROMPT,
    user: `Job "${failed.name}" ist fehlgeschlagen. Letzte ${TAIL_LINES} Zeilen:\n\n${log}`,
    maxTokens: MAX_TOKENS,
  });

  const comment = [
    `## 🔴 Build fehlgeschlagen — \`${failed.name}\``,
    '',
    analysis,
    '',
    '<details><summary>Log-Auszug</summary>',
    '',
    // Vier Backticks: das Log darf selbst ``` enthalten, ohne die Fence zu sprengen.
    '````',
    log,
    '````',
    '',
    '</details>',
    '',
    `<sub>Automatische Analyse fuer \`${headSha.slice(0, 7)}\` · [voller Lauf](${failed.html_url}) · ` +
      'vom Modell erzeugt und ungeprueft.</sub>',
  ].join('\n');

  fs.writeFileSync('analysis.md', `${comment}\n`);
  setOutput('pr', pr.number);
  console.log(`Analyse fuer PR #${pr.number} geschrieben (Job "${failed.name}").`);
}

main().catch((err) => {
  // Eine fehlende Analyse ist Beiwerk. Steht das Modell nicht zur Verfuegung,
  // warnen statt scheitern - der rote Build, auf den dieser Job reagiert, ist
  // das eigentliche Signal.
  if (isModelUnavailable(err)) {
    console.log(`::warning title=Build-Analyse uebersprungen::${err.message}`);
    return;
  }
  console.error(err.message);
  process.exit(1);
});
