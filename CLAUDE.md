# SlurmHUD — notes for agents

Floating macOS HUD (menu-bar accessory app) that shows the user's Slurm jobs, GPU usage,
fair-share (LevelFS) and cluster GPU availability. User-facing docs: README.md (English) and README.zh-CN.md.

## Layout

- `Sources/main.swift`: the whole app, one file, sectioned by `// MARK:`.
  - `Config`: JSON at `~/.config/slurm-hud/config.json`. Override the directory with `SLURMHUD_CONFIG_DIR` (used by tests).
    Missing keys fall back to defaults. The default `host` is empty, so a fresh install shows CONFIG ERROR until it is set.
    `clamp()` bounds the numbers. `problem` rejects hosts that are empty, start with `-`, or contain whitespace.
    A broken file is never overwritten; it shows a CONFIG ERROR banner instead.
  - `Remote.script`: bash sent over ssh stdin. It prints `@@TAG` sections (HOST, NOW, ENV, JOBS, SHARE, NODES, HIST, END)
    and `@@NA <SECTION>` when a query fails, so a failure never looks like an empty result. A fatal problem prints `@@ERR`.
  - `Parser`: turns that text into `Snapshot`. `Parser.describe` gives a deterministic dump for tests.
  - `SSH`: `Process` wrapper for `/usr/bin/ssh` and the ControlMaster helpers.
  - `Store`: the poller (`ObservableObject`). It owns link state, backoff, the config generation and the reconnect flow.
  - Views (`HUDView` and below): SwiftUI. `Canvas` draws the grid, meters, sparkline and GPU blocks.
  - `HUDPanel` / `AppDelegate`: borderless non-activating `NSPanel` (desktop level by default, optionally floating),
    the status item menu, and persistence in `UserDefaults` (domain `io.github.slurm-hud`).
- `Info.plist`: `LSUIElement` (no Dock icon). `build.sh` compiles with `swiftc` (no Xcode project); `./build.sh universal`
  builds arm64 + x86_64 and writes `build/SlurmHUD.zip`.
- `Tests/`: captured probe outputs (`*.txt`) plus golden parser dumps (`*.expected`); `Tests/run.sh` diffs them.
- `docs/demo_probe.txt`: synthetic probe output for `--demo` (screenshots, UI work without a cluster). `docs/screenshot.png` is rendered from it.
  Never put real job names, accounts or hostnames in anything committed.

## Build / test / verify

```bash
./build.sh            # builds in $TMPDIR, ad-hoc signs, installs ~/Applications/SlurmHUD.app (kills the running copy)
./build.sh run        # same, then launches it
Tests/run.sh          # parser regression tests (needs the built app)
~/Applications/SlurmHUD.app/Contents/MacOS/SlurmHUD --parse some_probe_output.txt
~/Applications/SlurmHUD.app/Contents/MacOS/SlurmHUD --render /tmp/hud.png         # PNG of the HUD after each update
SLURMHUD_CONFIG_DIR=/tmp/t1 ~/Applications/SlurmHUD.app/Contents/MacOS/SlurmHUD --render /tmp/t1.png   # isolated test config
SLURMHUD_CONFIG_DIR=/tmp/demo ~/Applications/SlurmHUD.app/Contents/MacOS/SlurmHUD --demo docs/demo_probe.txt --render docs/screenshot.png
```

After changing the parser or the probe, add a case to `Tests/*.txt`. Write its `.expected` only after
checking the output by hand. `--render` is the way to check the UI visually: `screencapture` needs a
Screen Recording permission that agent shells usually lack. Measure memory with `footprint <pid>` (~35 MB).
RSS overstates it because it counts shared frameworks.

## Invariants (don't break these)

- **Never let the app authenticate interactively or keep retrying direct logins.** Many HPC login nodes require MFA,
  and repeated failed logins can get the user's IP banned.
  - Every fetch uses `BatchMode=yes` and `ControlMaster=no`. Before each fetch, `ssh -O check` (local only) tests the master socket.
  - When the master is up, the fetch also gets `ProxyCommand=/usr/bin/false`. If the socket vanishes in between,
    ssh then fails locally instead of falling back to a direct login.
  - With no master, the app tries one direct login. Any failure that reached the server sets `directFailed`;
    after that it only polls the local socket. Pure network errors (refused, unreachable, DNS) back off exponentially, up to 15 min.
- The ControlPath is resolved once with `ssh -G` and passed **expanded** to every call (fetch, check, reconnect).
  Overriding ProxyCommand can change a `%C` hash, so a pattern must not be used here. `extraSSHOptions` goes to all of those calls too.
- `ControlMaster=no` on fetches is deliberate. A fetch that became a ControlPersist master would keep the
  stdout pipe open and hang `readDataToEndOfFile`.
- Reconnect writes `<config dir>/connect.command` and opens it in Terminal. That script runs
  `ssh -fN -o ControlMaster=yes -o ControlPersist=yes <host>`, so the user does MFA once. Every interpolated value goes through `shq()`.
- Remote env: non-login shells on some clusters lack `SLURM_CONF`/PATH. The first fetch uses `bash -l -s`. It caches
  `SLURM_CONF|bindir` in UserDefaults (`remoteEnv.<host>`); later fetches run plain `bash -s` with exports.
  On `@@ERR` the cache is cleared and the fetch retries with a login shell.
- Probe output format: `SLURM_TIME_FORMAT=%s` makes every timestamp an epoch, which avoids time-zone and DST math.
  `JobArrayID` keeps collapsed pending arrays as `123_[0-9%2]`, and the parser counts their tasks.
  Job and sacct names come **last** so a `|` inside a name can be re-joined. `sq` strips -O padding (~150 KB → ~11 KB per round).
  History is counted server-side with awk; only the top 3 failures are sent.
- A query that fails (`@@NA`) keeps the previous round's data for that section, marked STALE. It is never shown as zeros.
- Config reloads bump `Store.gen`. Results from an older generation are dropped, never applied to the new host.
- Keep idle CPU ~0: no repeating SwiftUI animations or per-second timers. The UI redraws only when data changes,
  and `scheduleRelayout()` coalesces the size measurement to once per main-loop turn.
- The repo lives in an iCloud-synced folder. codesign rejects bundles there ("resource fork, Finder information…"),
  so `build.sh` must keep staging the bundle outside the repo.

## Probing the cluster

Read the configured host from `~/.config/slurm-hud/config.json`. Read-only probes are fine through the existing master, e.g.
`ssh -o BatchMode=yes -o ControlMaster=no <host> 'bash -l -c "squeue -u \$USER"'`.
If `ssh -O check <host>` fails, ask the user to click RECONNECT (or run `ssh <host>`). Agents can't complete MFA.
Never kill the user's master connection: restoring it needs their MFA.
