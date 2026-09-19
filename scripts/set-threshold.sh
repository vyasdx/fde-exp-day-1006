#!/usr/bin/env bash
# Change the wire approval threshold. Data only — no code path is touched.
# Usage: ./scripts-set-threshold.sh 500.00
set -uo pipefail
NEW="${1:?usage: $0 <dollars, e.g. 500.00>}"
POLICY=governance/policy.yaml
TMPL=.azure/container-app.tmpl.yaml

OLD=$(grep -oE '^  wire_transfer_threshold: [0-9.]+' "$POLICY" | awk '{print $2}')
echo "threshold: $OLD -> $NEW"

sed -i -E "s/^  wire_transfer_threshold: [0-9.]+/  wire_transfer_threshold: $NEW/" "$POLICY"
python - "$TMPL" "$NEW" <<'PY'
import io,re,sys
p,new=sys.argv[1],sys.argv[2]
s=io.open(p,encoding="utf-8").read()
s=re.sub(r'(- name: FDE_WIRE_TRANSFER_THRESHOLD\n\s+value: ")[0-9.]+(")', r'\g<1>'+new+r'\g<2>', s)
io.open(p,"w",encoding="utf-8").write(s)
PY

echo "--- lockstep ---"
grep -h "wire_transfer_threshold: " "$POLICY"
grep -A1 "FDE_WIRE_TRANSFER_THRESHOLD" "$TMPL" | grep value:
echo "--- no digit in any comment above the setting? ---"
grep -nE "threshold|transfer|wire" "$POLICY" | grep -E ":.*[0-9]" | grep -v "wire_transfer_threshold: " || echo "(clean)"
echo "--- what the eval will resolve ---"
dotnet run --no-build --configuration Release --project eval/EvalRunner -- milestone3 --url "http://127.0.0.1:9" --policy "$POLICY" 2>&1 | grep -E "^\[m3\] threshold" | head -1 || true
