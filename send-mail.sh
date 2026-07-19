#!/usr/bin/env bash
#
# send-mail.sh
#
# Quick-launch Alpine's composer with the recipient and subject already
# filled in, so all that's left is typing the body and hitting Ctrl-X to
# send.
#
# The `alpine` on this machine (/usr/local/bin/alpine, built from
# ~/src/alpine) has no -subject flag -- that's an older Pine-era option
# this build's own --help doesn't list. The supported mechanism is a
# mailto: URL passed to -url, which Alpine's own mailto digester
# (url_local_mailto_and_atts in alpine/mailview.c) parses for `to` and
# `subject` (and `body`, unused here; `bcc`/`from` are explicitly ignored
# with a warning by that same code). Both recipient and subject are
# percent-encoded before being placed in the URL, since raw '&', '=', '?',
# '%', or spaces would otherwise be misparsed as URL syntax.
#
# This only pre-fills the composer -- Alpine still asks "Send message?"
# before anything goes out, so nothing here can silently mail on its own.
#
# Usage:
#   ./send-mail.sh --recipient <address> --subject "<text>"
#   ./send-mail.sh --help
#
set -uo pipefail

recipient=""
subject=""

urlencode() {
  local s="$1" c i out=""
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipient)
      recipient="${2:-}"
      shift 2
      ;;
    --subject)
      subject="${2:-}"
      shift 2
      ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (try --help)" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$recipient" || -z "$subject" ]]; then
  echo "Both --recipient and --subject are required (try --help)" >&2
  exit 2
fi

if [[ "$recipient" != *"@"* ]]; then
  echo "Warning: '$recipient' doesn't look like an email address" >&2
fi

if ! command -v alpine >/dev/null 2>&1; then
  echo "alpine is not on PATH" >&2
  exit 1
fi

exec alpine -url "mailto:$(urlencode "$recipient")?subject=$(urlencode "$subject")"
