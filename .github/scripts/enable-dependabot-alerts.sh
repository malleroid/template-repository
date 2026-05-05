#!/bin/bash

OWNER="malleroid"
REPO=""

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2026-03-10" \
  /repos/$OWNER/$REPO/vulnerability-alerts

echo "Dependabot alerts enabled for $OWNER/$REPO"
