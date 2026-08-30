#!/usr/bin/env bash
# ==============================================================================
# Patch 8.1 §54-55 — Delivery ZIP packaging with explicit integrity
# guarantees.
#
# BACKGROUND (the bug this script exists to prevent): the most recently
# shipped delivery archive, gold-erp-phase8-reports-dashboard.zip, is
# MISSING both .env.example and next-env.d.ts entirely -- confirmed by
# direct `unzip -l` inspection during this session (zero matching entries).
# Both files exist correctly in the working tree; the loss happened
# ONLY in whatever ad-hoc packaging step produced that ZIP -- almost
# certainly because both filenames are matched by .gitignore patterns
# (`.env*` and the literal `next-env.d.ts` line) and packaging was done via
# a git-aware tool (e.g. `git archive`, or `zip -x@<(git ls-files --others
# -i --exclude-standard)`-style exclusion) that silently treats "ignored by
# git" as "excluded from the deliverable" -- which is correct for real
# secrets (.env.local, .env.production, etc. — none of which exist in this
# tree) but WRONG for .env.example (a committed-in-spirit template with
# zero real secrets) and next-env.d.ts (a small, harmless, needed-for-a-
# clean-checkout TypeScript reference file that Next.js itself generates,
# but which every prior delivery has shipped inside the ZIP regardless).
#
# This script builds the delivery ZIP directly from the filesystem via
# `zip -r` with an EXPLICIT exclude list (never .gitignore, never
# `git ls-files`) — so it can never again silently drop a file just because
# some *unrelated* gitignore rule happens to also match its name. The
# exclude list below is deliberately narrow and enumerated, not "anything
# git would ignore" — anyone editing this script must add new junk patterns
# ONE AT A TIME with a reason, rather than reintroducing "trust
# .gitignore" as a shortcut (that shortcut is exactly what caused this
# bug).
#
# Usage:
#   ./scripts/build_delivery_zip.sh <output.zip>
#
# Exits non-zero (before ever touching the output path) if .env.example or
# next-env.d.ts is missing from the working tree, or if either ends up
# missing from the produced archive — a hard integrity gate, not just a
# warning.
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_ZIP="${1:?Usage: $0 <output.zip>}"
case "$OUT_ZIP" in
  /*) ;;
  *) OUT_ZIP="$(pwd)/$OUT_ZIP" ;;
esac

echo "==> Pre-flight: confirming .env.example and next-env.d.ts exist in the working tree"
for f in .env.example next-env.d.ts; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f is missing from the working tree -- refusing to package (this is the exact defect §54-55 exists to catch)" >&2
    exit 1
  fi
done

rm -f "$OUT_ZIP"

echo "==> Building $OUT_ZIP via explicit zip -r with an enumerated exclude list (never .gitignore-driven)"
zip -r -X -q "$OUT_ZIP" . \
  -x "node_modules/*" \
  -x ".git/*" \
  -x ".next/*" \
  -x "out/*" \
  -x "build/*" \
  -x "coverage/*" \
  -x ".vercel/*" \
  -x "*.tsbuildinfo" \
  -x "npm-debug.log*" \
  -x "yarn-debug.log*" \
  -x "yarn-error.log*" \
  -x ".pnpm-debug.log*" \
  -x "*.DS_Store" \
  -x "*.pem" \
  -x ".env" \
  -x ".env.local" \
  -x ".env.development.local" \
  -x ".env.test.local" \
  -x ".env.production.local"

echo "==> Post-flight: confirming .env.example and next-env.d.ts landed in the archive"
for f in .env.example next-env.d.ts; do
  if ! unzip -l "$OUT_ZIP" | awk '{print $4}' | grep -qx "$f"; then
    echo "FATAL: $f did not end up in $OUT_ZIP despite passing pre-flight -- packaging is broken, do not ship this archive" >&2
    exit 1
  fi
done

FILE_COUNT="$(unzip -l "$OUT_ZIP" | tail -1 | awk '{print $2}')"
echo "==> SUCCESS: $OUT_ZIP built with $FILE_COUNT entries, .env.example + next-env.d.ts both confirmed present"
