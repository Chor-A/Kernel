#!/usr/bin/env bash
set -euo pipefail

# Mirror the ReSukiSU ksud binaries from the latest successful GitHub
# Actions run into ksu-<artifact>.zip files, ready for the durable prebuilts
# release. build-kernel.yml consumes these via kernelsu-fetch.sh's
# KSU_PREBUILT_BASE fallback, which expects ksu-<artifact>.zip naming, so the
# 90-day actions-artifact expiry never blocks a kernel build.
#
# ReSukiSU is built into the Templar kernel source itself, so only ksud is
# mirrored (it swaps the kernel image on device).
#
# Outputs are written to OUT_DIR (default: ./ksu-assets):
#   ksu-ksud-aarch64-linux-android.zip ksu-ksud-armv7-linux-androideabi.zip

# ==> SETTINGS FOR RESUKISU INTEGRATION <==
KSU_OWNER=${KSU_OWNER:-ReSukiSU}
KSU_REPO=${KSU_REPO:-ReSukiSU}
KSU_BRANCH=${KSU_BRANCH:-main} # ReSukiSU uses 'main', not 'master'
KSU_WANT=${KSU_WANT:-'ksud-*'}
OUT_DIR=${OUT_DIR:-$PWD/ksu-assets}
GITHUB_TOKEN=${GITHUB_TOKEN:-}

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }
# Bound only the connect phase: a hanging endpoint otherwise stalls on the host
# TCP connect timeout (~130s) x --retry 3 between GitHub API calls.
curl_dl() { curl --connect-timeout 10 "$@"; }

[ -n "$GITHUB_TOKEN" ] || die "GITHUB_TOKEN is required (GitHub denies unauthenticated artifact downloads)"

API="https://api.github.com/repos/$KSU_OWNER/$KSU_REPO"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")

want() {
    local n=$1 p
    IFS='|' read -ra pats <<< "$KSU_WANT"
    for p in "${pats[@]}"; do
        case "$n" in
            $p) return 0 ;;
        esac
    done
    return 1
}

mkdir -p "$OUT_DIR"
run_ids=()
for page in 1 2 3 4 5; do
    mapfile -t ids < <(curl_dl -sfL "${AUTH[@]}" \
        "$API/actions/runs?branch=$KSU_BRANCH&status=success&per_page=10&page=$page" | \
        python3 -c "import json,sys; print('\n'.join(str(r['id']) for r in json.load(sys.stdin).get('workflow_runs',[])))")
    # python print() emits a trailing newline even for an empty run list, so
    # mapfile yields ("", ...) rather than an empty array; drop empty lines so
    # the page-empty check below actually fires on past-the-end pages.
    page_ids=()
    for id in "${ids[@]}"; do
        [ -n "$id" ] && page_ids+=("$id")
    done
    [ "${#page_ids[@]}" -eq 0 ] && break
    run_ids+=("${page_ids[@]}")

    # Runs come back newest-first; the newest run with the wanted artifacts is
    # the only one consumed. Check each page before fetching the next so a
    # match on the first page short-circuits the remaining pages instead of
    # eagerly paginating all 50 runs.
    for run_id in "${page_ids[@]}"; do
        # Parse "name id" pairs in one call; the artifact ids needed for the
        # download URLs are already in this response, so no per-name re-query.
        mapfile -t art < <(curl_dl -sfL "${AUTH[@]}" \
            "$API/actions/runs/$run_id/artifacts?per_page=100" | \
            python3 -c "import json,sys; print('\n'.join(f\"{a['name']} {a['id']}\" for a in json.load(sys.stdin).get('artifacts',[])))")
        matched=()
        matched_ids=()
        for pair in "${art[@]}"; do
            n=${pair%% *}
            id=${pair#* }
            want "$n" || continue
            matched+=("$n")
            matched_ids+=("$id")
        done
        [ "${#matched[@]}" -gt 0 ] || { info "run $run_id has no wanted artifacts, skipping"; continue; }

        ok "using run $run_id ($KSU_OWNER/$KSU_REPO @ $KSU_BRANCH)"
        # The matched artifacts are independent and network-bound; overlap the
        # downloads instead of serializing each zip's round-trip.
        dl_pids=()
        dl_rc=0
        for i in "${!matched[@]}"; do
            n=${matched[$i]}
            aid=${matched_ids[$i]}
            [ -n "$aid" ] || die "artifact '$n' not found in run $run_id"
            ( curl_dl -fL --retry 3 -sS -o "$OUT_DIR/ksu-$n.zip" \
                -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
                "$API/actions/artifacts/$aid/zip" &&
                ok "ksu-$n.zip" ) & dl_pids+=("$!")
        done
        for dl_pid in "${dl_pids[@]}"; do
            wait "$dl_pid" || dl_rc=1
        done
        [ "$dl_rc" -eq 0 ] || die "one or more ksud artifact downloads failed"
        exit 0
    done
done
[ "${#run_ids[@]}" -gt 0 ] || die "no successful $KSU_OWNER/$KSU_REPO runs on $KSU_BRANCH"

die "no successful run with wanted artifacts on $KSU_BRANCH"
