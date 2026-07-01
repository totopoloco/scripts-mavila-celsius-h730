#!/bin/bash

if [ $# -ne 2 ]; then
  echo "Usage: $0 <vault> <title>"
  exit 1
fi

VAULT="$1"
TITLE="$2"

pass-cli item list "$VAULT" --output json --show-secrets | jq -r --arg title "$TITLE" '
  ["TITLE", "EMAIL", "USERNAME"],
  ["-----", "--------", "-----"],
  (
    .items[]
    | select(.content.content.Login != null)
    | select(.content.title | test($title; "i"))
    | [.content.title, .content.content.Login.email, .content.content.Login.username]
  )
  | @tsv
' | column -t -s $'\t'
