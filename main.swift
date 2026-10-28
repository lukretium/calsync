// calsync: spiegelt Termine zwischen einem Kundenkalender und dem eigenen Firmenkalender (Hub)
// (im Hub mit Kundenname und Termintitel, im Kundenkalender als neutraler Blocker). Läuft lokal über EventKit, keine APIs, kein OAuth.
//
//   Kunde -> Hub:  "<name> · <Titel>" (Marker calsync:busy:<name>)
//   Hub -> Kunde:  "Blocker"         (Marker calsync:block:<name>)
//
// Jede Instanz verwaltet nur Events mit ihrem eigenen Marker. Gespiegelte Events
// werden nie zurückgespiegelt, dadurch keine Loops, auch mit mehreren Macs am selben Hub.

import EventKit
import Foundation

struct Config: Codable {
    var name: String                 // z.B. "Kunde D", muss pro Mac eindeutig sein
    var workCalendars: [String]      // "Account/Kalender" oder Kalender-ID
    var hubCalendar: String          // Firmenkalender: Ziel der Kundentermine, Quelle der Blocker
    var copyTitles: Bool?            // Default true: "<name> · <Titel>" statt "Busy · <name>"
    var days: Int?                   // Zeitfenster ab heute, Default 30
    var includeAllDay: Bool?         // Default false
    var ignore: [String]?            // Kundentermine, deren Titel einen dieser Texte enthält, nicht spiegeln
}

let configPath = ProcessInfo.processInfo.environment["CALSYNC_CONFIG"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/calsync/config.json")

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(ts) \(msg)")
    fflush(stdout)
}

/// macOS-Mitteilung, damit Fehler im Hintergrund nicht nur im Log landen.
func notify(_ msg: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv\ndisplay notification (item 1 of argv) with title \"calsync\"\nend run", msg]
    try? p.run()
    p.waitUntilExit()
}

func fail(_ msg: String) -> Never {
    log("FEHLER: \(msg)")
    notify(msg)
    exit(1)
}

// MARK: - Zugriff

let store = EKEventStore()

func requestAccess() {
    if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    store.requestFullAccessToEvents { ok, _ in
        granted = ok
        sem.signal()
    }
    sem.wait()
    if !granted {
        fail("Kein Kalenderzugriff. Systemeinstellungen > Datenschutz & Sicherheit > Kalender > CalSync auf 'Vollzugriff'.")
    }
}

func ref(_ c: EKCalendar) -> String { "\(c.source.title)/\(c.title)" }

func resolve(_ r: String) -> EKCalendar {
    let all = store.calendars(for: .event)
    let hits = all.filter { $0.calendarIdentifier == r || ref($0) == r }
    if hits.count == 1 { return hits[0] }
    if hits.isEmpty { fail("Kalender '\(r)' nicht gefunden. 'calsync list' zeigt alle.") }
    fail("Kalender '\(r)' ist mehrdeutig, bitte die ID aus 'calsync list' verwenden.")
}

// MARK: - Intervalle

struct Slot: Hashable {
    let start: Date
    let end: Date
    let title: String
    var key: String { "\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))-\(title)" }
}

/// Fasst überlappende Termine zu einem Block mit festem Titel zusammen.
func merge(_ slots: [Slot], title: String) -> [Slot] {
    var out: [Slot] = []
    for s in slots.sorted(by: { $0.start < $1.start }) {
        if let last = out.last, s.start <= last.end {
            out[out.count - 1] = Slot(start: last.start, end: max(last.end, s.end), title: title)
        } else {
            out.append(Slot(start: s.start, end: s.end, title: title))
        }
    }
    return out
}

func blocksTime(_ e: EKEvent, includeAllDay: Bool) -> Bool {
    if e.isAllDay && !includeAllDay { return false }
    if e.availability == .free { return false }
    if e.status == .canceled { return false }
    if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined {
        return false
    }
    return e.endDate > e.startDate
}

// MARK: - Marker

// Eigene Events erkennt calsync daran, dass die Notizen exakt dem Marker entsprechen und es
// keine Teilnehmer gibt. Ein bloßes "enthält" würde fremde Einladungen, die den Marker-Text
// im Body tragen, als eigene behandeln und beim Abgleich löschen.
func marker(_ e: EKEvent) -> String? {
    guard !e.hasAttendees, let n = e.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
          n.hasPrefix("calsync:") else { return nil }
    return n
}

// MARK: - Heartbeat

// Jede Instanz hält im Hub einen Eintrag am 1.1.2000 aktuell, Titel "calsync <name> <Zeitpunkt>".
// Weil alle Instanzen in denselben Hub schreiben, sieht man von jedem Rechner aus, wer zuletzt
// wann erfolgreich gelaufen ist. Das Datum liegt weit außerhalb jedes Sync-Fensters.
let heartbeatDay = ISO8601DateFormatter().date(from: "2000-01-01T12:00:00Z")!

