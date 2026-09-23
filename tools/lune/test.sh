#!/usr/bin/env bash
# The one command: install the pinned tools (checksum-verified), check the harness itself, build the place with
# Rojo and run every *Spec headless. Arguments go to run-tests.luau (e.g. --filter Core). See docs/HEADLESS_TESTS.md.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../.."
"$here/bootstrap.sh"
"$here/.bin/lune" run tools/lune/selftest
exec "$here/.bin/lune" run tools/lune/run-tests "$@"
