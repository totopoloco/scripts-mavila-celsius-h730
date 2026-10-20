#!/usr/bin/env bash
# linkcheck.sh - fetch a suspicious URL without a browser and keep a full log for analysis.
#
# Usage:  ./linkcheck.sh 'https://job.devologyx.io/YYzS' [output-dir]
#
# Saves into output-dir (default: linkcheck-YYYYmmdd-HHMMSS):
#   trace.log     timestamped wire log: IPs, TLS certificate, every request and response
#   headers.txt   response headers of every hop in the redirect chain
#   body.txt      final response body, saved as .txt so a double-click never opens a browser
#   summary.json  curl's summary: final URL, number of redirects, server IP, status, timings
#
# curl runs no JavaScript and sends none of your browser cookies, but the server
# still sees the request and your IP, so it counts as a visit.

set -u

if [ $# -lt 1 ]; then
  echo "usage: $0 URL [output-dir]" >&2
  exit 2
fi

URL="$1"
OUT="${2:-linkcheck-$(date +%Y%m%d-%H%M%S)}"
UA='Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0'

mkdir -p "$OUT" || exit 1

curl -sS --location --max-redirs 10 --compressed \
     --proto '=http,https' --proto-redir '=http,https' \
     --connect-timeout 10 --max-time 30 --max-filesize 5M \
     --user-agent "$UA" \
     --header 'Accept: text/html,application/xhtml+xml,*/*;q=0.8' \
     --trace-ascii "$OUT/trace.log" --trace-time \
     --dump-header "$OUT/headers.txt" \
     --output "$OUT/body.txt" \
     --write-out '%{json}\n' \
     "$URL" > "$OUT/summary.json"
rc=$?

section() { printf '\n== %s\n' "$1"; }
show()    { if [ -n "$1" ]; then printf '%s\n' "$1" | sed 's/^/  /'; else echo "  (none)"; fi; }

echo "Saved to $OUT/  (curl exit code $rc)"

section "Summary"
if command -v jq >/dev/null 2>&1; then
  jq -r --arg u "$URL" '
    "started at: \($u)",
    "landed on:  \(.url_effective)",
    "redirects:  \(.num_redirects)",
    "status:     \(.http_code)",
    "server IP:  \(.remote_ip)",
    "type, size: \(.content_type // "-"), \(.size_download) bytes transferred",
    "TLS check:  \(if (.scheme // "" | ascii_downcase) != "https" or .http_code == 0 then "-"
                   elif .ssl_verify_result == 0 then "ok"
                   else "FAILED (\(.ssl_verify_result))" end)",
    "error:      \(.errormsg // "-")"' "$OUT/summary.json" | sed 's/^/  /'
else
  show "$(cat "$OUT/summary.json")"
fi

section "Redirect chain"
show "$(tr -d '\r' < "$OUT/headers.txt" 2>/dev/null | awk '
  { l = tolower($0) }
  l ~ /^http\// { print $0 }
  l ~ /^location:/ { sub(/^[^:]*: */, ""); print "  -> " $0 }')"

# curl up to 8.16 logs info lines as "== Info: ...", 8.17 and later as "* ..."
section "Servers contacted"
show "$(grep -aE '(Info:|^[0-9:.]+ \*) +(Connected to|Established connection to) ' "$OUT/trace.log" 2>/dev/null \
        | sed -E 's/.*(Connected to|Established connection to) //; s/ from .*//')"

section "TLS certificate"
show "$(grep -aE '(Info:|^[0-9:.]+ \*) +(subject|issuer|expire date):' "$OUT/trace.log" 2>/dev/null \
        | sed -E 's/.*(subject|issuer|expire date):/\1:/')"

section "Cookies the site tried to set"
show "$(tr -d '\r' < "$OUT/headers.txt" 2>/dev/null | grep -i '^set-cookie:' | sed -E 's/^[^:]*: *([^=;]+).*/\1/')"

if [ -s "$OUT/body.txt" ]; then
  if command -v file >/dev/null 2>&1; then
    section "What the body actually is"
    show "$(file -b "$OUT/body.txt")"
  fi

  section "Hosts the page references (top 20)"
  show "$(grep -oiE "https?://[^/\"'<> )]+" "$OUT/body.txt" | tr '[:upper:]' '[:lower:]' | sort | uniq -c | sort -rn | head -20)"

  section "Worth a closer look (forms, passwords, auto-redirects, downloads, obfuscation)"
  FLAGS="<form[^>]{0,120}|type=[\"']?password|http-equiv=[\"']?refresh[^>]{0,120}|(window|document)\.location[^;]{0,120}|[a-z0-9._/-]+\.(exe|msi|dmg|pkg|apk|scr|bat|cmd|ps1|vbs|jar|iso|zip|rar|7z)\b|eval\(|atob\(|fromCharCode"
  show "$(grep -noiE "$FLAGS" "$OUT/body.txt" | cut -c1-160 | head -30)"

  printf '\nRead the page as text with:  less %s/body.txt\n' "$OUT"
fi

exit "$rc"
