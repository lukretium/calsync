# calsync

Für alle, die pro Kunde einen eigenen Mac mit eigenem Outlook haben und trotzdem überall
sehen wollen, wann sie woanders belegt sind. Ein privater Google-Kalender dient als Drehscheibe:

- Kunde -> Google: `<name> · <Termintitel>` (ohne Inhalt und Teilnehmer)
- Google -> Kunde: `Blocker` (private Termine und Termine anderer Kunden-Macs)

```
Kunde A (Exchange) ──"A · Daily"──▶ Google ◀──"B · Review"── Kunde B (Exchange)
       ▲                              │                            ▲
       └────────── "Blocker" ◀────────┴────────▶ "Blocker" ────────┘
```

Läuft lokal über EventKit (Apples Kalender-API), alle 10 Minuten per LaunchAgent. Keine
Cloud, keine API-Keys, keine App-Registrierung beim Kunden. In Kundenkalender gehen
standardmäßig nie Titel, weder private noch die anderer Kunden.

## Voraussetzungen

calsync sieht nur, was in **Apples Kalender-App** steht, nicht was in Outlook steht.

1. **Kundenkalender:** In der Kalender-App müssen die Kundentermine sichtbar sein. Auf
   verwalteten Macs ist der Exchange-Account oft schon eingerichtet. Sonst:
   Systemeinstellungen → Internetaccounts → Microsoft Exchange → Kunden-Adresse →
   "Anmelden" → nur "Kalender" aktivieren.
2. **Google:** Systemeinstellungen → Internetaccounts → Google → privater Account → nur
   "Kalender" aktivieren (Mail, Kontakte, Notizen haben auf einem Kunden-Mac nichts verloren).
3. **Compiler:** `swiftc` muss da sein, sonst einmal `xcode-select --install`.

## Setup pro Mac

```sh
git clone https://github.com/lukretium/calsync.git && cd calsync
./install.sh                  # baut (ca. 1 Min, ohne Ausgabe), fragt Kalenderzugriff an, listet Kalender
```

Den Dialog zum Kalenderzugriff bestätigen. Danach kommt eine Liste wie:

```
Exchange/Calendar                rw  56F37DF8-D782-4C86-B07F-D29467EBE935
Google/max.muster@gmail.com      rw  C5A91E71-A47C-4391-A0E2-807DF6C06A66
```

Config schreiben, Namen exakt aus der Liste übernehmen (oder die ID aus der dritten Spalte,
wenn ein Name mehrfach vorkommt):

```sh
cat > ~/.config/calsync/config.json <<'EOF'
{
  "name": "Kunde A",
  "workCalendars": ["Exchange/Calendar"],
  "hubCalendar": "Google/max.muster@gmail.com"
}
EOF
```

Lieber so oder mit einem Code-Editor schreiben: TextEdit macht aus `"` gern typografische
Anführungszeichen, dann ist das JSON kaputt.

```sh
./calsync sync --dry-run      # zeigt, was angelegt (+) und gelöscht (-) würde
./calsync sync                # einmal echt, danach Google und Outlook prüfen
./calsync sync                # sollte "+0 -0" melden
./install.sh enable           # alle 10 Minuten im Hintergrund
```

Log: `tail -f ~/Library/Logs/calsync.log`. Programm immer mit `./calsync` aufrufen, es liegt
nicht im PATH.

## Config

| Feld | Default | Bedeutung |
|---|---|---|
| `name` | (Pflicht) | Präfix in Google und Erkennungsmerkmal der eigenen Einträge. Pro Mac eindeutig. |
| `workCalendars` | (Pflicht) | Kundenkalender. Alle sind Quellen, der erste bekommt die Blocker. |
| `hubCalendar` | (Pflicht) | Google-Kalender, in den gespiegelt wird. |
| `blockFrom` | `[hubCalendar]` | Kalender, aus denen Blocker entstehen. |
| `days` | `30` | Zeitfenster ab heute. |
| `copyTitles` | `true` | `false`: in Google nur `busyTitle`-Blöcke statt Titel. |
| `busyTitle` | `Busy · <name>` | Titel der Blöcke bei `copyTitles: false`. |
| `blockerTitle` | `Blocker` | Titel der Blocker im Kundenkalender. |
| `blockerTitles` | `false` | `true`: Termine anderer Kunden behalten im Kundenkalender ihren Titel (z.B. für den eigenen Firmenkalender). Private Termine bleiben `Blocker`. |
| `includeAllDay` | `false` | Ganztägige Termine mitspiegeln. |
| `ignore` | `[]` | Termine, deren Titel einen dieser Texte enthält, nicht spiegeln. |

Mehrere Kundenkalender auf einem Mac: Config als Liste von Objekten, jedes läuft als eigene
Instanz.

Abgelehnte, abgesagte, als "frei" markierte und ganztägige Termine werden übersprungen.
Blocker werden bei Überlappung zusammengefasst.

## Wie es funktioniert

Jeder gespiegelte Eintrag trägt in den Notizen einen Marker (`calsync:busy:<name>` bzw.
`calsync:block:<name>`) und hat keine Teilnehmer. Jede Instanz verwaltet nur Einträge mit
ihrem eigenen Marker, gespiegelte Einträge werden nie zurückgespiegelt. Dadurch keine
Schleifen, auch wenn mehrere Macs am selben Google-Kalender hängen.

## Troubleshooting

- **Termine in Google, die es in Outlook nicht mehr gibt** (alte Serien, alte Uhrzeiten):
  Apples Kalender hat Löschungen vom Exchange-Server verpasst. Das ist lokal nicht erkennbar.
  Fix: `./install.sh disable`, Exchange-Account in den Internetaccounts entfernen und neu
  anlegen, warten bis alles geladen ist, neue Kalender-ID per `./calsync list` in die Config,
  `./install.sh enable`.
- **`Kalender '...' nicht gefunden`:** Name stimmt nicht exakt (z.B. `gmail.com` vs.
  `googlemail.com`) oder die ID hat sich nach einem Account-Neustart geändert.
- **`Unable to block on application ...`:** Harmlos, kommt vom Starter-Skript, wenn calsync
  sehr schnell fertig ist.
- **Verzögerung:** Ein Termin braucht vom einen Mac über Google bis in den anderen Kalender
  realistisch 10 bis 30 Minuten (Kalender-Sync, calsync-Takt, Exchange/iOS-Abruf).

## Weg damit

```sh
./install.sh disable && ./calsync clean
```

`clean` entfernt alle von dieser Instanz angelegten Einträge in Google und im Kundenkalender.
