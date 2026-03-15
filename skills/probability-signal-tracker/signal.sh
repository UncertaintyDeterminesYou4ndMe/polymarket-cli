#!/usr/bin/env bash
# Probability Signal Tracker
# Surfaces crowd-wisdom and insider signals from Polymarket prediction markets.
#
# Usage: ./signal.sh <command> [options]
# Commands: snapshot, diff, scan, watch, top

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DATA_DIR="${HOME}/.config/polymarket-signal-tracker"
mkdir -p "$DATA_DIR"

OUTPUT="${OUTPUT:-table}"   # Set OUTPUT=json for machine-readable output
CLI="polymarket"

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
die() { echo "Error: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "$1 is required but not installed."
}

snapshot_file() {
    local tag="${1:-_all}"
    echo "${DATA_DIR}/snapshot_${tag}.json"
}

# Extract the Yes probability (outcomePrices[0]) from a market JSON object.
# outcomePrices is stored as a JSON-encoded string: "[\"0.73\",\"0.27\"]"
prob_from_market() {
    echo "$1" | jq -r '
        .outcomePrices // "null"
        | if . == "null" then "null"
          else
            # outcomePrices may arrive as a pre-encoded string or as an array
            if type == "string" then fromjson else . end
            | if length > 0 then .[0] | tonumber else null end
          end
    '
}

# Compute signal_score = abs(shift) * log10(volume_24h + 1)
signal_score() {
    local shift="$1"
    local vol="$2"
    echo "$shift $vol" | awk '{
        s = $1; if (s < 0) s = -s
        v = $2 + 1
        score = s * log(v) / log(10)
        printf "%.4f", score
    }'
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_snapshot() {
    local tag="" limit=50
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)    tag="$2";    shift 2 ;;
            --limit)  limit="$2";  shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    require_cmd "$CLI"
    require_cmd jq

    echo "Fetching markets for snapshot..." >&2

    local markets
    if [[ -n "$tag" ]]; then
        markets=$(polymarket -o json markets trending --tag "$tag" --limit "$limit" 2>/dev/null)
    else
        markets=$(polymarket -o json markets trending --limit "$limit" 2>/dev/null)
    fi

    local file
    file=$(snapshot_file "${tag:-_all}")

    # Store markets with timestamp
    echo "$markets" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{timestamp: $ts, markets: .}' > "$file"

    local count
    count=$(echo "$markets" | jq 'length')
    echo "Snapshot saved: $count markets at $(date -u +%H:%M:%S UTC)" >&2
    echo "File: $file" >&2
}

