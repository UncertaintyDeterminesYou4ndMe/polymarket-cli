# Probability Signal Tracker

Track real-time prediction market probabilities to surface crowd wisdom and insider signals.

Polymarket prices ARE probabilities — a Yes token trading at 0.73 means the market collectively
assigns 73% probability to the event. Large or sudden movements often precede news, making this
a leading indicator.

## What This Skill Does

- Fetches current probabilities for markets (by tag, keyword, or explicit market ID)
- Detects probability shifts by diffing against a stored baseline
- Flags markets with unusual 24h volume (potential insider activity)
- Ranks markets by signal strength: volume spike × price move
- Outputs structured JSON for agent consumption or human-readable table

## Installation

```bash
# Install the CLI
cd /path/to/polymarket-cli
cargo install --path .

# Install jq (required)
brew install jq          # macOS
apt-get install jq       # Ubuntu/Debian

# Make the script executable
chmod +x skills/probability-signal-tracker/signal.sh
```

## Quick Start

```bash
# Snapshot current probabilities (run once to establish baseline)
./signal.sh snapshot --tag politics

# Detect shifts since last snapshot
./signal.sh diff --tag politics

# Live scan: top signals right now (no baseline needed)
./signal.sh scan --tag politics --min-volume 50000

# Watch a specific market by slug
./signal.sh watch --slug will-trump-win-2024

# Full pipeline: snapshot → wait → diff
./signal.sh snapshot --tag politics && sleep 3600 && ./signal.sh diff --tag politics
```

## Commands

### `snapshot`
Save current probabilities as baseline for future diffing.

```bash
./signal.sh snapshot [--tag <SLUG>] [--limit <N>]

# Examples
./signal.sh snapshot --tag politics
./signal.sh snapshot --tag crypto --limit 30
./signal.sh snapshot                          # All trending markets
```

### `diff`
Compare current probabilities against the last snapshot. Prints markets where probability moved.

```bash
./signal.sh diff [--tag <SLUG>] [--min-shift <DECIMAL>] [--limit <N>]

# Examples
./signal.sh diff --tag politics               # Any shift
./signal.sh diff --tag politics --min-shift 0.05  # Only 5%+ moves
./signal.sh diff --min-shift 0.03 --limit 20
```

Output fields:
- `slug` — market identifier
- `question` — market question
- `prob_before` — probability at snapshot time (0–1)
- `prob_now` — current probability (0–1)
- `shift` — prob_now − prob_before (positive = Yes moving up)
- `volume_24h` — 24h trading volume in USD
- `signal_score` — abs(shift) × log10(volume_24h + 1), higher = stronger signal

### `scan`
No baseline needed. Ranks currently active markets by signal strength
(high 24h volume + price near 0 or 1 suggests resolution approaching).

```bash
./signal.sh scan [--tag <SLUG>] [--min-volume <USD>] [--limit <N>]

# Examples
./signal.sh scan --tag politics --min-volume 100000
./signal.sh scan --tag crypto --limit 10
./signal.sh scan --min-volume 500000              # High-conviction signals only
```

### `watch`
Continuous monitoring of a single market. Polls every N seconds and prints on change.

```bash
./signal.sh watch --slug <SLUG> [--interval <SECONDS>]

# Examples
./signal.sh watch --slug will-trump-win-2024
./signal.sh watch --slug us-recession-2025 --interval 60
```

### `top`
Show the highest-volume markets right now, grouped by tag, with probabilities.

```bash
./signal.sh top [--limit <N>] [--tag <SLUG>]

# Examples
./signal.sh top --limit 5
./signal.sh top --tag politics --limit 10
```

## Signal Interpretation

### Volume Spike + Stable Price
- Crowd is actively trading but not moving the needle
- Suggests strong two-sided belief — market is at fair value
- Signal: low urgency

### Volume Spike + Price Moving Toward 1.0 (or 0.0)
- Smart money is piling in on one side
- Classic insider signal — someone knows something
- Signal strength ⭐⭐⭐⭐⭐

### Low Volume + Extreme Price (>0.90 or <0.10)
- Market has essentially resolved in the crowd's mind
- Late-stage information, limited trading opportunity
- Signal: informational only

### Sudden Shift With No News
- Price moved faster than public information allows
- Most reliable insider indicator on Polymarket
- Signal strength ⭐⭐⭐⭐⭐

### New Market Accumulating Volume Quickly
- High-attention event, market is bootstrapping
- Early-mover advantage in price discovery
- Signal strength ⭐⭐⭐⭐

## Agent Integration

This skill is designed to be called by an agent. All commands support `-o json` output
via the underlying CLI, and the script outputs clean JSON when `OUTPUT=json` is set.

```bash
# Agent-friendly JSON output
OUTPUT=json ./signal.sh scan --tag politics --min-volume 50000

# Example agent prompt use:
# "Run the probability signal tracker for politics markets and tell me
#  which markets show the strongest insider signal this hour."
```

### Recommended Agent Workflow

1. **Morning scan** — `scan --tag politics --min-volume 100000` to see overnight moves
2. **Hourly diff** — `snapshot` then `diff --min-shift 0.03` to catch intraday shifts
3. **Event-driven** — `watch --slug <specific-market>` when tracking a known event
4. **Discovery** — `top --tag crypto` to find new high-activity markets

## Data Sources

All data comes from the Polymarket Gamma API (read-only, no authentication needed):
- Market probabilities: derived from `outcomePrices[0]` (Yes token price = P(Yes))
- Volume: `volumeNum` (total) and `volume24hr` (24h rolling)
- Markets are fetched via `polymarket markets trending` and `polymarket markets list`

## Notes

- Probabilities reflect the **marginal trader's belief**, not a simple average
- Polymarket has geographic restrictions; prices are still publicly readable
- 24h volume data may have a few minutes of lag
- This is a signal tool, not financial advice
