#!/usr/bin/env bash
# Gathers what explains a failed build into $EVIDENCE_DIR: the log of each failed
# derivation, the text files the build wrote in its kept build directory, macOS crash
# reports and sandbox denials since the build started, and the platform versions.
set -uo pipefail

evidence="${EVIDENCE_DIR:?}"
start="$evidence/.build-start"
log="$evidence/build.log"
max_file_kb=2048
max_dir_mb=50
cd "$evidence" || exit 1

{
  echo "system: ${SYSTEM:-}"
  uname -a
  nix --version
  nix config show sandbox 2> /dev/null | sed 's/^/sandbox: /'
  if [[ $(uname) == Darwin ]]; then
    sw_vers
    echo "xcode: $(xcode-select -p 2> /dev/null)"
    echo "sdk: $(xcrun --show-sdk-version 2> /dev/null)"
  fi
} > platform.txt 2>&1

# Derivations nix reports as failed ("builder for '…' failed" before Nix 2.29,
# "Cannot build '…'" after); those that failed only through a dependency have no log.
grep -E "(builder for|Cannot build) ['\"][^'\"]+\.drv['\"]|Reason: " "$log" > failed.txt
mkdir -p logs
grep -oE "/nix/store/[^'\"]+\.drv" failed.txt | sort -u | while read -r drv; do
  out="logs/$(basename "$drv" .drv).log"
  nix log "$drv" > "$out" 2> /dev/null || rm -f "$out"
done

# Text files the build created or changed (unpacked sources keep their old mtimes),
# without Cargo/git/npm internals, each up to 2 MiB.
mkdir -p builddirs
grep -oE "keeping build directory ['\"][^'\"]+" "$log" | sed -E "s/.*['\"]//" | sort -u | while read -r dir; do
  # The last path component alone repeats (Linux: …/nix-<id>/build), so name it by two.
  out="builddirs/$(basename "$(dirname "$dir")")-$(basename "$dir").tar.gz"
  sudo find "$dir" \( -name incremental -o -name .fingerprint -o -name deps -o -name .git -o -name node_modules \) -prune \
    -o -type f -newer "$start" -size -"${max_file_kb}"k -print0 \
    | sudo xargs -0 grep -I --null -l '' 2> /dev/null \
    | sudo tar --null -T - -czf "$out" 2> /dev/null
  [[ -n $(tar -tzf "$out" 2> /dev/null | head -n 1) ]] || { rm -f "$out"; continue; }
  if (( $(du -m "$out" | cut -f1) > max_dir_mb )); then
    # shellcheck disable=SC2024 # the list goes to our own directory
    sudo find "$dir" -type f -newer "$start" > "${out%.tar.gz}.files.txt"
    rm -f "$out"
  fi
done

if [[ $(uname) == Darwin ]]; then
  mkdir -p crashes
  for d in /Library/Logs/DiagnosticReports ~/Library/Logs/DiagnosticReports /var/root/Library/Logs/DiagnosticReports; do
    sudo find "$d" -type f -newer "$start" -exec cp {} crashes/ \; 2> /dev/null
  done
  since=$(date -r "$(cat "$start")" '+%Y-%m-%d %H:%M:%S')
  # Most denials come from macOS's own services; the per-process count on top shows
  # the build's processes (bash, coreutils, the package's binaries) at a glance.
  sudo log show --style compact --start "$since" --predicate 'sender == "Sandbox"' 2> /dev/null \
    | grep -i deny | tail -n 5000 > denials.tmp
  {
    echo "# denials per process"
    grep -oE 'Sandbox: [^(]+' denials.tmp | sed 's/^Sandbox: //' | sort | uniq -c | sort -rn
    echo
    cat denials.tmp
  } > sandbox-denials.txt
  rm -f denials.tmp
fi

sudo chown -R "$(id -u)" . 2> /dev/null
gzip -f build.log
find . -type d -empty -delete
echo "evidence: $(du -sh . | cut -f1) in $evidence"
