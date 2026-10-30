#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tool_build="${GLODIN_TOOL_BUILD:-$repo_root/.tools}"
archive="$tool_build/gleam-v1.19.1.tar.gz"
mkdir -p "$tool_build/bin"
if [[ ! -f "$archive" ]]; then
  curl -L --fail --retry 3 https://codeload.github.com/gleam-lang/gleam/tar.gz/refs/tags/v1.19.1 -o "$archive"
fi
python3 - "$archive" <<'PY'
import hashlib, pathlib, sys
digest = hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()
assert digest == "5a717b4013d5599d73a99b3a1a4bb9168e62bfc18afff2f5bbab43244f860df0", "Gleam archive checksum mismatch"
PY
tar -xzf "$archive" -C "$tool_build"
python3 "$repo_root/scripts/patch_gleam.py" "$tool_build/gleam-1.19.1"
(
  cd "$tool_build/gleam-1.19.1"
  cargo build --release --locked -p gleam --target-dir "$tool_build/gleam-target"
)
cp "$tool_build/gleam-target/release/gleam" "$tool_build/bin/gleam.next"
mv "$tool_build/bin/gleam.next" "$tool_build/bin/gleam"
"$tool_build/bin/gleam" --version
