#!/usr/bin/env bash
# Builds the Saturn Remote web client (web/) into SaturnCore's bundled resources.
# The output is committed, so Xcode builds don't need Node.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/Packages/SaturnCore/Sources/SaturnCore/Resources/Remote/dist"

cd "$root/web"
npm ci
npm run build

rm -rf "$out"
mkdir -p "$(dirname "$out")"
cp -R "$root/web/dist" "$out"
echo "Built the remote web client into ${out#"$root"/}"
