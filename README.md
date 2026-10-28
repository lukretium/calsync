# calsync

Für alle, die pro Kunde einen eigenen Mac mit eigenem Outlook haben und trotzdem überall
sehen wollen, wann sie woanders belegt sind. Der eigene Firmenkalender dient als Drehscheibe:

- Kunde -> Firma: `<name> · <Termintitel>` (ohne Inhalt und Teilnehmer)
- Firma -> Kunde: `Blocker` (Firmentermine und Termine anderer Kunden-Macs)

```
Kunde A (Exchange) ──"A · Daily"──▶ Firma ◀──"B · Review"── Kunde B (Exchange)
       ▲                              │                           ▲
       └────────── "Blocker" ◀────────┴───────▶ "Blocker" ────────┘
```

Auf dem eigenen Firmen-Mac läuft nichts. Dort und auf dem Handy reicht der Firmenkalender,
er enthält alle Kundentermine mit Titel.

Läuft lokal über EventKit (Apples Kalender-API), alle 10 Minuten per LaunchAgent. Keine
Cloud, keine API-Keys, keine App-Registrierung beim Kunden. In Kundenkalender gehen nie
Titel, weder eigene noch die anderer Kunden.

## Voraussetzungen

calsync sieht nur, was in **Apples Kalender-App** steht, nicht was in Outlook steht. Auf
jedem Kunden-Mac braucht die Kalender-App zwei Accounts, jeweils nur mit "Kalender":

1. **Kunde:** Auf verwalteten Macs ist der Exchange-Account oft schon eingerichtet. Sonst:
   Systemeinstellungen → Internetaccounts → Microsoft Exchange → Kunden-Adresse → "Anmelden".
2. **Firma:** Systemeinstellungen → Internetaccounts → Microsoft Exchange → eigene
   Firmen-Adresse → "Anmelden".
3. **Compiler:** `swiftc` muss da sein, sonst einmal `xcode-select --install`.

## Setup pro Kunden-Mac

```sh
git clone https://github.com/lukretium/calsync.git && cd calsync
./install.sh                  # baut (ca. 1 Min, ohne Ausgabe), fragt Kalenderzugriff an, listet Kalender
```

Den Dialog zum Kalenderzugriff bestätigen. Danach kommt eine Liste wie:

```
Exchange/Calendar                rw  56F37DF8-D782-4C86-B07F-D29467EBE935
max.muster@firma.de/Calendar     rw  C5A91E71-A47C-4391-A0E2-807DF6C06A66
max.muster@firma.de/Calendar     rw  9B2F0D44-6E1A-4C7B-8F35-1D2A7C9E0B58
```

Config schreiben, Namen exakt aus der Liste übernehmen oder die ID aus der dritten Spalte:

```sh
cat > ~/.config/calsync/config.json <<'EOF'
{
  "name": "Kunde A",
  "workCalendars": ["Exchange/Calendar"],
  "hubCalendar": "C5A91E71-A47C-4391-A0E2-807DF6C06A66"
}
EOF
```

Taucht ein Kalender doppelt auf (zum Beispiel nach einem Tenant-Wechsel), ist einer davon
meist ein Altbestand. Den richtigen findet der Dry-Run: Die `Blocker`-Zeilen müssen zu den
eigenen Firmenterminen passen.

Lieber so oder mit einem Code-Editor schreiben: TextEdit macht aus `"` gern typografische
Anführungszeichen, dann ist das JSON kaputt.

```sh
./calsync sync --dry-run      # zeigt, was angelegt (+) und gelöscht (-) würde, Zeiten in UTC
./calsync sync                # einmal echt, danach Firmen- und Kundenkalender prüfen
./calsync sync                # sollte "+0 -0" melden
./install.sh enable           # alle 10 Minuten im Hintergrund
```

Log: `tail -f ~/Library/Logs/calsync.log`. Programm immer mit `./calsync` aufrufen, es liegt
nicht im PATH.

## Config

