# calsync

Spiegelt Termine zwischen einem Kundenkalender (Exchange) und einem Hub-Kalender (Google). Läuft lokal über EventKit, alle 10 Minuten per LaunchAgent.

- Kunde -> Google: `<name> · <Termintitel>` (ohne Inhalt und Teilnehmer)
- Google -> Kunde: `Blocker` (private Termine und Busy-Blöcke anderer Kunden-Macs)

In den Kundenkalender gehen nie Titel, weder private noch die anderer Kunden. Jede Instanz verwaltet
nur Events mit eigenem Marker in den Notizen (`calsync:busy:<name>` / `calsync:block:<name>`),
gespiegelte Events werden nie zurückgespiegelt.

## Setup pro Mac

Voraussetzung: Kunden-Exchange und Google-Account sind in Apples Kalender-App sichtbar.

```sh
./install.sh                  # baut, installiert, fragt Kalenderzugriff an, listet Kalender
vi ~/.config/calsync/config.json
./calsync sync --dry-run      # zeigt, was passieren würde
./calsync sync                # einmal echt
./install.sh enable           # alle 10 Minuten im Hintergrund
```

Kalender per `Account/Kalender` oder bei Mehrdeutigkeit per ID aus `./calsync list`.
`name` muss eindeutig sein. Mehrere Kundenkalender auf einem Mac: Config als
Liste von Objekten, jede läuft als eigene Instanz. Bauen braucht `swiftc` (`xcode-select --install`).

Config-Felder: `name`, `workCalendars` (erster bekommt die Blocker), `hubCalendar`,
optional `blockFrom` (Hub-Kalender als Blocker-Quelle, Default `hubCalendar`),
`copyTitles` (Default true, false = nur `busyTitle`-Blöcke), `busyTitle`, `blockerTitle`, `days` (Default 30), `includeAllDay` (Default false).

Abgelehnte, abgesagte, als "frei" markierte und ganztägige Termine werden ignoriert,
Blocker (und Busy-Blöcke ohne `copyTitles`) werden bei Überlappung zusammengefasst.

## Weg damit

```sh
./install.sh disable && ./calsync clean
```
