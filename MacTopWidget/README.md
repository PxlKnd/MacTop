# MacTopWidget

Natives Swift/AppKit-Desktop-Widget im Mactop-Stil — keine Dependencies, eine kompilierte Binary.

## Anzeigen
- **CPU**: Gesamt + Balken pro Core (P/E-Core-Erkennung)
- **GPU**: Device / Renderer / Tiler Utilization (via IOAccelerator)
- **Memory**: App/Wired/Compressed segmentiert, Swap (Activity-Monitor-Rechnung)
- **Network**: Down/Up-Raten + Sparkline-Historie (60 s)
- **Disk**: Read/Write-Durchsatz (IOBlockStorageDriver) + Volume-Belegung
- **Top-Prozesse**: CPU%, Name, MEM, PID
- **Uptime** oben rechts

## Bedienung
- Fenster an beliebiger Stelle ziehen (Position wird gemerkt)
- `×` oben rechts = beenden
- `⌃↑ ON/OFF` = Always-on-Top umschalten
- Update alle 1 s

## Bauen & Starten
```bash
./build.sh                 # kompilieren
./MacTopWidget &           # manuell starten
./build.sh --install-autostart    # + LaunchAgent (Autostart beim Login)
./build.sh --uninstall-autostart  # Autostart entfernen
```

## Projekt aktualisieren
Quellen unter `Sources/` (Metrics.swift = Datenerfassung, main.swift = UI), dann `./build.sh`.
LaunchAgent zeigt auf die Binary im Projektordner — also nicht verschieben nach dem Installieren.
