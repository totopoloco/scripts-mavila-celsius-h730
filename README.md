# scripts-mavila-celsius-h730

Personal scripts for administering my Fujitsu CELSIUS H730 workstation: Ubuntu 24.04 LTS (kernel 6.8),
Intel Core i7-4910MQ, NVIDIA Quadro K2100M (Kepler). Paths, driver versions, and tuning values are
hardcoded to this one machine — treat this as reference material rather than a drop-in toolkit.

The checkout lives at `~/scripts-mavila-celsius-h730` and is symlinked as `~/scripts`; scripts that
reference each other use the `~/scripts/...` path.

## Contents

Scripts are split into two groups: ones that only make sense on **this** machine (hardcoded model
numbers, driver versions, local service names, or values tuned to this hardware), and generic ones
that would work unmodified on any Debian/Ubuntu box.

### Specific to this machine

**GPU & hardware tuning** — the Quadro K2100M only supports the NVIDIA 470 driver branch, and Ubuntu
24.04 has a way of silently upgrading it to the incompatible 535 branch; this ties several scripts to
this exact GPU.
- `fix-nvidia-kepler.sh` — repairs a broken driver install (pins the bad version, purges 535, reinstalls
  and holds the real 470 build).
- `switch-to-nouveau.sh` — migrates off proprietary NVIDIA to `nouveau` entirely, needed before a
  release/kernel upgrade the 470 branch can't build against.
- `performance-tuning.sh` — full apply/undo/status tuning for maximum performance on this specific host
  (CPU governor/turbo, PCIe ASPM, SATA ALPM, USB/Wi-Fi power saving, sysctl/limits drop-ins, boot-time
  systemd unit). Fully reversible via `--undo`. `--iobench` runs a read-only per-disk throughput check
  (`hdparm -Tt`) with friendly device names and a plain-English speed verdict instead of a bare MB/sec
  figure.
- `thermal-info.sh` — CPU/thermal-zone temperature and thermald-config reporting, written for this
  chassis's sensors and trip points.
- `fix-mic-input.sh` — diagnoses (and with `--fix`, restarts) a recurring PipeWire/WirePlumber bug where
  the built-in mic (Realtek ALC282 on the Intel PCH codec) drops out of GNOME Settings > Sound > Input.
  Kernel/ALSA and the hardware mixer are unaffected; confirmed to need only a user-level service restart,
  not a reboot.
- `update.sh` — daily `apt update && full-upgrade`; warns before an LTS upgrade if
  `switch-to-nouveau.sh` hasn't been run yet (see GPU note above).

**App launchers** — background-launch the app with a per-app HiDPI `--force-device-scale-factor` tuned
by eye for this display; the factor would need re-tuning for a different monitor.
`brave.sh`, `chrome.sh`, `edge.sh`, `mongodb.sh`, `postman.sh`, `signal.sh`, `skype.sh`, `slack.sh`,
`sublime.sh`, `teams.sh`, `telegram.sh`, `thunderbird.sh`, `vscode.sh`.
- `vivaldi-openvalue.sh` — same idea, but launches Vivaldi under a separate `openvalue` OS user for a
  sandboxed work profile; depends on that user existing and an X11 session.

**Local services**
- `monitoring.sh` — start/stop/restart/status wrapper around the self-hosted log stack installed on this
  box (logstash, filebeat, kibana, elasticsearch, guacd, tomcat9).
- `yaping.sh` — pings a target from multiple source IPs/interfaces to compare ISP latency; the IPs are
  this network's.

### Generic (works on any Debian/Ubuntu box)

**System & package maintenance**
- `update.sh.bak` — superseded predecessor of `update.sh`; unlike it, fully generic (no GPU check).
- `remove_old_kernels.sh` — dry-run by default; pass `exec` to actually purge old kernels.
- `cleanup_models.sh` — prunes local Ollama models against a keep-list (edit the list for your models).
- `move_docker_images.sh` — migrates images between the `default` and `desktop-linux` docker contexts.
- `docker-nuke.sh` — stops/removes **all** containers, images, and volumes. Destructive, no confirmation
  prompt.
- `install_helm.sh` — adds the Helm apt repo and installs it.

**Diagnostics**
- `temp.sh` — quick CPU/thermal-zone temperature report (`-w` watches continuously); plain sysfs/
  lm-sensors, no machine-specific assumptions.
- `disk_info.sh` — used/free space per mounted volume, with a colored usage bar (real filesystems only;
  skips tmpfs/overlay/squashfs noise).
- `mem_top.sh` — top memory-consuming processes, RSS shown in M/G instead of raw KB or bare `%MEM`
  (`-w` watches continuously, same pattern as `temp.sh`).

**Secrets**
- `pass_display.sh` — fetch one login's full credentials by exact title match (via `pass-cli` + `jq`).
- `pass_search.sh` — case-insensitive title search across a vault; prints a table without exposing
  passwords.

**Local infra sandbox**
- `docker-compose.yml` + `postgres-docker/init-db/01-create-sample.sql` — disposable Postgres container
  seeded with sample data on first boot.

## Validating a script

There's no build system; scripts are standalone. Check syntax with `bash -n script.sh`, lint with
`shellcheck script.sh`, and prefer `--dry-run` / `--status` on the scripts that support it before running
the real thing.

## License

MIT © Marco Tulio Ávila Cerón