cmd_diff() {
    local tag="" min_shift=0 limit=50
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)        tag="$2";        shift 2 ;;
            --min-shift)  min_shift="$2";  shift 2 ;;
            --limit)      limit="$2";      shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    require_cmd "$CLI"
    require_cmd jq

    local file
    file=$(snapshot_file "${tag:-_all}")
    [[ -f "$file" ]] || die "No snapshot found for tag '${tag:-_all}'. Run: ./signal.sh snapshot${tag:+ --tag $tag}"

    local snap_ts
    snap_ts=$(jq -r '.timestamp' "$file")

    echo "Comparing against snapshot from $snap_ts ..." >&2

    # Fetch current state
    local current
    if [[ -n "$tag" ]]; then
        current=$(polymarket -o json markets trending --tag "$tag" --limit "$limit" 2>/dev/null)
    else
        current=$(polymarket -o json markets trending --limit "$limit" 2>/dev/null)
    fi

    # Build lookup: slug -> current probability
    local current_lookup
    current_lookup=$(echo "$current" | jq '
        reduce .[] as $m ({};
            .[$m.slug // $m.id] = {
                prob: (
                    $m.outcomePrices // "null"
                    | if . == "null" then null
                      else (if type == "string" then fromjson else . end)
                           | if length > 0 then .[0] | tonumber else null end
                      end
                ),
                volume_24h: ($m.volume24hr // $m.volumeNum // 0 | tonumber? // 0),
                question: ($m.question // "")
            }
        )
    ')

    # Diff against snapshot
    local results
    results=$(jq -n \
        --argjson snap "$(jq '.markets' "$file")" \
        --argjson curr "$current_lookup" \
        --argjson min_shift "$min_shift" \
        '
        $snap | map(
            . as $m |
            ($m.slug // $m.id) as $slug |
            ($curr[$slug]) as $now |
            if $now == null then empty
            else
                ($m.outcomePrices // "null"
                 | if . == "null" then null
                   else (if type == "string" then fromjson else . end)
                        | if length > 0 then .[0] | tonumber else null end
                   end
                ) as $before |
                if $before == null or $now.prob == null then empty
                else
                    ($now.prob - $before) as $shift |
                    (if $shift < 0 then -$shift else $shift end) as $abs_shift |
                    if $abs_shift < $min_shift then empty
                    else {
                        slug: $slug,
                        question: ($m.question // ""),
                        prob_before: ($before * 100 | round / 100),
                        prob_now: ($now.prob * 100 | round / 100),
                        shift: ($shift * 100 | round / 100),
                        volume_24h: $now.volume_24h,
                        signal_score: ($abs_shift * (($now.volume_24h + 1) | log / (10 | log)) * 100 | round / 100)
                    }
                    end
                end
            end
        )
        | sort_by(-.signal_score)
        '
    )

    local count
    count=$(echo "$results" | jq 'length')

    if [[ "$OUTPUT" == "json" ]]; then
        echo "$results"
        return
    fi

    if [[ "$count" -eq 0 ]]; then
        echo "No probability shifts detected (min-shift=${min_shift})."
        return
    fi

    echo ""
    echo "Probability Shifts since $snap_ts"
    echo "──────────────────────────────────────────────────────────────────────"
    printf "%-8s  %-52s  %6s  %6s  %7s  %8s  %s\n" \
        "SHIFT" "QUESTION" "BEFORE" "NOW" "VOL 24H" "SCORE" "SLUG"
    echo "──────────────────────────────────────────────────────────────────────"

    echo "$results" | jq -r '.[] | [
        .shift, .question, .prob_before, .prob_now, .volume_24h, .signal_score, .slug
    ] | @tsv' | while IFS=$'\t' read -r shift question before now vol score slug; do
        # Format shift with + sign and colour
        local shift_fmt
        if (( $(echo "$shift > 0" | bc -l) )); then
            shift_fmt="+${shift}"
        else
            shift_fmt="$shift"
        fi

        # Truncate question
        local q
        q=$(echo "$question" | cut -c1-52)

        # Format volume
        local vol_fmt
        vol_fmt=$(echo "$vol" | awk '{
            if ($1 >= 1000000) printf "$%.1fM", $1/1000000
            else if ($1 >= 1000) printf "$%.1fK", $1/1000
            else printf "$%.0f", $1
        }')

        printf "%-8s  %-52s  %5.0f%%  %5.0f%%  %7s  %8s  %s\n" \
            "$shift_fmt" "$q" \
            "$(echo "$before * 100" | bc -l | xargs printf '%.0f')" \
            "$(echo "$now * 100" | bc -l | xargs printf '%.0f')" \
            "$vol_fmt" "$score" "$slug"
    done
    echo ""
}

cmd_scan() {
    local tag="" min_volume=0 limit=20
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)         tag="$2";        shift 2 ;;
            --min-volume)  min_volume="$2";  shift 2 ;;
            --limit)       limit="$2";       shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    require_cmd "$CLI"
    require_cmd jq

    echo "Scanning markets..." >&2

    local markets
    if [[ -n "$tag" ]]; then
        markets=$(polymarket -o json markets trending --tag "$tag" --limit 50 2>/dev/null)
    else
        markets=$(polymarket -o json markets trending --limit 50 2>/dev/null)
    fi

    # Compute signal score for each market:
    # score = volume_24h_normalized × conviction (distance of prob from 0.5)
    # High score = high activity + strong directional belief = interesting signal
    local results
    results=$(echo "$markets" | jq \
        --argjson min_vol "$min_volume" \
        --argjson limit "$limit" \
        '
        map(
            . as $m |
            (
                $m.outcomePrices // "null"
                | if . == "null" then null
                  else (if type == "string" then fromjson else . end)
                       | if length > 0 then .[0] | tonumber else null end
                  end
            ) as $prob |
            ($m.volume24hr // $m.volumeNum // 0 | tonumber? // 0) as $vol |
            if $prob == null or $vol < $min_vol then empty
            else
                (($prob - 0.5) | if . < 0 then -. else . end) as $conviction |
                ($vol | log / (10 | log)) as $log_vol |
                {
                    slug: ($m.slug // $m.id),
                    question: ($m.question // ""),
                    probability: ($prob * 100 | round),
                    volume_24h: $vol,
                    signal_score: ($conviction * $log_vol * 100 | round / 100)
                }
            end
        )
        | sort_by(-.signal_score)
        | .[:$limit]
        '
    )

    if [[ "$OUTPUT" == "json" ]]; then
        echo "$results"
        return
    fi

    local count
    count=$(echo "$results" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        echo "No markets found matching criteria."
        return
    fi

    echo ""
    echo "Top Probability Signals — $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "─────────────────────────────────────────────────────────────────────"
    printf "%-5s  %-54s  %6s  %8s  %s\n" "SCORE" "QUESTION" "PROB%" "VOL 24H" "SLUG"
    echo "─────────────────────────────────────────────────────────────────────"

    echo "$results" | jq -r '.[] | [.signal_score, .question, .probability, .volume_24h, .slug] | @tsv' \
    | while IFS=$'\t' read -r score question prob vol slug; do
        local q vol_fmt
        q=$(echo "$question" | cut -c1-54)
        vol_fmt=$(echo "$vol" | awk '{
            if ($1 >= 1000000) printf "$%.1fM", $1/1000000
            else if ($1 >= 1000) printf "$%.1fK", $1/1000
            else printf "$%.0f", $1
        }')
        printf "%-5s  %-54s  %5s%%  %8s  %s\n" "$score" "$q" "$prob" "$vol_fmt" "$slug"
    done
    echo ""
    echo "Signal score = conviction (|prob − 50%|) × log₁₀(24h volume)"
    echo ""
}

cmd_watch() {
    local slug="" interval=30
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug)      slug="$2";      shift 2 ;;
            --interval)  interval="$2";  shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$slug" ]] || die "--slug is required"
    require_cmd "$CLI"
    require_cmd jq

    echo "Watching: $slug  (polling every ${interval}s, Ctrl+C to stop)" >&2
    echo "─────────────────────────────────────────────────────────────────────"

    local last_prob=""
    while true; do
        local market prob vol_24h
        market=$(polymarket -o json markets get "$slug" 2>/dev/null) || { echo "Error fetching market." >&2; sleep "$interval"; continue; }

        prob=$(echo "$market" | jq -r '
            .outcomePrices // "null"
            | if . == "null" then "null"
              else (if type == "string" then fromjson else . end)
                   | if length > 0 then (.[0] | tonumber * 100 | round | tostring) + "%" else "null" end
              end
        ')
        vol_24h=$(echo "$market" | jq -r '(.volume24hr // .volumeNum // 0 | tonumber? // 0 | . * 100 | round / 100)')

        local ts
        ts=$(date -u '+%H:%M:%S UTC')

        if [[ "$prob" != "$last_prob" && -n "$last_prob" ]]; then
            printf "[%s]  P(Yes)=%-8s  Vol24h=%s  ← CHANGED\n" "$ts" "$prob" "$vol_24h"
        else
            printf "[%s]  P(Yes)=%-8s  Vol24h=%s\n" "$ts" "$prob" "$vol_24h"
        fi

        last_prob="$prob"
        sleep "$interval"
    done
}

cmd_top() {
    local tag="" limit=10
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)    tag="$2";    shift 2 ;;
            --limit)  limit="$2";  shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    require_cmd "$CLI"
    require_cmd jq

    local markets
    if [[ -n "$tag" ]]; then
        markets=$(polymarket -o json markets trending --tag "$tag" --limit "$limit" 2>/dev/null)
    else
        markets=$(polymarket -o json markets trending --limit "$limit" 2>/dev/null)
    fi

    if [[ "$OUTPUT" == "json" ]]; then
        echo "$markets"
        return
    fi

    echo ""
    echo "Top Markets by 24h Volume — $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "─────────────────────────────────────────────────────────────────────"
    printf "%-54s  %6s  %8s  %8s\n" "QUESTION" "PROB%" "VOL 24H" "TOTAL VOL"
    echo "─────────────────────────────────────────────────────────────────────"

    echo "$markets" | jq -r '
        .[] |
        (
            .outcomePrices // "null"
            | if . == "null" then "?"
              else (if type == "string" then fromjson else . end)
                   | if length > 0 then (.[0] | tonumber * 100 | round | tostring) else "?" end
              end
        ) as $prob |
        (.volume24hr // .volumeNum // 0 | tonumber? // 0) as $v24 |
        (.volumeNum // 0 | tonumber? // 0) as $vtot |
        [(.question // ""), $prob, $v24, $vtot] | @tsv
    ' | while IFS=$'\t' read -r question prob v24 vtot; do
        local q v24_fmt vtot_fmt
        q=$(echo "$question" | cut -c1-54)
        v24_fmt=$(echo "$v24" | awk '{
            if ($1 >= 1000000) printf "$%.1fM", $1/1000000
            else if ($1 >= 1000) printf "$%.1fK", $1/1000
            else printf "$%.0f", $1
        }')
        vtot_fmt=$(echo "$vtot" | awk '{
            if ($1 >= 1000000) printf "$%.1fM", $1/1000000
            else if ($1 >= 1000) printf "$%.1fK", $1/1000
            else printf "$%.0f", $1
        }')
        printf "%-54s  %5s%%  %8s  %8s\n" "$q" "$prob" "$v24_fmt" "$vtot_fmt"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: ./signal.sh <command> [options]

Commands:
  snapshot   Save current probabilities as baseline
  diff       Show probability shifts since last snapshot
  scan       Rank markets by signal strength (no baseline needed)
  watch      Continuously poll a single market for changes
  top        Show top markets by 24h volume with probabilities

Global env:
  OUTPUT=json    Output machine-readable JSON instead of table

Examples:
  ./signal.sh snapshot --tag politics
  ./signal.sh diff --tag politics --min-shift 0.05
  ./signal.sh scan --tag crypto --min-volume 50000
  ./signal.sh watch --slug will-trump-win-2024 --interval 60
  ./signal.sh top --tag politics --limit 10
  OUTPUT=json ./signal.sh scan --tag politics
EOF
}

[[ $# -gt 0 ]] || { usage; exit 0; }

COMMAND="$1"; shift
case "$COMMAND" in
    snapshot)  cmd_snapshot  "$@" ;;
    diff)      cmd_diff      "$@" ;;
    scan)      cmd_scan      "$@" ;;
    watch)     cmd_watch     "$@" ;;
    top)       cmd_top       "$@" ;;
    help|-h|--help) usage ;;
    *) die "Unknown command: $COMMAND. Run './signal.sh help' for usage." ;;
esac