func heartbeats(in hub: EKCalendar) -> [EKEvent] {
    let pred = store.predicateForEvents(withStart: heartbeatDay.addingTimeInterval(-86400),
                                        end: heartbeatDay.addingTimeInterval(86400), calendars: [hub])
    return store.events(matching: pred).filter { marker($0)?.hasPrefix("calsync:heartbeat:") == true }
}

func writeHeartbeat(hub: EKCalendar, name: String) {
    let tag = "calsync:heartbeat:\(name)"
    let existing = heartbeats(in: hub).filter { marker($0) == tag }
    let e = existing.first ?? EKEvent(eventStore: store)
    e.calendar = hub
    e.title = "calsync \(name) \(ISO8601DateFormatter().string(from: Date()))"
    e.startDate = heartbeatDay
    e.endDate = heartbeatDay.addingTimeInterval(60)
    e.availability = .free
    e.notes = tag
    do {
        try store.save(e, span: .thisEvent, commit: true)
        for dup in existing.dropFirst() { try store.remove(dup, span: .thisEvent, commit: true) }
    } catch { log("  ! Heartbeat fehlgeschlagen: \(error.localizedDescription)") }
}

/// Letzter erfolgreicher Lauf je Instanz, aus den Heartbeats im Hub.
func lastRuns(hub: EKCalendar) -> [(name: String, at: Date)] {
    heartbeats(in: hub).compactMap { e in
        guard let tag = marker(e), let ts = e.title?.split(separator: " ").last,
              let at = ISO8601DateFormatter().date(from: String(ts)) else { return nil }
        return (String(tag.dropFirst("calsync:heartbeat:".count)), at)
    }.sorted { $0.name < $1.name }
}

// MARK: - Sync

struct Window { let start: Date; let end: Date }

/// Bringt die von uns verwalteten Events (Marker `tag`) in `target` auf den Stand `desired`.
func reconcile(target: EKCalendar, tag: String, desired: [Slot], window: Window, dryRun: Bool) -> (Int, Int) {
    let pred = store.predicateForEvents(withStart: window.start, end: window.end, calendars: [target])
    let existing = store.events(matching: pred).filter { marker($0) == tag }

    var byKey: [String: EKEvent] = [:]
    var remove: [EKEvent] = []
    for e in existing {
        let k = Slot(start: e.startDate, end: e.endDate, title: e.title ?? "").key
        if byKey[k] == nil { byKey[k] = e } else { remove.append(e) }   // Duplikate weg
    }
    let wanted = Set(desired.map(\.key))
    remove += byKey.filter { !wanted.contains($0.key) }.map(\.value)

    var created = 0
    for s in desired where byKey[s.key] == nil {
        created += 1
        if dryRun { log("  + \(target.title): \(s.title) \(s.start) - \(s.end)"); continue }
        let e = EKEvent(eventStore: store)
        e.calendar = target
        e.title = s.title
        e.startDate = s.start
        e.endDate = s.end
        e.availability = .busy
        e.notes = tag
        do { try store.save(e, span: .thisEvent, commit: false) }
        catch { log("  ! Anlegen fehlgeschlagen \(s.start): \(error.localizedDescription)") }
    }
    for e in remove {
        if dryRun { log("  - \(target.title): \(e.title ?? "") \(e.startDate!) - \(e.endDate!)"); continue }
        do { try store.remove(e, span: .thisEvent, commit: false) }
        catch { log("  ! Löschen fehlgeschlagen \(e.startDate!): \(error.localizedDescription)") }
    }
    return (created, remove.count)
}

func sync(_ cfg: Config, dryRun: Bool) {
    let work = cfg.workCalendars.map(resolve)
    let hub = resolve(cfg.hubCalendar)
    let busyTag = "calsync:busy:\(cfg.name)"
    let blockTag = "calsync:block:\(cfg.name)"
    let allDay = cfg.includeAllDay ?? false

    let today = Calendar.current.startOfDay(for: Date())
    let window = Window(start: today, end: Calendar.current.date(byAdding: .day, value: cfg.days ?? 30, to: today)!)

    store.refreshSourcesIfNecessary()

    // Kunde -> Hub: alles außer gespiegelten Events (egal von wem)
    let workEvents = store.events(matching: store.predicateForEvents(withStart: window.start, end: window.end, calendars: work))
    let busySlots = workEvents
        .filter { marker($0) == nil && blocksTime($0, includeAllDay: allDay) }
        .filter { e in !(cfg.ignore ?? []).contains { e.title?.localizedCaseInsensitiveContains($0) == true } }
        .map { Slot(start: $0.startDate, end: $0.endDate, title: "\(cfg.name) · \($0.title ?? "")") }
    let busy = cfg.copyTitles ?? true
        ? busySlots
        : merge(busySlots, title: "Busy · \(cfg.name)")

    // Hub -> Kunde: alles außer unseren eigenen Busy-Blöcken (Blöcke anderer Kunden zählen mit), ohne Titel
    let hubEvents = store.events(matching: store.predicateForEvents(withStart: window.start, end: window.end, calendars: [hub]))
    let blocks = merge(hubEvents
        .filter { marker($0) != busyTag && blocksTime($0, includeAllDay: allDay) }
        .map { Slot(start: $0.startDate, end: $0.endDate, title: "") }, title: "Blocker")

    let (bc, bd) = reconcile(target: hub, tag: busyTag, desired: busy, window: window, dryRun: dryRun)
    // Blocker nur in den ersten Kundenkalender schreiben, die anderen sind reine Quellen
    let (kc, kd) = reconcile(target: work[0], tag: blockTag, desired: blocks, window: window, dryRun: dryRun)

    if !dryRun {
        do { try store.commit() } catch { fail("Commit fehlgeschlagen: \(error.localizedDescription)") }
        writeHeartbeat(hub: hub, name: cfg.name)
    }
    log("\(dryRun ? "[dry-run] " : "")\(cfg.name): \(ref(hub)): +\(bc) -\(bd) | \(ref(work[0])): +\(kc) -\(kd)")
}

