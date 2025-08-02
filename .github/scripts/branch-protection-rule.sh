#!/bin/bash

OWNER="malleroid"
REPO=""
RULE_NAME="Main Branch Protection Rule"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../rulesets/main-branch.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Configuration file not found at $CONFIG_FILE"
  exit 1
fi

gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  /repos/$OWNER/$REPO/rulesets \
  --input "$CONFIG_FILE" \
  --verbose

echo "Repository rule applied successfully: $RULE_NAME"
