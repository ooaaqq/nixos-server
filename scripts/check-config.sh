#!/usr/bin/env bash

set -euo pipefail

root="$(git rev-parse --show-toplevel)"

bash -n "$root/scripts/check-config.sh"
shellcheck "$root/scripts/check-config.sh"
actionlint "$root/.github/workflows"/*.yml

mapfile -d '' -t nix_files < <(find "$root" -type f -name '*.nix' -print0)
nixfmt --check "${nix_files[@]}"

PYTHONPATH="$root${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m unittest discover -s "$root/tests" -p 'test_*.py'

nix flake check --no-build --accept-flake-config "git+file://$root"
