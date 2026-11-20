// SlurmHUD — a tiny floating HUD for watching your Slurm jobs over SSH.
// Native AppKit + SwiftUI, no web view. Polls one ssh command every N seconds
// through an existing ControlMaster socket, so MFA clusters work without
// the app ever trying to authenticate on its own.

import AppKit
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Config

struct GroupRule: Codable, Equatable {
    var match: String?   // regular expression, searched anywhere in the job name
    var label: String?   // row title; defaults to the names' common prefix + "*"
}

struct Config: Codable, Equatable {
    var host = ""      // a Host alias from ~/.ssh/config
    var label = ""     // header title; defaults to the host name
    var refreshSeconds = 60.0
    var slowRefreshSeconds = 300.0     // fair-share (sshare), CLUSTER (sinfo) and history (sacct) change slowly
    var pauseWhenLocked = true         // no polling while the screen is locked, the displays sleep or another user is active
    var maxRows = 8
    var historyHours = 12
    var showCluster = true
    var showHistory = true
    var extraSSHOptions: [String] = []
    var groupJobs = true               // fold jobs whose names differ only by a number / trailing letter into one row
    var groupRules: [GroupRule] = []   // explicit groups, checked first: [{"match": "<regex on the job name>", "label": "..."}]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? d.label
        refreshSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? d.refreshSeconds
        slowRefreshSeconds = try c.decodeIfPresent(Double.self, forKey: .slowRefreshSeconds) ?? d.slowRefreshSeconds
        pauseWhenLocked = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenLocked) ?? d.pauseWhenLocked
        maxRows = try c.decodeIfPresent(Int.self, forKey: .maxRows) ?? d.maxRows
        historyHours = try c.decodeIfPresent(Int.self, forKey: .historyHours) ?? d.historyHours
        showCluster = try c.decodeIfPresent(Bool.self, forKey: .showCluster) ?? d.showCluster
        showHistory = try c.decodeIfPresent(Bool.self, forKey: .showHistory) ?? d.showHistory
        extraSSHOptions = try c.decodeIfPresent([String].self, forKey: .extraSSHOptions) ?? d.extraSSHOptions
        groupJobs = try c.decodeIfPresent(Bool.self, forKey: .groupJobs) ?? d.groupJobs
        groupRules = try c.decodeIfPresent([GroupRule].self, forKey: .groupRules) ?? d.groupRules
    }

    /// Keep numbers in sane ranges so no view or query can be fed nonsense.
    mutating func clamp() {
        refreshSeconds = refreshSeconds.isFinite ? min(max(refreshSeconds, 10), 3600) : 60
        slowRefreshSeconds = slowRefreshSeconds.isFinite ? min(max(slowRefreshSeconds, 10), 3600) : 300
        maxRows = min(max(maxRows, 1), 50)
        historyHours = min(max(historyHours, 1), 24 * 14)
    }

    /// What ssh actually connects to: the host plus the options that can change user, port or destination.
    var target: String { ([host] + extraSSHOptions).joined(separator: "\u{1}") }

    /// A host that ssh could read as an option (or that isn't a single word) is refused outright.
    var displayLabel: String { label.isEmpty ? (host.isEmpty ? "SLURM" : host).uppercased() : label }

    var problem: String? {
        if host.isEmpty { return "config: set \"host\" to a Host alias from ~/.ssh/config, then Reload" }
        if host.hasPrefix("-") { return "config: host must not start with '-'" }
        if host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return "config: host must not contain spaces or control characters"
        }
        return nil
    }

    static var dir: URL {
        if let p = ProcessInfo.processInfo.environment["SLURMHUD_CONFIG_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/slurm-hud", isDirectory: true)
    }
    static var file: URL { dir.appendingPathComponent("config.json") }

    /// One config per server, each with a message when it can't be used. A broken file is never overwritten.
    /// Without a `servers` list the file describes one server. With one, every entry is merged over the
    /// top-level keys, so shared settings are written once: `{"refreshSeconds": 60, "servers": [{"host": "a"}, {"host": "b"}]}`.
    static func loadAll() -> [(Config, String?)] {
        guard let data = try? Data(contentsOf: file) else {
            let c = Config()
            c.save()
            return [(c, c.problem)]
        }
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [(Config(), "config: config.json is not valid JSON")]
        }
        guard let raw = top["servers"] else { return [decode(data, "config.json is not valid JSON")] }
        guard let list = raw as? [Any] else { return [(Config(), "config: \"servers\" must be a list of objects")] }
        if list.isEmpty { return [decode(data, "config.json is not valid JSON")] }
        var base = top
        base.removeValue(forKey: "servers")
        return list.enumerated().map { i, e in
            guard let o = e as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: base.merging(o) { $1 }) else {
                return (Config(), "config: servers[\(i)] must be an object")
            }
            return decode(d, "servers[\(i)] has a value of the wrong type")
        }
    }

    private static func decode(_ data: Data, _ err: String) -> (Config, String?) {
        guard var c = try? JSONDecoder().decode(Config.self, from: data) else { return (Config(), "config: " + err) }
        c.clamp()
        return (c, c.problem)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Config.file)
    }
}

// MARK: - Model

struct Job: Identifiable, Equatable {
    let id: String              // JobArrayID: 123, 123_4, or a collapsed pending array like 123_[0-9%2]
    let partition: String
    let name: String
    let st: String              // compact state: R, PD, CG, ...
    let elapsed: Int
    let limit: Int?
    let nodes: Int
    let tasks: Int              // > 1 only for a collapsed pending array
    let gpuByType: [String: Int] // per task
    let place: String           // node list when running, reason when pending
    let start: Date?            // actual start, or Slurm's estimate when pending

    var gpus: Int { gpuByType.values.reduce(0, +) * tasks }
    var isRunning: Bool { st == "R" || st == "CG" || st == "CF" }
    var isPending: Bool { st == "PD" }
}

struct ShareRow: Equatable { let account: String; let fairShare: Double?; let levelFS: Double? }
struct Pool: Identifiable, Equatable { let id: String; var total = 0; var used = 0; var free = 0 }
struct Failure: Identifiable, Equatable { let id: String; let name: String; let state: String }
struct Hist: Equatable { var ok = 0, fail = 0, timeout = 0, cancel = 0; var failures: [Failure] = [] }
struct TypeCount: Identifiable, Equatable { let id: String; let n: Int }
struct Sample: Equatable { let t: Date; let v: Int }

struct Snapshot: Equatable {
    var node = "", user = ""
    var jobs: [Job] = []
    var shares: [ShareRow] = []
    var acctLFS: [String: Double] = [:]
    var pools: [Pool] = []
    var hist = Hist()
    var serverNow = Date()
    var fetched = Date()
    var unavailable: Set<String> = []   // sections whose query failed this round and had nothing to fall back on
    var stale: Set<String> = []         // sections carried over from an earlier round because the query failed

    var running: [Job] { jobs.filter(\.isRunning) }
    var pending: [Job] {
        jobs.filter(\.isPending).sorted { ($0.start ?? .distantFuture, $0.id) < ($1.start ?? .distantFuture, $1.id) }
    }
    var gpuRun: Int { running.reduce(0) { $0 + $1.gpus } }
    var gpuPend: Int { pending.reduce(0) { $0 + $1.gpus } }
    var pendingTasks: Int { pending.reduce(0) { $0 + $1.tasks } }

    static func group(_ js: [Job]) -> [TypeCount] {
        var d: [String: Int] = [:]
        for j in js { for (t, n) in j.gpuByType where n > 0 { d[t, default: 0] += n * j.tasks } }
        return d.map { TypeCount(id: $0.key, n: $0.value) }.sorted { $0.n != $1.n ? $0.n > $1.n : $0.id < $1.id }
    }
}

// MARK: - Grouping

/// One HUD row: a single job, or several jobs that a rule put together.
struct JobGroup: Identifiable, Equatable {
    let id: String
    let label: String
    let jobs: [Job]

    var tasks: Int { jobs.reduce(0) { $0 + $1.tasks } }
    var gpus: Int { jobs.reduce(0) { $0 + $1.gpus } }
    var gpuTotals: [String: Int] {
        var d: [String: Int] = [:]
        for j in jobs { for (t, n) in j.gpuByType where n > 0 { d[t, default: 0] += n * j.tasks } }
        return d
    }
}

enum Grouper {
    // A number field: an integer, a decimal or scientific notation, so `lr1e-4` and `lr0.003` are one field each.
    private static let number = try! NSRegularExpression(pattern: "[0-9]+(?:\\.[0-9]+)?(?:[eE][-+]?[0-9]+)?")
    private static var cache: [String: NSRegularExpression?] = [:]   // main thread only

    /// A name split into fixed text and variable fields: `name == text[0] + field[0] + text[1] + … + text.last`.
    /// The fields are the numbers plus a trailing one-letter token (`ablate_a`), whose text before it ends in `_`, `-` or `.`.
    struct Parts: Equatable {
        var text: [String]
        var field: [String]
    }

