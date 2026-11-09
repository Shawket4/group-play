#!/usr/bin/env bash
# Regenerates the flutter_rust_bridge bindings: rust-core/crates/group-play-frb/src/api →
# packages/rust_bridge/lib/src/generated (Dart) + group-play-frb/src/frb_generated.rs (Rust).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WANT=2.13.0
HAVE="$(flutter_rust_bridge_codegen --version | awk '{print $2}')"
if [[ "$HAVE" != "$WANT" ]]; then
  echo "need flutter_rust_bridge_codegen $WANT (have $HAVE): cargo install flutter_rust_bridge_codegen --version $WANT --locked" >&2
  exit 1
fi
cd "$ROOT"
flutter_rust_bridge_codegen generate \
  --rust-input crate::api \
  --rust-root rust-core/crates/group-play-frb \
  --dart-output packages/rust_bridge/lib/src/generated \
  --dart-root packages/rust_bridge \
  --no-web
