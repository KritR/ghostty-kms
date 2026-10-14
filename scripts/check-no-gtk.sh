#!/usr/bin/env bash
# Check that building ghostty-kms neither fetches nor builds GTK or its
# neighbours (glib/GObject, GStreamer, X11, Wayland, cairo, ...), and that
# none of them end up in its runtime closure.
#
# What a build pulls in: for each input derivation, if its outputs are in
# the binary cache they're downloaded, so their runtime closure counts;
# otherwise (our slimmed overrides, the filtered Zig cache) they're built
# here, so we recurse into their inputs. The build history of unmodified,
# cached nixpkgs packages doesn't count; that's not something we fetch.
#
# The runtime closure is also enforced on every build by
# disallowedRequisites in flake.nix.
#
# Usage: scripts/check-no-gtk.sh [system]   (default x86_64-linux)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
system="${1:-x86_64-linux}"
attr="$root#packages.$system.ghostty-kms"
cache="https://cache.nixos.org"

# Store path names that count as GTK or adjacent. (The libX11 *source*
# tarball, libX11-<v>.tar.xz, is allowed: xlocale-data generates Compose
# tables from it.)
pattern='^/nix/store/[a-z0-9]{32}-(gtk4|gtk\+?3|gtk4-layer-shell|gtk4_layer_shell|libadwaita|gobject-introspection(-wrapped)?|gobject|glib|gsettings-desktop-schemas|gstreamer|gst-plugins-[a-z]+|wrap-gapps-hook[0-9]*|blueprint-compiler|pango|cairo|gdk-pixbuf|libx11|libxcb|libxext|wayland|wayland-protocols|wayland-scanner|libwacom|libgudev|zig_wayland|plasma_wayland_protocols)([-.][0-9].*)?(\.drv)?$'

hits=()
seen="$(mktemp)"
trap 'rm -f "$seen"' EXIT

check() {
  local path="$1" via="$2"
  if [[ "$path" =~ $pattern ]]; then
    hits+=("$path  (via $via)")
  fi
}

visit() {
  local drv="$1" via="$2"
  grep -qxF "$drv" "$seen" && return
  echo "$drv" >> "$seen"
  local d outs closure
  for d in $(nix-store -q --references "$drv" | grep '\.drv$'); do
    check "$d" "$via"
    outs="$(nix-store -q --outputs "$d")"
    # shellcheck disable=SC2086
    if closure="$(nix path-info -r --store "$cache" $outs 2>/dev/null)"; then
      for p in $closure; do check "$p" "$via > ${d#/nix/store/*-}"; done
    else
      visit "$d" "$via > ${d#/nix/store/*-}"
    fi
  done
}

fail=0
drv="$(nix eval --raw "$attr.drvPath")"
visit "$drv" "ghostty-kms"
if [ "${#hits[@]}" -gt 0 ]; then
  echo "FAIL: building $system ghostty-kms pulls in:"
  printf '  %s\n' "${hits[@]}" | sort -u
  fail=1
else
  echo "ok: building ghostty-kms ($system) fetches/builds nothing GTK-adjacent ($(wc -l < "$seen" | tr -d ' ') derivations built here)"
fi

if out="$(nix build "$attr" --no-link --print-out-paths 2>/dev/null)"; then
  # shellcheck disable=SC2086
  if runtime="$(nix path-info -r $out | grep -E "$pattern")"; then
    echo "FAIL: runtime closure includes:"
    echo "$runtime" | sed 's/^/  /'
    fail=1
  else
    echo "ok: runtime closure is clean ($(nix path-info -Sh "$(echo "$out" | head -1)" | awk '{print $2, $3}'))"
  fi
else
  echo "FAIL: ghostty-kms didn't build (disallowedRequisites rejects GTK-family references)"
  fail=1
fi
exit $fail
