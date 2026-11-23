# MacTopKit — echtes Schreibtisch-Widget (WidgetKit)

Eigenständiger Build neben dem Schiebe-HUD (`../MacTopWidget`). compilert mit swiftc, signiert mit Apple Development, ohne Xcode-Projekt.

## Build & Installation
```bash
./build-app.sh
```
Installiert nach `/Applications` (falls beschreibbar) sonst nach `~/Applications` und registriert die App bei LaunchServices.

## Widget hinzufügen
1. App startet nach dem Build automatisch (kurzes Fenster mit Anleitung).
2. **Rechtsklick auf den Schreibtisch → „Widgets bearbeiten…"**
3. Links/unten nach **MacTop Monitor** suchen → medium-Widget auf den Schreibtisch ziehen.

Falls es nicht in der Galerie erscheint: App einmal aus `~/Applications` starten und die Galerie schließen/erneut öffnen. Als letzten Ausweg Abmelden/Anmelden.

## Anzeigedaten (P/E farblich wie im HUD)
CPU gesamt + Core-Balken (P = Ampel grün/gelb/rot, E = Blau), GPU %, RAM %, Netzwerk ↓/↑.

## Timeline-Hintergrund
WidgetKit liefert pro Reload einen aktuellen Messwert (mit kurzem Warmup für das CPU/Netz-Delta) und plant das nächste Update nach 30 s ein (`.after`). macOS drosselt Widgets systemweit nach eigenem Budget — ein echtes 1–5-Sekunden-Live-Intervall übernimmt das unabhängige HUD (`../MacTopWidget`).

## Neu bauen nach Codeänderung
`./build-app.sh` kompiliert die Extension mit `-application-extension` und Entry-Point `_NSExtensionMain` (Pflicht für WidgetKit ohne Xcode), ersetzt die Installation und startet `chronod` neu.