    static func parts(_ name: String) -> Parts {
        let ns = name as NSString
        var p = Parts(text: [], field: [])
        var at = 0
        for m in number.matches(in: name, range: NSRange(location: 0, length: ns.length)) {
            p.text.append(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            p.field.append(ns.substring(with: m.range))
            at = m.range.location + m.range.length
        }
        var tail = ns.substring(from: at)
        let c = Array(tail)
        if name.count >= 3, c.count >= 2, c[c.count - 1].isLetter, "_-.".contains(c[c.count - 2]) {
            p.text.append(String(c.dropLast()))
            p.field.append(String(c[c.count - 1]))
            tail = ""
        }
        p.text.append(tail)
        return p
    }

    /// Automatic rule, step 1: names whose fixed text is the same are candidates (`eval_s0`/`eval_s1`, `ablate_a`/`ablate_b`).
    static func stem(_ name: String) -> String { parts(name).text.joined(separator: "\u{1}") }

    /// Step 2, inside one stem: only names that differ in a single field share a row, so two configs that happen to have
    /// the same shape (`a576_s3000_k2`, `a256_s7000_k0`) stay apart. The field that merges the most jobs is chosen
    /// (the rightmost on a tie); the jobs it leaves unmerged (a lone name, or only copies of one name)
    /// get another try with the remaining fields.
    static func split(_ jobs: [Job]) -> [[Job]] {
        let fs = jobs.map { parts($0.name).field }
        let n = fs.first?.count ?? 0
        guard jobs.count > 1, n > 0 else { return [jobs] }
        func key(_ i: Int, _ k: Int) -> [String] { var f = fs[i]; f[k] = "\u{1}"; return f }
        var best = 0, bestCount = Int.max
        for k in 0..<n {
            let c = Set(jobs.indices.map { key($0, k) }).count
            if c <= bestCount { best = k; bestCount = c }
        }
        var order: [[String]] = []
        var buckets: [[String]: [Int]] = [:]
        for i in jobs.indices {
            let kk = key(i, best)
            if buckets[kk] == nil { order.append(kk) }
            buckets[kk, default: []].append(i)
        }
        let groups = order.map { buckets[$0]! }
        func merged(_ g: [Int]) -> Bool { Set(g.map { fs[$0] }).count > 1 }
        let alone = groups.filter { !merged($0) }.flatMap { $0 }
        guard Set(alone.map { fs[$0] }).count > 1, alone.count < jobs.count else { return groups.map { $0.map { jobs[$0] } } }
        let rest = split(alone.map { jobs[$0] })
        var out: [[Job]] = groups.filter(merged).map { $0.map { jobs[$0] } } + rest
        let pos = Dictionary(jobs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        out.sort { pos[$0[0].id]! < pos[$1[0].id]! }
        return out
    }

    /// Names with the same shape keep every field they agree on and show `*` for the others (`a576_s3000_k*_r0`).
    /// Anything else (a rule's group) falls back to common prefix + "*" + common suffix, never cutting through a number.
    static func label(_ names: [String]) -> String {
        var seen = Set<String>()
        let uniq = names.filter { seen.insert($0).inserted }
        guard uniq.count > 1 else { return names.first ?? "" }
        let ps = uniq.map(parts)
        if ps.allSatisfy({ $0.text == ps[0].text }) {
            var s = ""
            for (i, t) in ps[0].text.enumerated() {
                s += t
                if i < ps[0].field.count { s += ps.allSatisfy({ $0.field[i] == ps[0].field[i] }) ? ps[0].field[i] : "*" }
            }
            return s
        }
        let u = uniq.map(Array.init)
        let a = u[0]
        let minLen = u.map(\.count).min() ?? 0
        var p = 0
        while p < minLen, u.allSatisfy({ $0[p] == a[p] }) { p += 1 }
        while p > 0, a[p - 1].isNumber { p -= 1 }
        var q = 0
        while q < minLen - p, u.allSatisfy({ $0[$0.count - 1 - q] == a[a.count - 1 - q] }) { q += 1 }
        while q > 0, a[a.count - q].isNumber { q -= 1 }
        return String(a[..<p]) + "*" + String(a[(a.count - q)...])
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let hit = cache[pattern] { return hit }
        let r = try? NSRegularExpression(pattern: pattern)   // a bad pattern is skipped, not fatal
        cache[pattern] = r
        return r
    }

    /// Keeps the order of first appearance. Config rules win over the automatic stem; first matching rule wins.
    static func group(_ jobs: [Job], rules: [GroupRule] = [], enabled: Bool = true) -> [JobGroup] {
        guard enabled else { return jobs.map { JobGroup(id: $0.id, label: $0.name, jobs: [$0]) } }
        var order: [String] = []
        var buckets: [String: [Job]] = [:]
        var fixed: [String: String] = [:]
        for j in jobs {
            var key = "auto:" + stem(j.name)
            for (i, r) in rules.enumerated() {
                guard let m = r.match, !m.isEmpty, let re = regex(m),
                      re.firstMatch(in: j.name, range: NSRange(j.name.startIndex..., in: j.name)) != nil else { continue }
                key = "rule:\(i)"
                if let l = r.label, !l.isEmpty { fixed[key] = l }
                break
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(j)
        }
        // Split the automatic buckets, then put every row back at its first job's position.
        let pos = Dictionary(jobs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [JobGroup] = []
        for k in order {
            let js = buckets[k] ?? []
            if k.hasPrefix("rule:") {
                rows.append(JobGroup(id: k, label: fixed[k] ?? label(js.map(\.name)), jobs: js))
            } else {
                for part in split(js) {
                    let l = label(part.map(\.name))
                    rows.append(JobGroup(id: "auto:\(l)#\(part[0].id)", label: l, jobs: part))   // a job may be named like a label
                }
            }
        }
        return rows.sorted { (pos[$0.jobs[0].id] ?? 0) < (pos[$1.jobs[0].id] ?? 0) }
    }
}

// MARK: - Remote probe (one ssh round trip)

enum Remote {
    // Every section reports failure as "@@NA <SECTION>" instead of pretending to be empty.
    // `sq` strips the column padding of -O output (~150 KB -> ~11 KB per round on a ~200-node cluster).
    // Names go in the last column so a '|' inside a name can be re-joined by the parser.
    static let script = #"""
    H=__HOURS__; WANT_SHARE=__SHARE__; WANT_NODES=__NODES__; WANT_HIST=__HIST__
    export SLURM_TIME_FORMAT=%s
    sq() { sed -E 's/ +\|/|/g'; }
    command -v squeue >/dev/null 2>&1 || { echo "@@ERR slurm commands not found in PATH"; exit 0; }
    echo "@@HOST $(hostname -s)|$USER"
    echo "@@NOW $(date +%s)"
    echo "@@ENV ${SLURM_CONF:-}|$(dirname "$(command -v squeue)")"
    J=$(squeue -u "$USER" -h -O "JobArrayID:60|,Partition:120|,StateCompact:8|,TimeUsed:20|,TimeLimit:20|,NumNodes:8|,tres-alloc:300|,ReasonList:300|,StartTime:24|,tres-per-node:120|,Name:300|" 2>&1) || { echo "@@ERR $(printf '%s' "$J" | tail -n 1)"; exit 0; }
    echo "@@JOBS"
    [ -n "$J" ] && printf '%s\n' "$J" | sq
    if [ "$WANT_SHARE" = 1 ]; then
      if U=$(sshare -nP -U -u "$USER" -o Account,User,FairShare,LevelFS 2>/dev/null); then
        echo "@@SHARE"
        [ -n "$U" ] && printf '%s\n' "$U"
        A=$(printf '%s\n' "$U" | cut -d'|' -f1 | sed 's/^ *//' | grep -v '^$' | sort -u | paste -sd, -)
        [ -n "$A" ] && sshare -nP -A "$A" -o Account,User,FairShare,LevelFS 2>/dev/null | awk -F'|' '$1 !~ /^ / && $2 == "" {print "ACCT|"$0}'
      else
        echo "@@NA SHARE"
      fi
    fi
    if [ "$WANT_NODES" = 1 ]; then
      if N=$(sinfo -h -N -O "NodeHost:80|,Gres:300|,GresUsed:300|,StateCompact:20|" 2>/dev/null); then
        echo "@@NODES"
        printf '%s\n' "$N" | sq | sort -u
      else
        echo "@@NA NODES"
      fi
    fi
    if [ "$WANT_HIST" = 1 ]; then
      if S=$(sacct -u "$USER" -X -n -P -S "now-${H}hours" -o JobID,State,End,JobName 2>/dev/null); then
        echo "@@HIST"
        printf '%s\n' "$S" | awk -F'|' '
          $2 ~ /^COMPLETED/ {ok++}
          $2 ~ /^CANCELLED/ {ca++}
          $2 ~ /^TIMEOUT/ {to++}
          $2 ~ /^(FAILED|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|PREEMPTED|DEADLINE)/ {fa++}
          END {printf "COUNT|%d|%d|%d|%d\n", ok, fa, to, ca}'
        printf '%s\n' "$S" | awk -F'|' '$2 ~ /^(FAILED|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|PREEMPTED|DEADLINE|TIMEOUT)/ {print "FAIL|"$0}' \
          | sort -t'|' -k4,4nr | head -n 3
      else
        echo "@@NA HIST"
      fi
    fi
    echo "@@END"
    """#

    /// `slow: false` leaves out the fair-share, node and history queries; the Store keeps showing their last result.
    static func render(_ c: Config, slow: Bool = true) -> String {
        script
            .replacingOccurrences(of: "__HOURS__", with: String(c.historyHours))
            .replacingOccurrences(of: "__SHARE__", with: slow ? "1" : "0")
            .replacingOccurrences(of: "__NODES__", with: c.showCluster && slow ? "1" : "0")
            .replacingOccurrences(of: "__HIST__", with: c.showHistory && slow ? "1" : "0")
    }
}

// MARK: - Formatting

enum Fmt {
    static func dur(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let first = s.first, first.isNumber else { return nil }   // UNLIMITED, INVALID, N/A
        var days = 0
        var rest = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            days = Int(s[..<dash]) ?? 0
            rest = s[s.index(after: dash)...]
        }
        let p = rest.split(separator: ":").compactMap { Int($0) }
        let secs: Int
        switch p.count {
        case 3: secs = p[0] * 3600 + p[1] * 60 + p[2]
        case 2: secs = days > 0 ? p[0] * 3600 + p[1] * 60 : p[0] * 60 + p[1]
        case 1: secs = days > 0 ? p[0] * 3600 : p[0] * 60
        default: return nil
        }
        return days * 86400 + secs
    }

    static func hm(_ s: Int?) -> String {
        guard let s else { return "∞" }
        if s >= 86400 {
            let d = s / 86400, h = (s % 86400) / 3600
            return h == 0 ? "\(d)d" : "\(d)d\(h)h"
        }
        return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
    }

    static func eta(_ d: Date?, now: Date) -> String {
        guard let d else { return "—" }
        let s = Int(d.timeIntervalSince(now))
        if s <= 60 { return "soon" }
        if s < 3600 { return "~\(s / 60)m" }
        if s < 86400 { return "~\(s / 3600)h" }
        return "~\(s / 86400)d\((s % 86400) / 3600)h"
    }

    static func num(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v.isInfinite { return "∞" }
        if v >= 1000 { return String(format: "%.0f", v) }
        return String(format: "%.3f", v)
    }

    private static let clockFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    static func clock(_ d: Date) -> String { clockFmt.string(from: d) }

    static func reason(_ r: String) -> String {
        let x = r.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        let map: [(String, String)] = [
            ("Priority", "PRIORITY"), ("Resources", "RESOURCES"), ("DependencyNeverSatisfied", "DEP FAIL"),
            ("Dependency", "DEPEND"), ("ReqNodeNotAvail", "NODE N/A"), ("Nodes required", "NODES DOWN"),
            ("QOSMax", "QOS LIMIT"), ("QOSGrp", "QOS LIMIT"), ("AssocGrp", "GRP LIMIT"), ("AssocMax", "ACCT LIMIT"),
            ("BeginTime", "BEGIN"), ("JobHeld", "HELD"), ("Reservation", "RESV"), ("PartitionTimeLimit", "TIME LIMIT"),
            ("launch failed", "LAUNCH FAIL"), ("BadConstraints", "BAD CONSTR"),
        ]
        for (k, v) in map where x.hasPrefix(k) { return v }
        return String(x.uppercased().prefix(10))
    }
}

// MARK: - Parsing

enum Parser {
    struct Out { var err: String?; var env: String?; var snap: Snapshot? }

    /// `gpu:[type:]count`, where type may start with a digit (e.g. gpu:2060:8) and count must end the token.
    static let gpuRE = try! NSRegularExpression(pattern: #"gpu:(?:([^:,()\s=|]+):)?(\d+)(?=$|[,()\s|])"#)

    static func gpuMatches<S: StringProtocol>(_ s: S) -> [(String, Int)] {
        let str = String(s)
        let ns = str as NSString
        return gpuRE.matches(in: str, range: NSRange(location: 0, length: ns.length)).map { m in
            let t = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : "gpu"
            return (t.lowercased(), Int(ns.substring(with: m.range(at: 2))) ?? 0)
        }
    }

    static func fields<S: StringProtocol>(_ line: S) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Number of tasks in a collapsed array id like `123_[0-9%2]`, `123_[1,3,5-7]`, `123_[0-99:2]`.
    static func arrayTasks(_ id: String) -> Int {
        guard let open = id.firstIndex(of: "["), let close = id.lastIndex(of: "]"), open < close else { return 1 }
        var spec = id[id.index(after: open)..<close]
        if let pct = spec.firstIndex(of: "%") { spec = spec[..<pct] }
        var n = 0
        for part in spec.split(separator: ",") {
            let stepParts = part.split(separator: ":")
            let step = stepParts.count > 1 ? max(1, Int(stepParts[1]) ?? 1) : 1
            let r = stepParts.first?.split(separator: "-") ?? []
            if r.count == 2, let a = Int(r[0]), let b = Int(r[1]), b >= a {
                n += (b - a) / step + 1
            } else if r.count == 1, Int(r[0]) != nil {
                n += 1
            }
        }
        return max(1, n)
    }

    static func parse(_ text: String) -> Out {
        var out = Out()
        var s = Snapshot()
        var sec = ""
        var ended = false
        var jobL: [Substring] = [], shareL: [Substring] = [], nodeL: [Substring] = [], histL: [Substring] = []

        for line in text.split(separator: "\n") {
            if line.hasPrefix("@@") {
                let body = line.dropFirst(2)
                let tag = String(body.prefix { $0 != " " })
                let rest = body.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
                switch tag {
                case "ERR":
                    out.err = rest.isEmpty ? "remote error" : rest
                    return out
                case "HOST":
                    let f = rest.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    s.node = f.first ?? ""
                    s.user = f.count > 1 ? f[1] : ""
                case "NOW":
                    if let e = Double(rest.split(separator: " ").first ?? "") { s.serverNow = Date(timeIntervalSince1970: e) }
                case "ENV":
                    out.env = rest
                case "NA":
                    s.unavailable.insert(rest)
                    sec = ""
                case "END":
                    ended = true
                    sec = ""
                default:
                    sec = tag
                }
                continue
            }
            switch sec {
            case "JOBS": jobL.append(line)
            case "SHARE": shareL.append(line)
            case "NODES": nodeL.append(line)
            case "HIST": histL.append(line)
            default: break   // login banners etc.
            }
        }
        guard ended else { out.err = "incomplete response from server"; return out }

        s.jobs = jobL.compactMap(job)

        for l in shareL {
            let f = fields(l)
            if f.first == "ACCT" {
                if f.count >= 5 { s.acctLFS[f[1]] = Double(f[4]) }
            } else if f.count >= 4, !f[1].isEmpty {
                s.shares.append(ShareRow(account: f[0], fairShare: Double(f[2]), levelFS: Double(f[3])))
            }
        }

        s.pools = pools(nodeL)
        s.hist = hist(histL)
        out.snap = s
        return out
    }

    static func job(_ line: Substring) -> Job? {
        var f = fields(line)
        if f.last == "" { f.removeLast() }      // trailing column suffix
        guard f.count >= 11, let c = f[0].first, c.isNumber else { return nil }
        let nodes = max(1, Int(f[5]) ?? 1)

        var byType: [String: Int] = [:]
        var total = 0
        for kv in f[6].split(separator: ",") {
            if kv.hasPrefix("gres/gpu=") {
                total = Int(kv.dropFirst(9)) ?? 0
            } else if kv.hasPrefix("gres/gpu:"), let eq = kv.firstIndex(of: "=") {
                let t = String(kv[kv.index(kv.startIndex, offsetBy: 9)..<eq]).lowercased()
                let n = Int(kv[kv.index(after: eq)...]) ?? 0
                if n > 0 { byType[t, default: 0] += n }
            }
        }
        let perNode = gpuMatches(f[9]).filter { $0.1 > 0 }
        if total == 0 && byType.isEmpty {
            for (t, n) in perNode { byType[t, default: 0] += n * nodes }
        } else if byType.isEmpty {
            let named = perNode.count == 1 && perNode[0].0 != "gpu" ? perNode[0].0 : "gpu"
            byType[named] = total
        } else {
            let typed = byType.values.reduce(0, +)
            if total > typed { byType["gpu", default: 0] += total - typed }
        }

        let start = Double(f[8]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return Job(id: f[0], partition: f[1], name: f[10...].joined(separator: "|"), st: f[2],
                   elapsed: Fmt.dur(f[3]) ?? 0, limit: Fmt.dur(f[4]), nodes: nodes,
                   tasks: arrayTasks(f[0]), gpuByType: byType,
                   place: f[7].trimmingCharacters(in: CharacterSet(charactersIn: "()")),
                   start: start)
    }

    /// Free GPUs count only on nodes the scheduler can place new work on.
    static func pools(_ lines: [Substring]) -> [Pool] {
        let usableBase: Set<String> = ["idle", "mix", "alloc", "comp", "plnd"]
        let blockingFlags = Set("*$@^%!")   // not responding, maint, reboot pending/issued, powering down
        var pools: [String: Pool] = [:]
        var seen = Set<String>()
        for l in lines {
            let f = fields(l)
            guard f.count >= 4, !f[0].isEmpty, seen.insert(f[0]).inserted else { continue }
            let raw = f[3].lowercased()
            let base = String(raw.prefix { $0.isLetter })
            let usable = usableBase.contains(base) && !raw.contains(where: blockingFlags.contains)
            let used = Dictionary(gpuMatches(f[2]), uniquingKeysWith: +)
            for (t, n) in gpuMatches(f[1]) where n > 0 {
                var p = pools[t] ?? Pool(id: t)
                let u = min(used[t] ?? 0, n)
                p.total += n
                p.used += u
                if usable { p.free += n - u }
                pools[t] = p
            }
        }
        return pools.values.sorted { $0.id < $1.id }
    }

    static func hist(_ lines: [Substring]) -> Hist {
        var h = Hist()
        var seen = Set<String>()
        for l in lines {
            let f = fields(l)
            if f.first == "COUNT", f.count >= 5 {
                h.ok = Int(f[1]) ?? 0; h.fail = Int(f[2]) ?? 0; h.timeout = Int(f[3]) ?? 0; h.cancel = Int(f[4]) ?? 0
            } else if f.first == "FAIL", f.count >= 5, seen.insert(f[1]).inserted {
                let st = f[2].uppercased()
                let short = st.hasPrefix("OUT_OF") ? "OOM" : String(st.split(separator: " ").first ?? "")
                h.failures.append(Failure(id: f[1], name: f[4...].joined(separator: "|"), state: short))
            }
        }
        return h
    }

    /// Deterministic text dump, used by `SlurmHUD --parse <file>` and Tests/run.sh.
    static func describe(_ o: Out) -> String {
        var r: [String] = []
        if let e = o.err { r.append("err: \(e)") }
        guard let s = o.snap else { return r.joined(separator: "\n") }
        r.append("host: \(s.node)|\(s.user)")
        for j in s.jobs.sorted(by: { $0.id < $1.id }) {
            let types = j.gpuByType.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            r.append("job \(j.id) st=\(j.st) tasks=\(j.tasks) gpus=\(j.gpus) types=[\(types)] start=\(j.start.map { String(Int($0.timeIntervalSince1970)) } ?? "-") name=\(j.name)")
        }
        for x in s.shares { r.append("share \(x.account) fs=\(Fmt.num(x.fairShare)) lfs=\(Fmt.num(x.levelFS))") }
        for (k, v) in s.acctLFS.sorted(by: { $0.key < $1.key }) { r.append("acct \(k) lfs=\(Fmt.num(v))") }
        for p in s.pools { r.append("pool \(p.id) total=\(p.total) used=\(p.used) free=\(p.free)") }
        r.append("hist ok=\(s.hist.ok) fail=\(s.hist.fail) timeout=\(s.hist.timeout) cancel=\(s.hist.cancel)")
        for f in s.hist.failures { r.append("failure \(f.id) \(f.state) \(f.name)") }
        for g in Grouper.group(s.running) + Grouper.group(s.pending) where g.jobs.count > 1 {
            r.append("group \(g.label) n=\(g.jobs.count) gpus=\(g.gpus) ids=\(g.jobs.map(\.id).joined(separator: ","))")
        }
        r.append("unavailable: \(s.unavailable.sorted().joined(separator: ","))")
        r.append("totals gpuRun=\(s.gpuRun) gpuPend=\(s.gpuPend) pendingTasks=\(s.pendingTasks)")
        return r.joined(separator: "\n")
    }
}

// MARK: - SSH

func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

enum SSH {
    struct Result { var status: Int32 = -1; var out = ""; var err = ""; var timedOut = false }

    final class Flag {
        private let lock = NSLock()
        private var v = false
        func set() { lock.lock(); v = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    static func run(_ args: [String], stdin: String?, timeout: Double) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        let o = Pipe(), e = Pipe(), i = Pipe()
        p.standardOutput = o
        p.standardError = e
        p.standardInput = i
        var r = Result()
        do { try p.run() } catch { r.err = error.localizedDescription; return r }
        if let stdin { try? i.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
        try? i.fileHandleForWriting.close()

        let timed = Flag()
        let killer = DispatchWorkItem { if p.isRunning { timed.set(); p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = o.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        killer.cancel()

        r.status = p.terminationStatus
        r.out = String(decoding: outData, as: UTF8.self)
        r.err = String(decoding: errData, as: UTF8.self)
        r.timedOut = timed.value
        return r
    }

    /// Fully expanded ControlPath for the host (our own if ~/.ssh/config gives none), or nil if ssh -G fails.
    /// Passing it expanded keeps the socket path stable even when we override ProxyCommand below.
    static func controlPath(_ c: Config) -> String? {
        func query(_ pre: [String]) -> String? {
            let r = run(pre + c.extraSSHOptions + ["-G", "--", c.host], stdin: nil, timeout: 5)
            guard r.status == 0 else { return nil }
            for line in r.out.split(separator: "\n") where line.hasPrefix("controlpath ") { return String(line.dropFirst(12)) }
            return "none"
        }
        guard let cp = query([]) else { return nil }
        if cp != "none" { return cp }
        if let own = query(["-o", "ControlPath=~/.ssh/slurmhud-%C"]), own != "none" { return own }
        return nil
    }

    /// Transport options shared by every ssh call (fetch, socket check, reconnect).
    static func base(_ c: Config, _ cp: String?) -> [String] {
        (cp.map { ["-o", "ControlPath=\($0)"] } ?? []) + c.extraSSHOptions
    }

    /// masterOnly: the master socket was up a moment ago. ProxyCommand=false makes sure that if it vanished,
    /// ssh fails locally instead of silently falling back to a direct (MFA) login.
    static func fetchArgs(_ c: Config, _ cp: String?, masterOnly: Bool) -> [String] {
        var a = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ControlMaster=no",
                 "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "-o", "LogLevel=ERROR"]
        if masterOnly { a += ["-o", "ProxyCommand=/usr/bin/false"] }
        return a + base(c, cp)
    }

    static func masterUp(_ c: Config, _ cp: String?) -> Bool {
        guard let cp else { return false }
        // No socket file means no master: skip spawning ssh. A file that exists still has to pass the real check.
        if !FileManager.default.fileExists(atPath: (cp as NSString).expandingTildeInPath) { return false }
        return run(["-o", "LogLevel=QUIET"] + base(c, cp) + ["-O", "check", "--", c.host], stdin: nil, timeout: 5).status == 0
    }

    /// Failures that never reached sshd's auth stage, so retrying cannot trip a login ban.
    static func isNetworkError(_ e: String) -> Bool {
        let s = e.lowercased()
        return ["timed out", "could not resolve", "nodename nor servname", "name or service not known",
                "network is unreachable", "no route to host", "connection refused"].contains { s.contains($0) }
    }
}

// MARK: - Store / poller

/// Per-server UI settings in UserDefaults, stored as `<key>.<id>`. The first server also reads the
/// pre-multi-server keys (`hud.x`, `compact`, …) until it has its own, so an upgrade keeps the old window.
struct Prefs {
    let id: String
    let legacy: Bool
    private var d: UserDefaults { .standard }
    func object(_ k: String) -> Any? { d.object(forKey: "\(k).\(id)") ?? (legacy ? d.object(forKey: k) : nil) }
    func bool(_ k: String) -> Bool { object(k) as? Bool ?? false }
    func double(_ k: String) -> Double? { (object(k) as? NSNumber)?.doubleValue }
    func string(_ k: String) -> String? { object(k) as? String }
    func set(_ v: Any, _ k: String) { d.set(v, forKey: "\(k).\(id)") }
}

/// Direct (non-master) logins are rationed per ssh target across all windows, so two entries for the same
/// host (or a window being replaced on reload while its fetch is still out) never knock twice:
/// at most one direct attempt at a time, and none after one failed until the user reloads the config.
enum DirectGate {
    enum Verdict { case go, busy, failed }
    private static let lock = NSLock()
    private static var busy = Set<String>()
    private static var failed = Set<String>()

    static func begin(_ t: String) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        if failed.contains(t) { return .failed }
        if busy.contains(t) { return .busy }
        busy.insert(t)
        return .go
    }
    /// Releases the target and, in the same step, records a failure, so no other window can slip in between.
    static func end(_ t: String, failed f: Bool) {
        lock.lock()
        busy.remove(t)
        if f { failed.insert(t) }
        lock.unlock()
    }
    static func reset() { lock.lock(); failed.removeAll(); lock.unlock() }
}

final class Store: ObservableObject {
    enum Link: Equatable { case boot, live, auth, down(String), error(String), config(String) }

    @Published private(set) var snap: Snapshot?
    @Published private(set) var link: Link = .boot
    @Published private(set) var syncing = false
    @Published private(set) var spark: [Sample] = []
    @Published private(set) var compact: Bool
    @Published private(set) var cfg: Config
    private var cfgError: String?
    let prefs: Prefs
    private var stopped = false
    private var idle = false                 // screen locked / displays asleep / user switched out
    private var nextSlow = Date.distantPast  // when the slow queries are due again
    private var lastSlow = Date.distantPast  // when they last ran
    static let slowSections: Set<String> = ["SHARE", "NODES", "HIST"]
    var paused: Bool { idle && cfg.pauseWhenLocked && demoText == nil }

    private var timer: Timer?
    private var fastUntil = Date.distantPast
    private var gen = 0                 // bumps on config reload; in-flight results from older generations are dropped
    private var cp: String?
    private var cpResolved = false
    private var directFailed = false    // a direct login reached the server and failed: from now on use the master socket only
    private var backoff = 30.0          // retry delay for network-level failures of direct attempts

    init(_ c: Config, _ e: String?, prefs: Prefs) {
        cfg = c
        cfgError = e
        self.prefs = prefs
        compact = prefs.bool("compact")
    }

    func toggleCompact() {
        compact.toggle()
        prefs.set(compact, "compact")
    }

    /// The server was removed from the config: no more polling, and an in-flight result is dropped.
    func stop() {
        stopped = true
        gen += 1
        timer?.invalidate()
    }

    /// The Mac is (not) being looked at. Polling stops while paused; coming back fetches everything at once.
    func setIdle(_ v: Bool) {
        let was = paused
        idle = v
        if paused { timer?.invalidate() }
        else if was {
            nextSlow = .distantPast
            refreshSoon(1)
        }
    }

    func apply(_ c: Config, _ e: String?) {
        nextSlow = .distantPast
        cfg = c
        cfgError = e
        gen += 1
        cp = nil
        cpResolved = false
        directFailed = false
        backoff = 30
        snap = nil
        spark = []
        link = .boot
        timer?.invalidate()
        if !syncing { refresh() }   // otherwise the stale in-flight result restarts polling
    }

    /// `--demo <file>`: show a captured/synthetic probe output instead of talking to a cluster (screenshots, UI work).
    var demoText: String?

    private func applyDemo(_ text: String) {
        let p = Parser.parse(text)
        guard var sn = p.snap else { link = .error(p.err ?? "demo: could not parse"); return }
        sn.fetched = Date()
        if spark.isEmpty {   // a plausible last hour so the sparkline isn't blank
            let now = Date()
            spark = (0..<60).map { i in
                let x = Double(i) / 59
                let v = Double(sn.gpuRun) * (0.45 + 0.55 * x) + 2.5 * sin(Double(i) / 4.5)
                return Sample(t: now.addingTimeInterval(Double(i - 59) * 60), v: max(0, Int(v.rounded())))
            }
            spark[spark.count - 1] = Sample(t: now, v: sn.gpuRun)
        }
        snap = sn
        link = .live
    }

    /// `full` also runs the slow queries now (manual refresh, retry).
    func refresh(full: Bool = false) {
        if full { nextSlow = .distantPast }
        guard !syncing, !stopped, !paused else { return }
        timer?.invalidate()
        if let d = demoText { applyDemo(d); return }
        if let e = cfgError { link = .config(e); return }   // wait for Reload Config
        syncing = true
        let cfg = self.cfg, myGen = gen
        let slow = Date() >= nextSlow || snap == nil
        // The old key for a plain host; options that may point ssh elsewhere get their own cache entry.
        let envKey = "remoteEnv." + (cfg.extraSSHOptions.isEmpty ? cfg.host : cfg.target)
        let cached = UserDefaults.standard.string(forKey: envKey)
        let resolved = cpResolved, knownCP = cp, masterOnlyMode = directFailed

        DispatchQueue.global(qos: .utility).async {
            let cp = resolved ? knownCP : SSH.controlPath(cfg)
            let master = SSH.masterUp(cfg, cp)
            var r: SSH.Result?
            var parsed: Parser.Out?
            let gate: DirectGate.Verdict = master || masterOnlyMode ? .failed : DirectGate.begin(cfg.target)
            if master || gate == .go {
                var prelude = ""
                var remote = "bash -l -s"
                if let c = cached {
                    let parts = c.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    if parts.count == 2 {
                        if !parts[0].isEmpty { prelude += "export SLURM_CONF=\(shq(parts[0]))\n" }
                        if !parts[1].isEmpty && parts[1] != "." { prelude += "export PATH=\(shq(parts[1])):\"$PATH\"\n" }
                        remote = "bash -s"
                    }
                }
                let res = SSH.run(SSH.fetchArgs(cfg, cp, masterOnly: master) + ["--", cfg.host, remote],
                                  stdin: prelude + Remote.render(cfg, slow: slow), timeout: 30)
                if res.status == 0 && !res.timedOut { parsed = Parser.parse(res.out) }
                r = res
            }
            // Judged here, not on the main queue: the result may belong to a removed window or an old config,
            // and a failed login must count either way.
            if !master && gate == .go, let r { DirectGate.end(cfg.target, failed: Store.directFailure(r, parsed)) }
            DispatchQueue.main.async {
                guard myGen == self.gen else {   // config changed (or the server was removed) while we were out
                    self.syncing = false
                    self.refresh()
                    return
                }
                self.cp = cp
                self.cpResolved = true
                if !master && gate == .busy {   // another window is mid-login to this target: look again shortly
                    self.syncing = false
                    self.schedule(5)
                    return
                }
                if !master && !masterOnlyMode && gate == .failed { self.directFailed = true }   // another window's login failed
                self.finish(r, parsed, usedLogin: cached == nil, viaMaster: master, envKey: envKey, slow: slow)
            }
        }
    }

    private func finish(_ r: SSH.Result?, _ p: Parser.Out?, usedLogin: Bool, viaMaster: Bool, envKey: String, slow: Bool) {
        syncing = false
        guard let r else {   // no master socket and direct logins are off
            link = .auth
            scheduleNext()
            return
        }
        if let p, let err = p.err {
            if !usedLogin {   // cached env went stale: retry once with a login shell
                UserDefaults.standard.removeObject(forKey: envKey)
                refresh()
                return
            }
            link = .error(err)
        } else if let p, var sn = p.snap {
            if usedLogin, let env = p.env { UserDefaults.standard.set(env, forKey: envKey) }
            sn.fetched = Date()
            let now = Date()
            let soon = lastSlow.addingTimeInterval(min(60, cfg.slowRefreshSeconds))   // early runs: at most once a minute
            if slow {
                lastSlow = now
                nextSlow = now.addingTimeInterval(cfg.slowRefreshSeconds)
                // A slow query failed: try again soon, not every round.
                if !sn.unavailable.isDisjoint(with: Store.slowSections) { nextSlow = now.addingTimeInterval(min(60, cfg.slowRefreshSeconds)) }
            }
            if let old = snap {
                if !slow {
                    keepSlow(from: old, into: &sn)
                    // A job left the queue: the history and the free GPUs just changed. Array tasks count by their
                    // job ID, so a pending array that starts a task (123_[0-9] -> 123_[1-9]) is not a departure.
                    func base(_ id: String) -> Substring { id.prefix { $0 != "_" } }
                    if !Set(old.jobs.map { base($0.id) }).subtracting(sn.jobs.map { base($0.id) }).isEmpty { nextSlow = min(nextSlow, soon) }
                }
                carryOver(from: old, into: &sn)
            }
            link = .live
            backoff = 30
            addSample(sn.gpuRun)
            snap = sn
            fastUntil = .distantPast
        } else {
            let msg = r.err.split(separator: "\n").last.map(String.init) ?? ""
            if r.timedOut {
                if !viaMaster { directFailed = true }   // it connected but hung: don't knock again
                link = .down("ssh timed out after 30s")
            } else if viaMaster {
                link = .down("ssh link dropped")      // the next round re-checks the socket
            } else if SSH.isNetworkError(r.err) {
                backoff = min(backoff * 2, 900)
                link = .down(msg.isEmpty ? "network unreachable" : msg)
            } else {
                directFailed = true
                let e = r.err.lowercased()
                if e.contains("permission denied") || e.contains("keyboard-interactive") || e.contains("authentication") {
                    link = .auth
                } else {
                    link = .down(msg.isEmpty ? "ssh exited with status \(r.status)" : msg)
                }
            }
        }
        scheduleNext()
    }

    /// A direct login that must not be repeated: it hung, or it reached the server and failed for a reason other
    /// than the network. Mirrors the branches of `finish` that set `directFailed`.
    static func directFailure(_ r: SSH.Result, _ p: Parser.Out?) -> Bool {
        if r.timedOut { return true }
        if let p, p.err != nil || p.snap != nil { return false }
        return !SSH.isNetworkError(r.err)
    }

    /// A round without the slow queries shows their last result as it was (fresh, stale or unavailable).
    private func keepSlow(from old: Snapshot, into sn: inout Snapshot) {
        sn.shares = old.shares
        sn.acctLFS = old.acctLFS
        sn.pools = old.pools
        sn.hist = old.hist
        for k in Store.slowSections {
            if old.stale.contains(k) { sn.stale.insert(k) }
            if old.unavailable.contains(k) { sn.unavailable.insert(k) }
        }
    }

    /// Keep showing the last good data for a section whose query failed this round, marked stale.
    private func carryOver(from old: Snapshot, into sn: inout Snapshot) {
        if sn.unavailable.contains("SHARE"), !old.shares.isEmpty {
            sn.shares = old.shares; sn.acctLFS = old.acctLFS
            sn.unavailable.remove("SHARE"); sn.stale.insert("SHARE")
        }
        if sn.unavailable.contains("NODES"), !old.pools.isEmpty {
            sn.pools = old.pools
            sn.unavailable.remove("NODES"); sn.stale.insert("NODES")
        }
        if sn.unavailable.contains("HIST"), !old.unavailable.contains("HIST") {
            sn.hist = old.hist
            sn.unavailable.remove("HIST"); sn.stale.insert("HIST")
        }
    }

    private func addSample(_ v: Int) {
        let now = Date()
        if let last = spark.last, now.timeIntervalSince(last.t) < 10 { spark.removeLast() }   // manual refresh burst
        spark.append(Sample(t: now, v: v))
        let cutoff = now.addingTimeInterval(-4 * 3600)
        spark.removeAll { $0.t < cutoff }
        if spark.count > 240 { spark.removeFirst(spark.count - 240) }
    }

    private func scheduleNext() {
        timer?.invalidate()
        let fast = Date() < fastUntil
        let iv: Double
        switch link {
        case .live, .boot: iv = cfg.refreshSeconds
        case .auth: iv = fast ? 3 : 15        // local socket check only, no network
        case .down: iv = fast ? 4 : backoff
        case .error: iv = fast ? 4 : 60
        case .config: return
        }
        guard !paused else { return }   // resumed by setIdle(false)
        schedule(iv)
    }

    private func schedule(_ iv: Double) {
        timer?.invalidate()
        let t = Timer(timeInterval: iv, repeats: false) { [weak self] _ in self?.refresh() }
        t.tolerance = iv * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func wake() { refreshSoon(4) }   // give the network a moment after sleep

    /// System wake and screen unlock often arrive together: keep one pending refresh, at the later deadline.
    private var resume: DispatchWorkItem?
    private var resumeAt = Date.distantPast
    private func refreshSoon(_ delay: Double) {
        let at = max(Date().addingTimeInterval(delay), resume == nil ? .distantPast : resumeAt)
        resume?.cancel()
        timer?.invalidate()
        let w = DispatchWorkItem { [weak self] in self?.resume = nil; self?.refresh() }
        resume = w
        resumeAt = at
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow), execute: w)
    }

    /// Opens Terminal with a one-shot script that starts a persistent ssh master (you do MFA there once).
    /// Every value is passed through shq(); nothing from the config reaches the shell unquoted.
    func reconnect() {
        guard cfgError == nil else { return }
        let opts = SSH.base(cfg, cp).map(shq).joined(separator: " ")
        let h = shq(cfg.host)
        // A master that died (sleep, network change) can leave its socket behind; ssh then refuses to create a new
        // one ("already exists, disabling multiplexing") and the login opens no link. -O check just failed, so no
        // master answers on it and removing the file is safe.
        let clearStale = cp.map { "[ -S \(shq($0)) ] && rm -f -- \(shq($0))" } ?? ":"
        let body = """
        #!/bin/zsh
        clear
        printf '\\033[36m◢ SLURM-HUD\\033[0m  opening a persistent ssh link to %s\\n' \(h)
        if ssh \(opts) -O check -- \(h) 2>/dev/null; then
          printf '\\033[32m✓ link already up\\033[0m\\n'
        else
          \(clearStale)
          ssh \(opts) -fN -o ControlMaster=yes -o ControlPersist=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -- \(h) \\
            && printf '\\033[32m✓ link established. The HUD picks it up within seconds; you can close this window.\\033[0m\\n' \\
            || printf '\\033[31m✗ connection failed\\033[0m\\n'
        fi

        """
        // One script per host, so two servers reconnecting at once don't overwrite each other's.
        let safe = String(cfg.host.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        let hash = cfg.target.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }   // FNV-1a: stable across launches
        let url = Config.dir.appendingPathComponent("connect-\(safe)-\(String(hash, radix: 16)).command")
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
        fastUntil = Date().addingTimeInterval(180)
        if !syncing { scheduleNext() }
    }

    /// Menu bar summary: running GPUs and queued tasks, or what is wrong.
    var shortStatus: String {
        switch link {
        case .live, .boot:
            guard let s = snap else { return "…" }
            return s.pendingTasks > 0 ? "\(s.gpuRun) ◇\(s.pendingTasks)" : "\(s.gpuRun)"
        case .auth: return "⚠︎"
        default: return "✕"
        }
    }

    var statusText: String {
        switch link {
        case .boot: return "linking…"
        case .live: return snap.map { "synced \(Fmt.clock($0.fetched))" } ?? "live"
        case .auth: return "auth required"
        case .down(let m): return "down: \(m)"
        case .error(let m): return "error: \(m)"
        case .config(let m): return m
        }
    }

    var sparkMinutes: Int {
        guard let a = spark.first, let b = spark.last else { return 0 }
        return Int(b.t.timeIntervalSince(a.t) / 60)
    }
}

// MARK: - Theme

enum T {
    // Morandi palette: every hue is greyed down so nothing glows; state is carried by hue, not brightness.
    // Each colour has a dark-mode and a light-mode value and follows the system appearance on its own.
    typealias RGB = (Double, Double, Double)
    static func dyn(_ dark: RGB, _ light: RGB, _ alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let c = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
        })
    }
    static let cyan = dyn((0.60, 0.72, 0.78), (0.33, 0.47, 0.55))      // dusty blue
    static let chrome = dyn((0.63, 0.66, 0.69), (0.42, 0.45, 0.49))    // blue-grey
    static let green = dyn((0.64, 0.74, 0.62), (0.35, 0.49, 0.36))     // sage
    static let amber = dyn((0.84, 0.72, 0.55), (0.66, 0.47, 0.24))     // sand / ochre
    static let red = dyn((0.80, 0.55, 0.54), (0.68, 0.34, 0.34))       // dusty rose
    static let magenta = dyn((0.76, 0.60, 0.68), (0.59, 0.36, 0.48))   // mauve
    static let violet = dyn((0.66, 0.63, 0.78), (0.44, 0.40, 0.61))    // lavender grey
    static let lime = dyn((0.72, 0.73, 0.56), (0.47, 0.49, 0.26))      // olive
    private static let ink: RGB = (0.93, 0.91, 0.88)                   // warm off-white
    private static let inkLight: RGB = (0.20, 0.19, 0.18)              // warm charcoal
    static let text = dyn(ink, inkLight, 0.92)
    static let dim = dyn(ink, inkLight, 0.55)
    static let faint = dyn(ink, inkLight, 0.30)
    static let track = dyn(ink, inkLight, 0.09)                        // empty part of a meter
    static let tick = dyn((0.10, 0.10, 0.11), (0.94, 0.92, 0.89), 0.7) // meter tick marks: the panel colour
    static let border = dyn((1, 1, 1), (0, 0, 0), 0.10)
    static let bgTop = dyn((0.145, 0.140, 0.145), (0.955, 0.940, 0.915), 0.86)
    static let bgBottom = dyn((0.105, 0.100, 0.108), (0.925, 0.905, 0.880), 0.92)

    static func mono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w, design: .monospaced) }

    static func gpu(_ type: String) -> Color {
        let t = type.lowercased()
        if t.contains("h100") || t.contains("h200") || t.contains("b200") || t.contains("gh200") { return magenta }
        if t.contains("l40") { return cyan }
        if t.contains("a100") || t.contains("a40") { return violet }
        let pal = [lime, amber, violet, cyan]
        return pal[t.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % pal.count]
    }

    static func lfs(_ v: Double?) -> Color {
        guard let v else { return dim }
        return v >= 1 ? green : amber
    }
}

// MARK: - Views

let hudWidth: CGFloat = 360

struct HUDView: View {
    @ObservedObject var s: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(s: s)
            if s.link != .live && s.link != .boot { Banner(s: s) }
            if let snap = s.snap {
                Group {
                    if s.compact { CompactView(snap: snap) } else { FullView(snap: snap, s: s) }
                }
                .opacity(s.link == .live ? 1 : 0.45)
            } else if s.link == .boot {
                Text("ESTABLISHING LINK …").font(T.mono(9.5)).tracking(2).foregroundColor(T.dim)
            }
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 12)
        .frame(width: hudWidth, alignment: .leading)
        .background(Chrome())
        .contextMenu { RootMenu(s: s) }
    }
}

struct RootMenu: View {
    @ObservedObject var s: Store
    var body: some View {
        Button("Refresh Now") { s.refresh(full: true) }
        Button(s.compact ? "Expand" : "Compact") { s.toggleCompact() }
        Divider()
        let hud = AppDelegate.shared?.hud(for: s)
        Button(hud?.layer == .desktop ? "Float Above Windows" : "Pin to Desktop (behind windows)") { hud?.toggleLayer() }
        Button("Reconnect SSH…") { s.reconnect() }
        Divider()
        Button("Quit SlurmHUD") { NSApp.terminate(nil) }
    }
}

struct Chrome: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        LinearGradient(colors: [T.bgTop, T.bgBottom], startPoint: .top, endPoint: .bottom)
            .clipShape(shape)
            .overlay(shape.strokeBorder(T.border, lineWidth: 0.75))
    }
}

struct HeaderView: View {
    @ObservedObject var s: Store
    var body: some View {
        let (lc, lt): (Color, String) = {
            if s.syncing && s.link == .live { return (T.cyan, "SYNC") }
            switch s.link {
            case .boot: return (T.cyan, "BOOT")
            case .live: return (T.green, "LIVE")
            case .auth: return (T.amber, "AUTH")
            case .down: return (T.red, "DOWN")
            case .error: return (T.red, "ERR")
            case .config: return (T.red, "CFG")
            }
        }()
        HStack(spacing: 6) {
            Text("◢").font(T.mono(9)).foregroundColor(T.cyan)
            Text(s.cfg.displayLabel.uppercased()).font(T.mono(11.5, .bold)).tracking(2.6).foregroundColor(T.text)
            Text("// \(s.snap?.node ?? s.cfg.host)").font(T.mono(9.5)).foregroundColor(T.dim).lineLimit(1)
            Spacer(minLength: 4)
            Circle().fill(lc).frame(width: 5, height: 5)
            Text(lt).font(T.mono(9, .bold)).tracking(1.4).foregroundColor(lc)
            if let t = s.snap?.fetched {
                Text(Fmt.clock(t)).font(T.mono(9)).foregroundColor(T.dim)
            }
            Button(action: { s.toggleCompact() }) {
                Text(s.compact ? "▾" : "▴").font(T.mono(10)).foregroundColor(T.chrome)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct Banner: View {
    @ObservedObject var s: Store
    var body: some View {
        let (title, detail, color): (String, String, Color) = {
            switch s.link {
            case .auth: return ("AUTH REQUIRED", "no live ssh link to \(s.cfg.host); log in once (MFA)", T.amber)
            case .down(let m): return ("LINK DOWN", m, T.red)
            case .error(let m): return ("SLURM ERROR", m, T.red)
            case .config(let m): return ("CONFIG ERROR", m, T.red)
            default: return ("", "", T.dim)
            }
        }()
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(T.mono(9.5, .bold)).tracking(1.4).foregroundColor(color)
                Text(detail).font(T.mono(8.5)).foregroundColor(T.dim).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            switch s.link {
            case .config:
                Button("EDIT") { AppDelegate.shared?.editConfig() }.buttonStyle(HUDButton(color: color))
                Button("RELOAD") { AppDelegate.shared?.reloadConfig() }.buttonStyle(HUDButton(color: color))
            case .error:
                Button("RETRY") { s.refresh(full: true) }.buttonStyle(HUDButton(color: color))
            default:
                Button("RECONNECT") { s.reconnect() }.buttonStyle(HUDButton(color: color))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.45), lineWidth: 0.75))
    }
}

struct HUDButton: ButtonStyle {
    var color: Color = T.cyan
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(T.mono(9, .bold)).tracking(1.4).foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(c.isPressed ? 0.30 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.7), lineWidth: 0.75))
            .contentShape(Rectangle())
    }
}

struct SectionHead: View {
    let title: String
    var tail: String? = nil
    var color: Color = T.chrome
    var warn: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(T.mono(8.5, .semibold)).tracking(1.8).foregroundColor(color)
            if let tail { Text(tail).font(T.mono(8.5, .bold)).foregroundColor(T.text.opacity(0.8)) }
            if let warn { Text(warn).font(T.mono(7.5, .bold)).tracking(1.2).foregroundColor(T.amber) }
            Rectangle()
                .fill(LinearGradient(colors: [color.opacity(0.55), color.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 0.75)
        }
    }
}

extension Snapshot {
    /// "STALE" when showing an older round's data for this section, "N/A" when there is none.
    func warn(_ section: String) -> String? {
        if stale.contains(section) { return "STALE" }
        if unavailable.contains(section) { return "N/A" }
        return nil
    }
}

struct Meter: View {
    let frac: Double
    let color: Color
    var height: CGFloat = 3
    var ticks = true
    var body: some View {
        Canvas { ctx, sz in
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(T.track))
            let w = sz.width * CGFloat(max(0, min(1, frac.isFinite ? frac : 0)))
            if w > 0 {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: sz.height)),
                         with: .linearGradient(Gradient(colors: [color.opacity(0.35), color]),
                                               startPoint: .zero, endPoint: CGPoint(x: w, y: 0)))
            }
            if ticks {
                for i in 1..<10 {
                    ctx.fill(Path(CGRect(x: sz.width * CGFloat(i) / 10, y: 0, width: 0.75, height: sz.height)),
                             with: .color(T.tick))
                }
            }
        }
        .frame(height: height)
    }
}

struct Sparkline: View {
    let values: [Int]
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5)); base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            guard values.count > 1 else { return }
            let mx = Double(max(values.max() ?? 1, 1))
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: CGFloat(i) * step, y: size.height - 1.5 - CGFloat(Double(v) / mx) * (size.height - 4))
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.32), color.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.1)
        }
    }
}

/// One block per GPU while they fit; past 64 GPUs it switches to a proportional bar so the work stays bounded.
struct GPUBlocks: View {
    let run: [TypeCount]
    let pend: [TypeCount]
    var body: some View {
        let groups: [(String, Bool, Int)] = run.map { ($0.id, true, $0.n) } + pend.map { ($0.id, false, $0.n) }
        let total = groups.reduce(0) { $0 + $1.2 }
        Canvas { ctx, size in
            guard total > 0 else { return }
            if total <= 64 {
                let gap: CGFloat = 2
                let w = min(9, (size.width - gap * CGFloat(total - 1)) / CGFloat(total))
                let cell = { (i: Int) in CGRect(x: CGFloat(i) * (w + gap), y: 1, width: w, height: size.height - 2) }
                var i = 0
                for (t, filled, n) in groups {
                    let c = T.gpu(t)
                    if filled {
                        let first = i
                        ctx.drawLayer { l in
                            for k in 0..<n { l.fill(Path(roundedRect: cell(first + k), cornerRadius: min(1.5, w / 3)), with: .color(c)) }
                        }
                    } else {
                        for k in 0..<n {
                            ctx.stroke(Path(roundedRect: cell(i + k).insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.2),
                                       with: .color(c.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [2, 1.4]))
                        }
                    }
                    i += n
                }
            } else {
                var x: CGFloat = 0
                for (t, filled, n) in groups {
                    let w = size.width * CGFloat(n) / CGFloat(total)
                    let r = CGRect(x: x, y: 1, width: max(w - 2, 1), height: size.height - 2)
                    let c = T.gpu(t)
                    if filled {
                        ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(c))
                    } else {
                        ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5),
                                   with: .color(c.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                    x += w
                }
            }
        }
        .frame(height: 13)
        .overlay(alignment: .leading) {
            if total == 0 { Text("· · ·  NO GPU ALLOCATED").font(T.mono(8.5)).tracking(1.2).foregroundColor(T.faint) }
        }
    }
}

struct BigStat: View {
    let label: String
    let value: Int
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(T.mono(8, .medium)).tracking(1.6).foregroundColor(T.dim)
            Text("\(value)").font(T.mono(30, .light)).foregroundColor(color)
        }
    }
}

struct KV: View {
    let k: String
    let v: String
    let c: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(T.mono(7.5, .medium)).tracking(1.3).foregroundColor(T.dim)
            Text(v).font(T.mono(15, .medium)).foregroundColor(c)
        }
    }
}

struct Chip: View {
    let types: [String: Int]   // GPU type -> total count
    var body: some View {
        let total = types.values.reduce(0, +)
        let cpu = total == 0
        let single = types.count == 1 ? types.keys.first : nil
        let c = cpu ? T.dim : (single.map(T.gpu) ?? T.chrome)
        let label = cpu ? "CPU" : "\((single ?? "mix").uppercased())×\(total)"
        Text(label).font(T.mono(8.5, .bold)).foregroundColor(c)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 2.5).fill(c.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(c.opacity(0.5), lineWidth: 0.5))
            .fixedSize()
            .help(types.sorted { $0.key < $1.key }.map { "\($0.key.uppercased())×\($0.value)" }.joined(separator: " + "))
    }
}

struct JobMenu: View {
    let g: JobGroup
    var body: some View {
        let ids = g.jobs.map(\.id).joined(separator: " ")
        if g.jobs.count == 1, let j = g.jobs.first {
            Text("\(j.id) · \(j.partition)")
            Text(j.place)
            Divider()
            Button("Copy Job ID") { copy(j.id) }
            Button("Copy Job Name") { copy(j.name) }
        } else {
            Text("\(g.jobs.count) jobs · \(g.label)")
            Divider()
            Button("Copy \(g.jobs.count) Job IDs") { copy(ids) }
            Button("Copy Job Names") { copy(g.jobs.map(\.name).joined(separator: "\n")) }
        }
        Button("Copy  scancel \(g.jobs.count == 1 ? ids : "… (\(g.jobs.count) jobs)")") { copy("scancel \(ids)") }
    }
    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}

extension JobGroup {
    /// Tooltip: one line per job.
    var detail: String {
        jobs.prefix(20).map { j in
            let t = j.isPending ? "" : " · \(Fmt.hm(j.elapsed))/\(Fmt.hm(j.limit))"
            return jobs.count == 1 ? "\(j.id) · \(j.partition) · \(j.place)" : "\(j.id) · \(j.name) · \(j.place)\(t)"
        }.joined(separator: "\n") + (jobs.count > 20 ? "\n+ \(jobs.count - 20) more" : "")
    }
}

struct FullView: View {
    let snap: Snapshot
    @ObservedObject var s: Store
    var body: some View {
        let running = Grouper.group(snap.running, rules: s.cfg.groupRules, enabled: s.cfg.groupJobs)
        let pending = Grouper.group(snap.pending, rules: s.cfg.groupRules, enabled: s.cfg.groupJobs)
        let rows = s.cfg.maxRows
        VStack(alignment: .leading, spacing: 11) {
            GPUSection(snap: snap, spark: s.spark.map(\.v), sparkMinutes: s.sparkMinutes)
            FairShareSection(snap: snap)
            if !running.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHead(title: "RUNNING", tail: "\(snap.running.count)", color: T.green)
                    ForEach(running.prefix(rows)) { RunRow(g: $0) }
                    if running.count > rows { More(n: running.count - rows) }
                }
            }
            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHead(title: "QUEUE", tail: "\(snap.pendingTasks)", color: T.amber)
                    ForEach(pending.prefix(rows)) { QueueRow(g: $0, now: snap.serverNow) }
                    if pending.count > rows { More(n: pending.count - rows) }
                }
            }
            if running.isEmpty && pending.isEmpty {
                Text("NO ACTIVE JOBS · GRID IDLE").font(T.mono(9)).tracking(1.6).foregroundColor(T.faint)
            }
            if s.cfg.showCluster && (!snap.pools.isEmpty || snap.unavailable.contains("NODES")) {
                ClusterSection(pools: snap.pools, warn: snap.warn("NODES"))
            }
            if s.cfg.showHistory { HistLine(h: snap.hist, hours: s.cfg.historyHours, warn: snap.warn("HIST")) }
        }
    }
}

struct More: View {
    let n: Int
    var body: some View { Text("  + \(n) more rows").font(T.mono(8.5)).foregroundColor(T.faint) }
}

struct GPUSection: View {
    let snap: Snapshot
    let spark: [Int]
    let sparkMinutes: Int
    var body: some View {
        let run = Snapshot.group(snap.running), pend = Snapshot.group(snap.pending)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 20) {
                BigStat(label: "GPU ACTIVE", value: snap.gpuRun, color: T.cyan)
                BigStat(label: "GPU QUEUED", value: snap.gpuPend, color: T.amber)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Sparkline(values: spark, color: T.cyan).frame(width: 104, height: 28)
                    Text(spark.count > 1 ? "ACTIVE · \(max(1, sparkMinutes))M" : "ACTIVE · ——")
                        .font(T.mono(7)).tracking(1.2).foregroundColor(T.faint)
                }
                .padding(.bottom, 4)
            }
            GPUBlocks(run: run, pend: pend)
            if !run.isEmpty || !pend.isEmpty {
                HStack(spacing: 10) {
                    ForEach(run) { t in
                        (Text("■ ").foregroundColor(T.gpu(t.id)) + Text("\(t.id.uppercased()) \(t.n)").foregroundColor(T.text.opacity(0.8)))
                            .font(T.mono(8.5, .medium))
                    }
                    ForEach(pend) { t in
                        (Text("□ ").foregroundColor(T.gpu(t.id)) + Text("\(t.id.uppercased()) \(t.n)").foregroundColor(T.dim))
                            .font(T.mono(8.5))
                    }
                }
            }
        }
    }
}

struct FairShareSection: View {
    let snap: Snapshot
    var body: some View {
        let row = snap.shares.first
        let acct = row.flatMap { snap.acctLFS[$0.account] }
        VStack(alignment: .leading, spacing: 6) {
            SectionHead(title: "FAIRSHARE", tail: row?.account, warn: snap.warn("SHARE"))
            HStack(alignment: .top, spacing: 0) {
                KV(k: "LEVELFS·GROUP", v: Fmt.num(acct), c: T.lfs(acct)).frame(maxWidth: .infinity, alignment: .leading)
                KV(k: "LEVELFS·USER", v: Fmt.num(row?.levelFS), c: T.lfs(row?.levelFS)).frame(maxWidth: .infinity, alignment: .leading)
                KV(k: "FS FACTOR", v: Fmt.num(row?.fairShare), c: T.cyan).frame(maxWidth: .infinity, alignment: .leading)
            }
            Meter(frac: row?.fairShare ?? 0, color: T.cyan, height: 3)
        }
    }
}

struct RunRow: View {
    let g: JobGroup
    static func frac(_ j: Job) -> Double { j.limit.map { Double(j.elapsed) / Double(max($0, 1)) } ?? 0 }
    var body: some View {
        let js = g.jobs
        // The time shown for a group is the job closest to its limit: the one that ends first.
        let lead = js.max { Self.frac($0) < Self.frac($1) } ?? js[0]
        let live = js.contains { $0.st == "R" }
        VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 6) {
                Text("▸").font(T.mono(10, .bold)).foregroundColor(live ? T.green : T.dim)
                Text(g.label).font(T.mono(10.5)).foregroundColor(T.text).lineLimit(1).truncationMode(.middle)
                if js.count > 1 { Text("×\(js.count)").font(T.mono(9, .bold)).foregroundColor(T.green).fixedSize() }
                Spacer(minLength: 4)
                Chip(types: g.gpuTotals)
                Text("\(Fmt.hm(lead.elapsed))/\(Fmt.hm(lead.limit))").font(T.mono(9.5)).foregroundColor(T.dim).fixedSize()
            }
            // One thin meter per job while they fit; a single averaged one for a big group.
            HStack(spacing: 3) {
                if js.count <= 12 {
                    ForEach(js) { j in bar(Self.frac(j)) }
                } else {
                    bar(js.reduce(0) { $0 + Self.frac($1) } / Double(js.count))
                }
            }
            .padding(.leading, 14)
        }
        .contentShape(Rectangle())
        .contextMenu { JobMenu(g: g) }
        .help(g.detail)
    }
    func bar(_ f: Double) -> some View { Meter(frac: f, color: f > 0.9 ? T.amber : T.green, height: 1.5, ticks: false) }
}

struct QueueRow: View {
    let g: JobGroup
    let now: Date
    var body: some View {
        // Pending jobs arrive sorted by estimated start, so the first one is the next to run.
        let first = g.jobs[0]
        let reasons = Set(g.jobs.map { Fmt.reason($0.place) })
        HStack(spacing: 6) {
            Text("◇").font(T.mono(9.5, .bold)).foregroundColor(T.amber)
            Text(g.label).font(T.mono(10.5)).foregroundColor(T.text.opacity(0.85)).lineLimit(1).truncationMode(.middle)
            if g.tasks > 1 { Text("×\(g.tasks)").font(T.mono(9, .bold)).foregroundColor(T.amber).fixedSize() }
            Spacer(minLength: 4)
            Chip(types: g.gpuTotals)
            Text(reasons.count == 1 ? Fmt.reason(first.place) : "MIXED").font(T.mono(8, .bold)).foregroundColor(T.amber.opacity(0.9)).fixedSize()
            Text(Fmt.eta(first.start, now: now)).font(T.mono(9.5)).foregroundColor(T.dim).frame(minWidth: 40, alignment: .trailing).fixedSize()
        }
        .contentShape(Rectangle())
        .contextMenu { JobMenu(g: g) }
        .help(g.detail)
    }
}

struct ClusterSection: View {
    let pools: [Pool]
    let warn: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHead(title: "CLUSTER", warn: warn)
            ForEach(pools) { p in
                HStack(spacing: 8) {
                    Text(p.id.uppercased()).font(T.mono(9, .semibold)).foregroundColor(T.gpu(p.id)).frame(width: 44, alignment: .leading)
                    Meter(frac: Double(p.used) / Double(max(p.total, 1)), color: T.gpu(p.id), height: 4)
                    (Text("\(p.free)").font(T.mono(10, .semibold)).foregroundColor(p.free > 0 ? T.green : T.red)
                     + Text(" FREE/\(p.total)").font(T.mono(8.5)).foregroundColor(T.dim))
                        .fixedSize()
                }
            }
        }
    }
}

struct HistLine: View {
    let h: Hist
    let hours: Int
    let warn: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text("LAST \(hours)H").font(T.mono(8.5, .semibold)).tracking(1.6).foregroundColor(T.chrome)
                if warn == "N/A" {
                    Text("history unavailable").font(T.mono(9)).foregroundColor(T.faint)
                } else {
                    cnt("✓", h.ok, T.green)
                    cnt("✗", h.fail, T.red)
                    cnt("⧖", h.timeout, T.amber)
                    cnt("⊘", h.cancel, T.text.opacity(0.7))
                }
                if let warn, warn != "N/A" { Text(warn).font(T.mono(7.5, .bold)).tracking(1.2).foregroundColor(T.amber) }
                Spacer(minLength: 0)
            }
            ForEach(h.failures.prefix(2)) { f in
                Text("✗ \(f.name) · \(f.state)").font(T.mono(8.5)).foregroundColor(T.red.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                    .help(f.id)
            }
        }
    }
    func cnt(_ sym: String, _ n: Int, _ c: Color) -> some View {
        Text("\(sym) \(n)").font(T.mono(9.5, .medium)).foregroundColor(n > 0 ? c : T.faint)
    }
}

struct CompactView: View {
    let snap: Snapshot
    var body: some View {
        let row = snap.shares.first
        let acct = row.flatMap { snap.acctLFS[$0.account] }
        HStack(alignment: .center, spacing: 12) {
            stat("\(snap.gpuRun)", "GPU", T.cyan)
            bar
            stat("\(snap.pendingTasks)", "QUEUED", T.amber)
            bar
            VStack(alignment: .leading, spacing: 1) {
                (Text("LFS·G ").foregroundColor(T.dim) + Text(Fmt.num(acct)).foregroundColor(T.lfs(acct))).font(T.mono(9.5, .medium))
                (Text("LFS·U ").foregroundColor(T.dim) + Text(Fmt.num(row?.levelFS)).foregroundColor(T.lfs(row?.levelFS))).font(T.mono(9.5, .medium))
            }
            Spacer(minLength: 0)
        }
    }
    var bar: some View { Rectangle().fill(T.chrome.opacity(0.3)).frame(width: 0.75, height: 22) }
    func stat(_ v: String, _ k: String, _ c: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(v).font(T.mono(20, .light)).foregroundColor(c)
            Text(k).font(T.mono(8, .medium)).tracking(1.2).foregroundColor(T.dim)
        }
    }
}

// MARK: - Window

final class HostView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, non-activating panel that never steals keyboard focus; drag anywhere to move.
final class HUDPanel: NSPanel {
    var onMoved: (() -> Void)?
    private var downAt: NSPoint?
    private var downOrigin = NSPoint.zero
    private var dragging = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            downAt = NSEvent.mouseLocation
            downOrigin = frame.origin
            dragging = false
        case .leftMouseDragged:
            if let d = downAt {
                let p = NSEvent.mouseLocation
                let dx = p.x - d.x, dy = p.y - d.y
                if dragging || abs(dx) + abs(dy) > 3 {
                    dragging = true
                    setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
                    return
                }
            }
        case .leftMouseUp:
            downAt = nil
            if dragging { dragging = false; onMoved?(); return }
        default: break
        }
        super.sendEvent(e)
    }
}

enum Layer: String { case float, desktop }

/// One server's floating window. Its position, visibility, layer, opacity and click-through are saved per server.
final class ServerHUD: NSObject {
    let store: Store
    let index: Int
    var panel: HUDPanel!
    var host: HostView<HUDView>!
    var layer: Layer
    private var bag = Set<AnyCancellable>()
    private var layoutQueued = false
    private var prefs: Prefs { store.prefs }

    init(store: Store, index: Int) {
        self.store = store
        self.index = index
        layer = Layer(rawValue: store.prefs.string("hud.layer") ?? "") ?? .desktop
        super.init()
        buildPanel()
        store.objectWillChange
            .sink { [weak self] _ in self?.scheduleRelayout() }
            .store(in: &bag)
    }

    func close() {
        store.stop()
        bag.removeAll()
        panel.orderOut(nil)
        panel.close()
    }

    func buildPanel() {
        let p = HUDPanel(contentRect: initialFrame(height: 120), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.isMovable = false
        p.animationBehavior = .none
        p.onMoved = { [weak self] in self?.savePosition() }

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: p.frame.size))
        fx.material = .popover   // follows the system appearance (.hudWindow is always dark)
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = ServerHUD.roundedMask(12)
        fx.autoresizingMask = [.width, .height]

        let h = HostView(rootView: HUDView(s: store))
        h.sizingOptions = [.intrinsicContentSize]
        h.frame = fx.bounds
        h.autoresizingMask = [.width, .height]
        fx.addSubview(h)
        p.contentView = fx

        panel = p
        host = h
        applyLayer()
        p.alphaValue = CGFloat(prefs.double("hud.alpha") ?? 1)
        p.ignoresMouseEvents = prefs.bool("hud.clickThrough")
        relayout()
        if !prefs.bool("hud.hidden") { p.orderFrontRegardless() }
    }

    static func roundedMask(_ r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    /// The saved position while some screen still shows part of it; otherwise (no saved position, or its display
    /// is gone) the top-right corner of the main screen, each further server one column to the left.
    /// The saved position is kept, so the HUD goes back there when that display returns.
    func initialFrame(height: CGFloat, width: CGFloat = hudWidth) -> NSRect {
        if let x = prefs.double("hud.x"), let top = prefs.double("hud.top") {
            let f = NSRect(x: x, y: top - height, width: width, height: height)
            if NSScreen.screens.contains(where: { $0.frame.intersects(f) }) { return ServerHUD.clamped(f) }
        }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = vf.maxX - (width + 18) * CGFloat(index + 1)
        return ServerHUD.clamped(NSRect(x: x, y: vf.maxY - 18 - height, width: width, height: height))
    }

    /// Displays were added, removed or rearranged: put the panel back on a screen that exists.
    func screensChanged() {
        guard let panel else { return }
        let f = initialFrame(height: panel.frame.height, width: panel.frame.width)
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    /// Keep the whole panel on the screen it mostly sits on (top edge wins if it is taller than the screen).
    static func clamped(_ f: NSRect) -> NSRect {
        func overlap(_ s: NSScreen) -> CGFloat { let i = s.frame.intersection(f); return i.isNull ? 0 : i.width * i.height }
        let screen = NSScreen.screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return f }
        var r = f
        r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
        r.origin.y = r.height >= v.height ? v.maxY - r.height : min(max(r.minY, v.minY), v.maxY - r.height)
        return r
    }

    func savePosition() {
        prefs.set(Double(panel.frame.minX), "hud.x")
        prefs.set(Double(panel.frame.maxY), "hud.top")
    }

    /// Several @Published fields change per refresh; measure the layout once per main-loop turn.
    func scheduleRelayout() {
        guard !layoutQueued else { return }
        layoutQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.layoutQueued = false
            self?.relayout()
        }
    }

    func relayout() {
        guard let panel, let host else { return }
        let size = host.intrinsicContentSize
        if size.width > 10, size.height > 10,
           abs(panel.frame.height - size.height) > 0.5 || abs(panel.frame.width - size.width) > 0.5 {
            var f = panel.frame
            let top = f.maxY
            f.size = size
            f.origin.y = top - size.height
            panel.setFrame(ServerHUD.clamped(f), display: true)
            panel.invalidateShadow()
        }
        AppDelegate.shared?.updateStatusTitle()
    }

    func applyLayer() {
        switch layer {
        case .float:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        case .desktop:
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
    }

    func toggleLayer() {
        layer = layer == .float ? .desktop : .float
        prefs.set(layer.rawValue, "hud.layer")
        applyLayer()
        if panel.isVisible { panel.orderFrontRegardless() }   // a hidden HUD stays hidden
    }

    /// This server's part of the status menu: flat when it is the only server, a submenu otherwise.
    func addItems(to m: NSMenu, shortcuts: Bool) {
        func add(_ title: String, _ sel: Selector, _ key: String = "", on: Bool = false) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: shortcuts ? key : "")
            it.target = self
            it.state = on ? .on : .off
            m.addItem(it)
        }
        add("Refresh Now", #selector(refreshNow), "r")
        add(panel.isVisible ? "Hide HUD" : "Show HUD", #selector(toggleHUD), "h")
        add("Compact Mode", #selector(toggleCompact), on: store.compact)
        m.addItem(.separator())
        add("Float Above Windows", #selector(setFloat), on: layer == .float)
        add("Pin to Desktop (behind windows)", #selector(setDesktop), on: layer == .desktop)
        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [100, 90, 80, 70, 60, 50] {
            let it = NSMenuItem(title: "\(v)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            it.target = self
            it.tag = v
            it.state = abs(panel.alphaValue * 100 - CGFloat(v)) < 1 ? .on : .off
            sub.addItem(it)
        }
        op.submenu = sub
        m.addItem(op)
        add("Click-Through (lock in place)", #selector(toggleClickThrough), on: panel.ignoresMouseEvents)
        m.addItem(.separator())
        add("Reconnect SSH (MFA)…", #selector(reconnect))
    }

    var menuTitle: String { "\(store.cfg.displayLabel) · \(store.cfg.host)  —  \(store.statusText)" }

    @objc func refreshNow() { store.refresh(full: true) }
    @objc func toggleCompact() { store.toggleCompact() }
    @objc func setFloat() { if layer != .float { toggleLayer() } }
    @objc func setDesktop() { if layer != .desktop { toggleLayer() } }
    @objc func reconnect() { store.reconnect() }
    @objc func toggleHUD() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        prefs.set(!panel.isVisible, "hud.hidden")
    }
    @objc func setOpacity(_ sender: NSMenuItem) {
        panel.alphaValue = CGFloat(sender.tag) / 100
        prefs.set(Double(sender.tag) / 100, "hud.alpha")
    }
    @objc func toggleClickThrough() {
        panel.ignoresMouseEvents.toggle()
        prefs.set(panel.ignoresMouseEvents, "hud.clickThrough")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    var huds: [ServerHUD] = []
    var item: NSStatusItem!
    var demoText: String?
    var renderPath: String?
    private var locked = false, displaysAsleep = false, switchedOut = false
    var idle: Bool { locked || displaysAsleep || switchedOut }
    private var renderSub: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let i = CommandLine.arguments.firstIndex(of: "--demo"), i + 1 < CommandLine.arguments.count {
            demoText = (try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)) ?? ""
        }
        // Debug: `SlurmHUD --render out.png` writes every server's HUD, side by side, to a PNG after each update.
        // Hooked (in sync) before the first refresh so synchronous state changes (e.g. a config error) are captured too.
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            renderPath = CommandLine.arguments[i + 1]
        }
        buildStatusItem()
        sync(Config.loadAll(), start: false)
        // A display unplugged or rearranged: windows saved on it would otherwise stay off-screen.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.huds.forEach { $0.screensChanged() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.huds.forEach { $0.store.wake() }
        }
        // Nobody can see the HUD: stop polling the cluster until somebody can.
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.setIdle { $0.locked = true } }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.setIdle { $0.locked = false } }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setIdle { $0.displaysAsleep = true } }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setIdle { $0.displaysAsleep = false } }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setIdle { $0.switchedOut = true } }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setIdle { $0.switchedOut = false } }
        huds.forEach { $0.store.refresh() }
    }

    /// Match the windows to the config: servers keep their window by position in the list, new ones get a
    /// window, removed ones lose theirs. A server whose host changed starts over (`Store.apply`).
    @MainActor func sync(_ list: [(Config, String?)], start: Bool = true) {
        var seen: [String: Int] = [:]
        let ids: [String] = list.map { c, _ in
            let n = seen[c.host, default: 0]
            seen[c.host] = n + 1
            return n == 0 ? c.host : "\(c.host)#\(n + 1)"   // the same host twice keeps two sets of settings
        }
        while huds.count > list.count { huds.removeLast().close() }
        var fresh: [Store] = []
        for (i, (c, e)) in list.enumerated() {
            if i < huds.count, huds[i].store.prefs.id == ids[i] {
                huds[i].store.apply(c, e)
                continue
            }
            let s = Store(c, e, prefs: Prefs(id: ids[i], legacy: i == 0))
            s.demoText = demoText
            s.setIdle(idle)
            let h = ServerHUD(store: s, index: i)
            if i < huds.count { huds[i].close(); huds[i] = h } else { huds.append(h) }
            fresh.append(s)
        }
        if let path = renderPath {   // follow the current set of servers
            renderSub = Publishers.MergeMany(huds.map { $0.store.objectWillChange })
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.renderPNG(path) }
            // Replacing the subscription drops a render that was still waiting out its debounce.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.renderPNG(path) }
        }
        if start { fresh.forEach { $0.refresh() } }
        updateStatusTitle()
    }

    func hud(for s: Store) -> ServerHUD? { huds.first { $0.store === s } }

    private func setIdle(_ change: (AppDelegate) -> Void) {
        change(self)
        huds.forEach { $0.store.setIdle(idle) }
    }

    @MainActor func renderPNG(_ path: String) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let stores = huds.map(\.store)
        let view = HStack(alignment: .top, spacing: 18) {
            ForEach(stores.indices, id: \.self) { HUDView(s: stores[$0]) }
        }
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(24)
            .background(LinearGradient(colors: [Color(red: 0.66, green: 0.63, blue: 0.59), Color(red: 0.45, green: 0.47, blue: 0.49)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: status item

    func buildStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let m = NSMenu()
        m.delegate = self
        item.menu = m
        updateStatusTitle()
    }

    private var lastTitle = ""
    /// `▣ 18 ◇10` for one server; `▣ 18 ◇10 │ 4 │ ✕` with several, in config order.
    func updateStatusTitle() {
        guard let item else { return }
        let t = "▣ " + (huds.isEmpty ? "…" : huds.map(\.store.shortStatus).joined(separator: " │ "))
        guard t != lastTitle else { return }
        lastTitle = t
        item.button?.attributedTitle = NSAttributedString(string: t, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)])
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if huds.count == 1, let h = huds.first {
            let head = NSMenuItem(title: h.menuTitle, action: nil, keyEquivalent: "")
            head.isEnabled = false
            m.addItem(head)
            m.addItem(.separator())
            h.addItems(to: m, shortcuts: true)
        } else {
            for h in huds {
                let it = NSMenuItem(title: h.menuTitle, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                h.addItems(to: sub, shortcuts: false)
                it.submenu = sub
                m.addItem(it)
            }
            m.addItem(.separator())
            add(m, "Refresh All", #selector(refreshAll), "r")
            add(m, huds.contains { $0.panel.isVisible } ? "Hide All HUDs" : "Show All HUDs", #selector(toggleAll), "h")
            m.addItem(.separator())
        }
        add(m, "Edit Config…", #selector(editConfig))
        add(m, "Reload Config", #selector(reloadConfig))
        let login = SMAppService.mainApp.status
        let li = add(m, login == .requiresApproval ? "Launch at Login (approve in System Settings…)" : "Launch at Login",
                     #selector(toggleLogin), on: login == .enabled)
        if login == .requiresApproval { li.state = .mixed }
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit SlurmHUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String = "", on: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        it.state = on ? .on : .off
        m.addItem(it)
        return it
    }

    @objc func refreshAll() { huds.forEach { $0.store.refresh(full: true) } }
    @objc func toggleAll() {
        let show = !huds.contains { $0.panel.isVisible }
        for h in huds where h.panel.isVisible != show { h.toggleHUD() }
    }
    @MainActor @objc func reloadConfig() {
        DirectGate.reset()   // the user may have fixed the login; each target gets one direct try again
        sync(Config.loadAll())
    }
    @objc func editConfig() {
        if !FileManager.default.fileExists(atPath: Config.file.path) { Config().save() }
        NSWorkspace.shared.open(Config.file)
    }
    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            switch svc.status {
            case .enabled:
                try svc.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try svc.register()
                if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Launch at Login failed"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }
}

// MARK: - Entry

@main
@MainActor
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // `SlurmHUD --parse <file>`: run the parser on a captured probe output and print a summary (tests).
        if let i = args.firstIndex(of: "--parse"), i + 1 < args.count {
            let text = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
            print(Parser.describe(Parser.parse(text)))
            exit(0)
        }
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
