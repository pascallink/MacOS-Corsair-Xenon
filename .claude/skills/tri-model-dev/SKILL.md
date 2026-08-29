---
name: tri-model-dev
description: 3-Stufen Entwicklungs-Workflow mit Modellwechsel (Opus 5 -> Fable 5 -> Sonnet 5)
---

Führe für die gegebene Anforderung oder Problemstellung den folgenden strukturierten Workflow aus.

**Stufe 1: Analyse & Issue-Erstellung**
- **Modell:** `opus 5`
- **Aktionen:**
  1. Analysiere das Problem tiefgehend im Kontext der lokalen Codebasis.
  2. Fasse die Ursachen, betroffenen Komponenten und Akzeptanzkriterien zusammen.
  3. Erstelle mit dem CLI-Tool (z. B. `gh issue create`) ein neues Issue im Repository mit dem Titel und dieser strukturierten Problembeschreibung.

**Stufe 2: Umsetzungsplanung**
- **Modell:** `fable 5`
- **Aktionen:**
  1. Lies das in Stufe 1 erstellte Issue und die Analyseergebnisse ein.
  2. Entwirf einen detaillierten technischen Umsetzungsplan (Architekturänderungen, betroffene Dateien, Edge-Cases).
  3. Formuliere eine präzise Schritt-für-Schritt-Anleitung für die spätere Implementierung.

**Stufe 3: Lokale Implementierung**
- **Modell:** `sonnet 5`
- **Aktionen:**
  1. Setze den in Stufe 2 erstellten Umsetzungsplan schrittweise im lokalen Quellcode um.
  2. Kompiliere und teste die Applikation lokal.
  3. Stelle sicher, dass alle Tests erfolgreich durchlaufen, bevor die Änderungen lokal committet werden.
