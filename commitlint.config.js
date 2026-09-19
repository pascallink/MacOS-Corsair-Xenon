/**
 * Erzwingt die Commit-Konvention aus CLAUDE.md:
 *   <typ>(<scope>): <Betreff im Imperativ, klein, ohne Punkt>
 *
 * Die erlaubten Scopes werden zur Laufzeit aus dem Repo gelesen - jeder
 * Ordner unter Sources/ ist ein Target und damit ein Scope. Ein neues
 * Target braucht hier keine Aenderung am Scan, nur ggf. einen Eintrag in
 * ALIASES.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const FIXED_SCOPES = ['ci', 'repo', 'scripts'];

// Kurzform statt Ordnername - anders als bei webkit-ext (manifest.json als
// Erkennungsmerkmal) gibt es hier kein Signal, das einen Ordner automatisch
// als Scope qualifiziert. Jedes Sources/-Target braucht deshalb einen Eintrag.
const ALIASES = {
  XeneonEdgeKit: 'kit',
  XeneonEdgeApp: 'app',
  ClaudeUsageWidget: 'widget',
  xeneonctl: 'ctl'
};

function targetScopes() {
  const sourcesDir = path.join(__dirname, 'Sources');
  return fs
    .readdirSync(sourcesDir, { withFileTypes: true })
    .filter(function (entry) {
      return entry.isDirectory();
    })
    .map(function (entry) {
      return ALIASES[entry.name] || entry.name;
    });
}

module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [
      2,
      'always',
      ['feat', 'fix', 'refactor', 'test', 'docs', 'chore', 'build', 'ci']
    ],
    'scope-empty': [2, 'never'],
    'scope-enum': [2, 'always', FIXED_SCOPES.concat(targetScopes())],
    'subject-case': [2, 'never', ['start-case', 'pascal-case', 'upper-case']],
    'subject-full-stop': [2, 'never', '.'],
    'header-max-length': [2, 'always', 72],
    'body-max-line-length': [1, 'always', 100]
  }
};
