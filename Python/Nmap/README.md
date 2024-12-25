
# NMAP Scanner

Dieses Projekt ist ein einfacher Port-Scanner, der mit Python geschrieben wurde. Der Scanner erkennt offene Ports auf einer Ziel-IP und versucht über Banner Grabbing den Service zu identifizieren, der auf dem jeweiligen Port läuft.

## Funktionen

1. **Port Scanning**: Identifiziert offene Ports auf einem Zielsystem.
2. **Banner Grabbing**: Ermittelt, welche Services auf den offenen Ports laufen.

## Nutzung

### Voraussetzungen

- Python 3.x
- Erforderliche Module:
  - `socket`  (standardmäßig enthalten)
  - `concurrent.futures` (standardmäßig enthalten)

### Ausführung

1. Bearbeite das Skript und setze die Ziel-IP (`target`) und den Portbereich (`port_range`), falls nötig.
2. Führe das Skript aus:
   ```bash
   python nmap_scanner.py
   ```

### Beispielausgabe

```
Trying Port: 0
Trying Port: 1
...
Offene Ports auf 10.129.7.19 --> [22, 80]
Port 22 --> Banner: b"SSH-2.0-OpenSSH_7.9\r\n"
Port 80 --> Banner: b"HTTP/1.1 200 OK\r\n"
```

## Hinweis

- **Bildungszwecke**: Bitte scanne nur Systeme, für die du die Erlaubnis hast.
- **Fehlerbehandlung**: Das Skript enthält grundlegende Fehlerbehandlung für Netzwerkprobleme.


---

Viel Spaß beim Testen und Experimentieren!
