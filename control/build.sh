#!/bin/sh
# Builds the one output that is installed everywhere (dev HA, a real HA by copy, or a release asset):
#   control/dist/custom_components/panel_control/   copy this folder into <HA config>/custom_components/
#   control/dist/panel_control.zip                  same files at the zip root (HACS zip_release layout)
# Deterministic (sorted, fixed mtimes in the zip) so two builds of the same tree are byte-identical.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
src="$here/custom_components/panel_control"
out="$here/dist"
rm -rf "$out"
mkdir -p "$out/custom_components"
rsync -a --exclude '__pycache__' --exclude '*.pyc' "$src/" "$out/custom_components/panel_control/"
(cd "$out/custom_components/panel_control" && find . -type f | sort | sed 's|^\./||' \
  | TZ=UTC xargs -r touch -d '2020-01-01 00:00:00' \
  && find . -type f | sort | sed 's|^\./||' | zip -q -X -@ "$out/panel_control.zip")
echo "built $out/custom_components/panel_control ($(find "$out/custom_components" -type f | wc -l) files)"
echo "built $out/panel_control.zip ($(wc -c < "$out/panel_control.zip") bytes)"