/// Entfernt alle von dieser Instanz angelegten Events, auch in der Vergangenheit und Zukunft.
func clean(_ cfg: Config) {
    let calendars = [resolve(cfg.hubCalendar), resolve(cfg.workCalendars[0])]
    let tags = ["calsync:busy:\(cfg.name)", "calsync:block:\(cfg.name)"]
    var n = 0
    // predicateForEvents ist auf 4 Jahre begrenzt, daher in Jahresschritten
    var from = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    let until = Calendar.current.date(byAdding: .year, value: 2, to: Date())!
    while from < until {
        let to = Calendar.current.date(byAdding: .year, value: 1, to: from)!
        for e in store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: calendars))
        where marker(e).map(tags.contains) == true {
            if (try? store.remove(e, span: .thisEvent, commit: false)) != nil { n += 1 }
        }
        from = to
    }
    for e in heartbeats(in: calendars[0]) where marker(e) == "calsync:heartbeat:\(cfg.name)" {
        if (try? store.remove(e, span: .thisEvent, commit: false)) != nil { n += 1 }
    }
    try? store.commit()
    log("clean \(cfg.name): \(n) Events entfernt")
}

/// Prüft die Heartbeats aller Instanzen im Hub und meldet sich, wenn eine werktags zwischen
/// 8 und 18 Uhr länger als `maxAge` Minuten still ist. Gedacht für den Rechner, an dem man sitzt.
func watch(hub: EKCalendar, maxAge: Int, quiet: Bool) {
    store.refreshSourcesIfNecessary()
    let now = Date()
    let cal = Calendar.current
    let workTime = !cal.isDateInWeekend(now) && (8..<18).contains(cal.component(.hour, from: now))
    let runs = lastRuns(hub: hub)
    var stale: [String] = []
    if runs.isEmpty {
        log("keine Heartbeats in \(ref(hub))")
        stale.append("keine Instanz meldet sich in \(ref(hub))")
    }
    for r in runs {
        let min = Int(now.timeIntervalSince(r.at) / 60)
        log("\(r.name): letzter Lauf vor \(min) Min. (\(r.at))")
        if min > maxAge { stale.append("\(r.name) seit \(min) Min. still") }
    }
    if !quiet && workTime && !stale.isEmpty { notify(stale.joined(separator: ", ")) }
}

/// Ein Objekt oder eine Liste: mehrere Kundenkalender auf einem Mac laufen als eigene Instanzen.
func loadConfigs() -> [Config] {
    guard let data = try? Data(contentsOf: configPath) else { fail("Keine Config unter \(configPath.path)") }
    if let one = try? JSONDecoder().decode(Config.self, from: data) { return [one] }
    do { return try JSONDecoder().decode([Config].self, from: data) }
    catch { fail("Config ungültig: \(error)") }
}

// MARK: - CLI

let args = CommandLine.arguments.dropFirst()
let cmd = args.first ?? "sync"
requestAccess()

switch cmd {
case "list":
    for c in store.calendars(for: .event).sorted(by: { ref($0) < ref($1) }) {
        print("\(ref(c))\t\(c.allowsContentModifications ? "rw" : "ro")\t\(c.calendarIdentifier)")
    }
case "sync":
    for cfg in loadConfigs() { sync(cfg, dryRun: args.contains("--dry-run")) }
case "clean":
    for cfg in loadConfigs() { clean(cfg) }
case "status", "watch":
    // status: Ausgabe ohne Mitteilung. watch: zusätzlich Mitteilung, wenn eine Instanz still ist.
    let rest = args.dropFirst().filter { !$0.hasPrefix("-") }
    let hub = rest.first.map(resolve) ?? resolve(loadConfigs()[0].hubCalendar)
    watch(hub: hub, maxAge: rest.dropFirst().first.flatMap { Int($0) } ?? 30, quiet: cmd == "status")
default:
    print("usage: calsync [list | sync [--dry-run] | clean | status [Kalender] | watch Kalender [Minuten]]")
    exit(2)
}
