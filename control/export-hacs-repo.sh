#!/bin/sh
# Turns the build output into a HACS-installable repository tree in <dir> (HACS needs custom_components/<domain>/
# at the repo ROOT and one integration per repo, so it cannot use this monorepo directly; see ../README.md).
#   sh control/export-hacs-repo.sh <dir>     <dir> = a clone of the HACS repo (an existing .git is left alone)
# Same files as dist/custom_components/panel_control, so dev HA, manual copy and HACS install identical code.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
[ $# -eq 1 ] || { sed -n 2,5p "$0"; exit 2; }
out=$1
sh "$here/build.sh" >/dev/null
mkdir -p "$out/custom_components"
rsync -a --delete "$here/dist/custom_components/" "$out/custom_components/"
printf '{\n  "name": "Panel Control",\n  "homeassistant": "2026.10.0"\n}\n' > "$out/hacs.json"
# relative links (../../contract/...) do not exist in the exported repo: point them at this monorepo on GitHub
base=https://github.com/h45h74x/homeassistant-panel/blob/main/control
sed "s#](\.\./\.\./#]($base/#g" "$here/custom_components/panel_control/README.md" > "$out/README.md"
ver=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$here/custom_components/panel_control/manifest.json")
# the checks HACS makes on a custom repository (structure, manifest keys, README)
dirs=$(ls "$out/custom_components")
[ "$(echo "$dirs" | wc -l)" = 1 ] || { echo "HACS allows exactly one integration directory, found: $dirs"; exit 1; }
for k in domain name version documentation issue_tracker codeowners; do
  grep -q "\"$k\"" "$out/custom_components/$dirs/manifest.json" || { echo "manifest.json lacks \"$k\" (HACS requires it)"; exit 1; }
done
echo "HACS repo tree ready in $out (integration $dirs, version $ver)"
echo "next: cd $out && git add -A && git commit -m 'v$ver' && git push && gh release create v$ver --generate-notes"
