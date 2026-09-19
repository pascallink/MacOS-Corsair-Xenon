#!/bin/bash
#
# SessionStart-Hook: meldet die Swift-Toolchain und installiert commitlint,
# wenn noetig - bricht nie ab (exit 0), blockiert nie eine Sitzung.
#
# Anders als bei webkit-ext ist das hier kein Monorepo: es gibt genau ein
# package.json im Root (nur fuer commitlint), keine Schleife ueber mehrere
# Projektordner und kein core.hooksPath/pre-commit-Kosten-Tracking - die
# Kostenerfassung laeuft unveraendert ueber den Stop-Hook
# publish-claude-usage.sh (siehe docs/CLAUDE-USAGE-WIDGET.md).
set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# Toolchain-Meldung: ./Scripts/test.sh ergaenzt die CLT-Suchpfade fuer
# Testing.framework nur, wenn kein volles Xcode aktiv ist (siehe das Skript
# selbst und .github/TESTS.md). Ohne das Framework schlaegt jeder Testlauf
# fehl, bevor der erste Test startet - das lohnt eine fruehe Ansage.
if command -v xcode-select >/dev/null 2>&1; then
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [ -n "$developer_dir" ]; then
    echo "Toolchain: $developer_dir"
    if [ -d "${developer_dir}/Library/Developer/Frameworks/Testing.framework" ]; then
      echo "Testing.framework (CLT) gefunden - ./Scripts/test.sh laeuft mit swift-testing."
    else
      echo "Testing.framework (CLT) nicht unter ${developer_dir} gefunden."
      echo "Bei vollem Xcode findet swift test es selbst, sonst schlaegt"
      echo "./Scripts/test.sh fehl (.github/TESTS.md)."
    fi
  else
    echo "xcode-select -p liefert keinen Pfad - Toolchain nicht auffindbar."
  fi
else
  echo "xcode-select nicht verfuegbar - kein macOS, ./Scripts/test.sh laeuft hier nicht."
fi

# commitlint-Abhaengigkeiten: nur installieren, wenn package.json da ist und
# das Lockfile neuer ist als node_modules - derselbe Kurzschluss wie bei
# webkit-ext, hier aber nur fuer den einen Root-Ordner.
if [ -f package.json ]; then
  if [ -d node_modules ] && [ ! package-lock.json -nt node_modules ]; then
    :
  elif npm install --no-audit --no-fund >/dev/null 2>&1; then
    echo "Abhaengigkeiten installiert (commitlint)."
  else
    echo "npm install fehlgeschlagen - vor lint:commits von Hand nachholen."
  fi
fi

exit 0
