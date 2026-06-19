#!/usr/bin/env bash
# Proof for the e2e-elastic PoC: every trace lands on exactly ONE gateway pod.
# Reads each gateway's detailed debug logs and fails if any trace ID shows up
# on more than one pod (= a split trace = tail sampling would be wrong).
set -euo pipefail
NS=${NS:-otel-poc}
SEL=app=otel-gateway
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

pods=$(kubectl -n "$NS" get pods -l "$SEL" -o jsonpath='{.items[*].metadata.name}')
[ -z "$pods" ] && { echo "No gateway pods in ns/$NS"; exit 1; }

echo "== Trace IDs received per gateway pod (ns/$NS) =="
i=0
for p in $pods; do
  i=$((i+1))
  kubectl -n "$NS" logs "$p" --tail=-1 2>/dev/null \
    | grep -Eo 'Trace ID *: *[0-9a-f]{32}' | grep -Eo '[0-9a-f]{32}' \
    | sort -u > "$tmp/pod-$i.ids"
  printf "  %-45s %5s distinct trace IDs\n" "$p" "$(wc -l < "$tmp/pod-$i.ids" | tr -d ' ')"
done

total=$(cat "$tmp"/pod-*.ids | sort -u | wc -l | tr -d ' ')
splits=$(cat "$tmp"/pod-*.ids | sort | uniq -d)
nsplit=$(printf '%s' "$splits" | grep -c . || true)
echo "  ----"; echo "  TOTAL distinct trace IDs: $total"; echo

if   [ "$total" -eq 0 ];  then echo "⚠️  No trace IDs yet — is the demo running? give it ~30s + tail_sampling decision_wait."; exit 2
elif [ "$nsplit" -eq 0 ]; then echo "✅ PASS — $total traces, ZERO split across gateways. routing_key:traceID holds."
else echo "❌ FAIL — $nsplit split trace IDs:"; printf '%s\n' "$splits" | head; exit 1; fi
