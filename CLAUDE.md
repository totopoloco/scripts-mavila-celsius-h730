# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A personal collection of standalone shell scripts (plus one docker-compose sandbox) for administering
**one specific physical machine**: a Fujitsu CELSIUS H730 workstation running Ubuntu 24.04 LTS (Noble,
kernel 6.8) with an Intel Core i7-4910MQ (Haswell) CPU and an NVIDIA Quadro K2100M (Kepler-class) GPU.
This is not an application with a build/test pipeline — there is no package.json/Makefile, no test
suite, and none is expected. Each script is independent and directly executable.

The live checkout is symlinked as `~/scripts` (i.e. `~/scripts -> scripts-mavila-celsius-h730`).
Scripts that reference "this repo" in comments, generated apt-pin files, or warning messages use the
path `~/scripts/<name>.sh` — follow that convention in anything new rather than the absolute repo path.

## Validating changes

There's no build step. Use these instead:

```bash
bash -n script.sh          # syntax check
shellcheck script.sh       # lint (used historically on the nvidia scripts)
```

The larger system-modifying scripts implement their own safety rails — use them instead of running the
real action blind:

```bash
./performance-tuning.sh --dry-run   # or --status to see current vs. desired state
./fix-nvidia-kepler.sh --dry-run
./switch-to-nouveau.sh --dry-run
./remove_old_kernels.sh             # no args = preview only; add `exec` to actually purge
```

## Commit messages

