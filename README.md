# scripts-mavila-celsius-h730

Personal scripts for administering my Fujitsu CELSIUS H730 workstation: Ubuntu 24.04 LTS (kernel 6.8),
Intel Core i7-4910MQ, NVIDIA Quadro K2100M (Kepler). Paths, driver versions, and tuning values are
hardcoded to this one machine — treat this as reference material rather than a drop-in toolkit.

The checkout lives at `~/scripts-mavila-celsius-h730` and is symlinked as `~/scripts`; scripts that
reference each other use the `~/scripts/...` path.

## Contents

### App launchers
`brave.sh`, `chrome.sh`, `edge.sh`, `mongodb.sh`, `postman.sh`, `signal.sh`, `skype.sh`, `slack.sh`,
`sublime.sh`, `teams.sh`, `telegram.sh`, `thunderbird.sh`, `vscode.sh` — launch the app in the background
with a per-app HiDPI `--force-device-scale-factor`. `vivaldi-openvalue.sh` launches Vivaldi under a
separate `openvalue` OS user for a sandboxed work profile.

### NVIDIA / Kepler GPU
The Quadro K2100M only supports the NVIDIA 470 driver branch, and Ubuntu 24.04 has a way of silently
upgrading it to the incompatible 535 branch.
- `fix-nvidia-kepler.sh` — repairs a broken driver install (pins the bad version, purges 535, reinstalls
  and holds the real 470 build).
- `switch-to-nouveau.sh` — migrates off proprietary NVIDIA to `nouveau` entirely, needed before a
  release/kernel upgrade the 470 branch can't build against.

### System maintenance
- `update.sh` — daily `apt update && full-upgrade`; warns before an LTS upgrade if
  `switch-to-nouveau.sh` hasn't been run yet.
- `update.sh.bak` — superseded predecessor, kept for reference.
- `remove_old_kernels.sh` — dry-run by default; pass `exec` to actually purge old kernels.
- `cleanup_models.sh` — prunes local Ollama models against a keep-list.
- `move_docker_images.sh` — migrates images between the `default` and `desktop-linux` docker contexts.
- `docker-nuke.sh` — stops/removes **all** containers, images, and volumes. Destructive, no confirmation
  prompt.

### Performance & thermal
- `performance-tuning.sh` — full apply/undo/status tuning for maximum performance (CPU governor/turbo,
  PCIe ASPM, SATA ALPM, USB/Wi-Fi power saving, sysctl/limits drop-ins, boot-time systemd unit). Fully
  reversible via `--undo`.
- `thermal-info.sh`, `temp.sh` — CPU/thermal-zone temperature reporting (`temp.sh -w` watches
  continuously).

### Secrets
- `pass_display.sh` — fetch one login's full credentials by exact title match (via `pass-cli` + `jq`).
- `pass_search.sh` — case-insensitive title search across a vault; prints a table without exposing
  passwords.

### Local infra sandbox
- `docker-compose.yml` + `postgres-docker/init-db/01-create-sample.sql` — disposable Postgres container
  seeded with sample data on first boot.
- `monitoring.sh` — start/stop/restart/status wrapper around a self-hosted log stack (logstash,
  filebeat, kibana, elasticsearch, guacd, tomcat9).

### Misc
- `install_helm.sh` — adds the Helm apt repo and installs it.
- `disk_info.sh` — per-block-device `df` usage.
- `yaping.sh` — pings a target from multiple source IPs to compare ISP latency.

## Validating a script

There's no build system; scripts are standalone. Check syntax with `bash -n script.sh`, lint with
`shellcheck script.sh`, and prefer `--dry-run` / `--status` on the scripts that support it before running
the real thing.

## License

MIT © Marco Tulio Ávila Cerón
