#!/bin/bash

if [ $# -ne 2 ]; then
  echo "Usage: $0 <vault> <title>"
  exit 1
fi

VAULT="$1"
TITLE="$2"

pass-cli item list "$VAULT" --output json --show-secrets | jq --arg title "$TITLE" '
  .items[]
  | select(.content.content.Login != null)
  | select(.content.title | ascii_downcase == ($title | ascii_downcase))
  | {title: .content.title, username: .content.content.Login.username, email: .content.content.Login.email, password: .content.content.Login.password}
'