Commit messages are concrete, accurate, and carefully crafted in a Freddie Mercury tone — precise about
what changed and why, delivered with the theatrical confidence of a Queen frontman working a stadium
crowd rather than the flat prose of a corporate changelog. Accuracy is non-negotiable; the drama is
garnish, not a substitute for saying exactly what happened. (e.g. "Break free from stale JSON:
pass_display.sh and pass_search.sh needed --show-secrets all along.")

## Architecture

### The Kepler GPU constraint ties several scripts together

The GPU (Quadro K2100M / GK106) is Kepler-class, which NVIDIA only supports up to the **470** driver
branch. On this Ubuntu release, the 470 package at one specific version was turned into a transitional
stub that depends on **535** (which dropped Kepler support), so an ordinary `apt upgrade` silently
breaks `nvidia-smi`. This single fact drives four scripts:

- `fix-nvidia-kepler.sh` — repairs a broken install: pins the poisoned transitional version to `-1`,
  purges the 535 branch, reinstalls the real 470 build, and holds it so future upgrades can't clobber it
  again. Supports `--dry-run` / `--reboot`; logs real runs to a timestamped file next to the script.
- `switch-to-nouveau.sh` — the escape hatch: fully migrates off proprietary NVIDIA to the in-kernel
  `nouveau` driver (needed before moving to a kernel/release the 470 branch can't build against). Undoes
  the apt pins/holds `fix-nvidia-kepler.sh` created.
- `update.sh` — the everyday `apt update && apt full-upgrade` driver. Before upgrading, it checks whether
  a new Ubuntu LTS is available and, if so, warns to run `switch-to-nouveau.sh` first and reboot into a
  working nouveau desktop *before* `do-release-upgrade`.
- `performance-tuning.sh` — unrelated to the driver bug itself, but its `apply_runtime` step also touches
  GPU-adjacent power settings (PCIe ASPM) on the same box.

When touching any of these four, re-check the others for consistency (e.g. the apt pin file paths listed
at the top of `switch-to-nouveau.sh` must match what `fix-nvidia-kepler.sh` actually writes).

### performance-tuning.sh: apply / undo / status / boot-apply lifecycle

The largest script in the repo (~900 lines). It has five modes (`--apply` default, `--undo`, `--status`,
`--boot-apply`, `--iobench`); `--apply`/`--undo`/`--boot-apply` are designed to be fully reversible:

1. Before changing anything, `take_snapshot()` captures every runtime knob it's about to touch
   (governor, USB autosuspend, SATA ALPM, Wi-Fi powersave, gsettings, sysctl values) into
   `/var/backups/performance-tuning/`.
2. Persistent config goes into drop-ins (`/etc/sysctl.d/99-performance.conf`,
   `/etc/security/limits.d/99-performance.conf`, an NetworkManager conf.d file) rather than editing
   existing files in place.
3. Runtime-only knobs (CPU governor/turbo, ASPM, ALPM, USB, Wi-Fi power save) are re-applied on every
   boot by installing a copy of the script to `/usr/local/sbin/` plus a `performance-tuning.service`
   systemd unit that runs it with `--boot-apply`.
4. `--undo` reverses all of the above from the snapshot and removes the installed copy + unit.

`--iobench` sits outside that snapshot/undo lifecycle entirely — it's a read-only diagnostic (a per-disk
`hdparm -Tt` throughput probe reported via friendly device names and a plain-English speed verdict, since
raw MB/sec is meaningless without knowing hdparm under-reports SSDs). It still escalates to root via
`require_root` for a real run, the same way `--apply`/`--undo` do, because opening the raw block devices
needs it.

Any new persistent system tuning in this repo should follow the same shape: snapshot-before-mutate,
drop-in files over in-place edits, explicit `--undo`.

### Script groups

Same split as README.md: scripts hardcoded to this machine's hardware/setup vs. scripts that would run
unmodified on any Debian/Ubuntu box. (`fix-nvidia-kepler.sh`, `switch-to-nouveau.sh`, `update.sh`, and
`performance-tuning.sh` are also machine-specific — already covered above under the Kepler GPU
constraint, not repeated here.)

**Specific to this machine**
- App launchers (`brave.sh`, `chrome.sh`, `edge.sh`, `mongodb.sh`, `postman.sh`, `signal.sh`,
  `skype.sh`, `slack.sh`, `sublime.sh`, `teams.sh`, `telegram.sh`, `thunderbird.sh`, `vscode.sh`) — all
  follow the same one-line-body template: set `MY_FACTOR` (a per-app HiDPI `--force-device-scale-factor`
  tuned by eye for this display), launch the app backgrounded with output silenced. Match this template
  exactly when adding a launcher for a new app. `vivaldi-openvalue.sh` is a variant of this pattern that
  launches the browser as a separate OS user (`openvalue`) via `sudo -u` + a temporary `xhost` grant, for
  keeping a work profile isolated from the main session.
- `thermal-info.sh` — CPU/thermal-zone/thermald reporting written for this chassis's sensors. Overlaps in
  purpose with the generic `temp.sh` below, but assumes nothing machine-specific the way this one does.
- `fix-mic-input.sh` — diagnoses (and with `--fix`, repairs) GNOME Settings showing no microphone: the
  built-in mic (ALC282 on the Intel PCH codec) is fine at the kernel/ALSA level, but WirePlumber's
  `alsa_input.pci-*.analog-stereo` node for it can get stuck or flap after a startup race. `--fix`
  restarts the user pipewire/pipewire-pulse/wireplumber services — no reboot needed, no sudo.
- `monitoring.sh` — start/stop/restart/status wrapper (via `systemctl`) around the specific self-hosted
  log/monitoring stack installed on this box (logstash, filebeat, kibana, elasticsearch, guacd, tomcat9).
  Will error outright on any machine without those exact services.
- `yaping.sh` — pings a target from multiple source IPs/interfaces to compare ISP latency; the IPs are
  this network's.

**Generic (portable to any Debian/Ubuntu box)**
- `update.sh.bak` — superseded predecessor of `update.sh`; unlike it, has no GPU-specific check, so it's
  actually the more portable of the two.
- `remove_old_kernels.sh` (dry-run unless called with `exec`), `cleanup_models.sh` (prunes local Ollama
  models against a keep-list — the mechanism is generic, only the list is personal), `move_docker_images.sh`
  (migrates images between the `default` and `desktop-linux` docker contexts via save/gzip/load),
  `docker-nuke.sh` (stops/removes **all** containers, images, and volumes with no confirmation prompt —
  treat as destructive, don't suggest running it casually), `install_helm.sh` (adds the Helm apt repo and
  installs it).
- `temp.sh` — quick CPU/thermal-zone report (`-w` watches continuously); plain sysfs/lm-sensors reads.
- `disk_info.sh` — used/free space per *mounted volume* (not per block device — the original version
  looped over raw block devices like `/dev/sda`, which usually aren't themselves mounted, so it reported
  little of use). Renders a colored usage bar per volume and filters to real filesystem types so
  tmpfs/overlay/squashfs (snap's loop mounts) don't clutter the output.
- `mem_top.sh` — top memory-consuming processes by RSS, converted to M/G instead of raw KB or a bare
  `%MEM` figure (same rationale as `disk_info.sh`'s bars: percentages/KB alone don't tell you much without
  doing the math yourself). `-w` watches continuously, same pattern as `temp.sh`.
- **Secrets** (`pass_display.sh`, `pass_search.sh`) — both wrap a `pass-cli item list <vault> --output
  json --show-secrets | jq ...` pipeline against a password-manager CLI. The `--show-secrets` flag is
  required: without it, `item list` returns bare metadata (id/title/state/timestamps) with no `content`
  key at all, so the `.content.content.Login...` filters both scripts rely on silently match nothing.
  `pass_display` fetches one login's full credentials by exact (case-insensitive) title match;
  `pass_search` does a case-insensitive substring search and prints a title/email/username table without
  exposing passwords. Follow this jq-over-pass-cli-json shape for any new credential-lookup script, and
  keep password values out of the search/list variant.
- `docker-compose.yml` + `postgres-docker/init-db/01-create-sample.sql` — disposable Postgres container
  seeded with sample data on first boot.

### House style for anything that mutates system state

The newer, more careful scripts (`fix-nvidia-kepler.sh`, `switch-to-nouveau.sh`, `performance-tuning.sh`,
`update.sh`) share conventions that older scripts in this repo don't. Prefer this style for new work:

- `set -uo pipefail` (or `-euo pipefail`) at the top.
- A `--dry-run`/`-n` flag threaded through every mutating action via a small `run()` wrapper that either
  prints the command or executes it.
- Colorized `log()` / `ok()` / `warn()` / `err()` helper functions for output.
- `--help` that self-documents from the script's own header comment block rather than a separate string.
- Real (non-dry-run) invocations tee their output to a timestamped log file next to the script
  (`<name>-YYYYmmdd-HHMMSS.log`).
- System changes prefer additive/reversible mechanisms — apt pin files and `/etc/*.d/` drop-ins,
  `apt-mark hold`, `.bak` copies before in-place `sed` edits — over destructive one-way edits.
