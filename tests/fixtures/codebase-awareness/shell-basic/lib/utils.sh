#!/usr/bin/env bash
set -euo pipefail

# Weak shared-name fixture: this file should not become a reusable helper
# candidate from its lib/ path alone.
UTILITY_FIXTURE_NAME="weak-only"