| Feld | Default | Bedeutung |
|---|---|---|
| `name` | (Pflicht) | Präfix im Firmenkalender und Erkennungsmerkmal der eigenen Einträge. Pro Mac eindeutig. |
| `workCalendars` | (Pflicht) | Kundenkalender. Alle sind Quellen, der erste bekommt die Blocker. |
| `hubCalendar` | (Pflicht) | Firmenkalender, in den gespiegelt wird und aus dem die Blocker kommen. |
| `days` | `30` | Zeitfenster ab heute. |
| `copyTitles` | `true` | `false`: im Firmenkalender nur `Busy · <name>` statt Titel. |
| `includeAllDay` | `false` | Ganztägige Termine mitspiegeln. |
| `ignore` | `[]` | Kundentermine, deren Titel einen dieser Texte enthält, nicht spiegeln. |

Mehrere Kundenkalender auf einem Mac: Config als Liste von Objekten, jedes läuft als eigene
Instanz.

Abgelehnte, abgesagte, als "frei" markierte und ganztägige Termine werden übersprungen.
Blocker werden bei Überlappung zusammengefasst. Private Termine blockieren Kunden, wenn sie
im Firmenkalender stehen.

## Läuft es?

Jede Instanz schreibt nach jedem erfolgreichen Lauf einen Heartbeat in den Firmenkalender:
einen Eintrag heute 00:00 bis 00:01, Titel `calsync <name> <Zeitpunkt>`, als "frei"
markiert. Weil alle Kunden-Macs in denselben Firmenkalender schreiben, sieht man von jedem
Rechner aus, wer zuletzt wann gelaufen ist:

```sh
./calsync status <Firmenkalender>   # z.B. "DM: letzter Lauf vor 4 Min."
```

Auf dem Rechner, an dem man täglich sitzt, prüft ein Wächter das alle 15 Minuten und meldet
sich per macOS-Mitteilung, wenn eine Instanz werktags zwischen 8 und 18 Uhr länger als 30
Minuten still ist (Agent aus, Kunden-Mac zugeklappt, Kalenderzugriff weg):

```sh
./install.sh watch <Firmenkalender-ID aus ./calsync list>   # "./install.sh watch off" stoppt ihn
```

Fehler wie fehlender Kalenderzugriff oder ein nicht gefundener Kalender kommen zusätzlich
direkt auf dem Kunden-Mac als Mitteilung.

## Wie es funktioniert

Jeder gespiegelte Eintrag trägt in den Notizen einen Marker (`calsync:busy:<name>` bzw.
`calsync:block:<name>`) und hat keine Teilnehmer. Jede Instanz verwaltet nur Einträge mit
ihrem eigenen Marker, gespiegelte Einträge werden nie zurückgespiegelt. Dadurch keine
Schleifen, auch wenn mehrere Macs am selben Firmenkalender hängen.

## Troubleshooting

- **Termine im Firmenkalender, die es beim Kunden nicht mehr gibt** (alte Serien, alte
  Uhrzeiten): Apples Kalender hat Löschungen vom Exchange-Server verpasst. Das ist lokal nicht
  erkennbar. Fix: `./install.sh disable`, Kunden-Account in den Internetaccounts entfernen und
  neu anlegen, warten bis alles geladen ist, neue Kalender-ID per `./calsync list` in die
  Config, `./install.sh enable`.
- **`Kalender '...' nicht gefunden`:** Name stimmt nicht exakt oder die ID hat sich nach
  einem Account-Neustart geändert.
- **`Unable to block on application ...`:** Harmlos, kommt vom Starter-Skript, wenn calsync
  sehr schnell fertig ist.
- **Verzögerung:** Ein Termin braucht vom Kunden-Mac bis aufs Handy oder in den anderen
  Kalender realistisch 10 bis 30 Minuten (Kalender-Sync, calsync-Takt, Exchange-Abruf).

## Update

```sh
git pull && ./install.sh
```

`install.sh` baut neu, wenn `main.swift` oder `Info.plist` neuer sind als die gebaute App.
Ein laufender Hintergrund-Sync nimmt die neue Version beim nächsten Lauf automatisch, ein
erneutes `enable` ist nicht nötig. Ob er läuft: `launchctl list | grep calsync`.

## Weg damit

```sh
./install.sh disable && ./calsync clean
```

`clean` entfernt alle von dieser Instanz angelegten Einträge im Firmen- und im
Kundenkalender, auch den Heartbeat (sonst meldet der Wächter sie als still). Beim Wechsel des `hubCalendar` vorher mit der alten Config ausführen, sonst
bleiben die alten Einträge liegen.
