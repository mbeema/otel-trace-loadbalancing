#!/usr/bin/env bash
# ============================================================================
# PROOF: trace-id pinning. The decisive PoC test.
#
# Pulls the detailed debug logs from each gateway pod, extracts the set of
# trace IDs each pod actually received, and checks the one property that the
# whole architecture rests on:
#
#     NO trace ID may appear on more than one gateway pod.
#
# If a trace were split across two gateways, tail_sampling on either pod would
# see an incomplete trace. Zero splits == the loadbalancing exporter pinned
# every span of a trace to a single gateway. That is the claim, verified.
# ============================================================================
set -euo pipefail
NS=observability
SEL=app=otel-gateway
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pods=$(kubectl -n "$NS" get pods -l "$SEL" -o jsonpath='{.items[*].metadata.name}')
[ -z "$pods" ] && { echo "No gateway pods found in ns/$NS"; exit 1; }

echo "== Trace IDs received per gateway pod =="
i=0
for p in $pods; do
  i=$((i+1))
  kubectl -n "$NS" logs "$p" --tail=-1 2>/dev/null \
    | grep -Eo 'Trace ID *: *[0-9a-f]{32}' \
    | grep -Eo '[0-9a-f]{32}' \
    | sort -u > "$tmp/pod-$i.ids"
  printf "  %-45s %5s distinct trace IDs\n" "$p" "$(wc -l < "$tmp/pod-$i.ids" | tr -d ' ')"
done

cat "$tmp"/pod-*.ids | sort -u > "$tmp/all.ids"
total=$(wc -l < "$tmp/all.ids" | tr -d ' ')
echo "  ----"
echo "  TOTAL distinct trace IDs across all gateways: $total"

# A trace ID appearing in >1 pod's (already-deduped) file = a split.
splits=$(cat "$tmp"/pod-*.ids | sort | uniq -d)
nsplit=$(printf '%s' "$splits" | grep -c . || true)

echo
if [ "$total" -eq 0 ]; then
  echo "⚠️  No trace IDs found in logs yet. Did the telemetrygen Job run and finish?"
  echo "   (tail_sampling decision_wait is 10s — wait, then re-run.)"
  exit 2
elif [ "$nsplit" -eq 0 ]; then
  echo "✅ PASS — $total traces, ZERO split across gateways."
  echo "   Every span of every trace was pinned to a single gateway. routing_key:traceID works."
else
  echo "❌ FAIL — $nsplit trace IDs landed on more than one gateway (split traces):"
  printf '%s\n' "$splits" | head
  exit 1
fi
