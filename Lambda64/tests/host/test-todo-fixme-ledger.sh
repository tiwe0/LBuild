#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd "$script_dir/../../.." && pwd)
scanner_source="$project_root/scripts/check-todo-fixme.py"
schema_source="$project_root/docs/modernization/todo-fixme/schema"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/lambda64-todo-fixme.XXXXXX")
trap 'rm -rf "$fixture"' EXIT

mkdir -p \
    "$fixture/scripts" \
    "$fixture/docs/modernization/todo-fixme/schema" \
    "$fixture/Lambda64/tests/host" \
    "$fixture/Lambda64/system" \
    "$fixture/Lambda64/doc/internals" \
    "$fixture/Lambda64/tools"
cp "$scanner_source" "$fixture/scripts/check-todo-fixme.py"
cp "$schema_source"/*.json "$fixture/docs/modernization/todo-fixme/schema/"
cp "$0" "$fixture/Lambda64/tests/host/test-todo-fixme-ledger.sh"
chmod +x "$fixture/scripts/check-todo-fixme.py" "$fixture/Lambda64/tests/host/test-todo-fixme-ledger.sh"

cat >"$fixture/Makefile" <<'EOF'
todo-fixme-check:
	@python3 scripts/check-todo-fixme.py --verify
EOF

python3 - "$fixture" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
(root / "Lambda64/system/inventory.lisp").write_text(
    "".join(f";; TODO fixture source requirement {number:03d}\n" for number in range(451)),
    encoding="utf-8",
)
(root / "Lambda64/doc/atomic-extensions.md").write_text(
    "".join(f"<!-- FIXME fixture documentation requirement {number} -->\n" for number in range(4)),
    encoding="utf-8",
)
records = []
for number in range(29):
    codepoint = f"{0x1800 + number:04X}"
    records.append(f"{codepoint};MONGOLIAN LETTER TODO FIXTURE {number:02d};Lo;0;L;;;;;N;;;;;\n")
(root / "Lambda64/tools/UnicodeData.txt").write_text("".join(records), encoding="utf-8")
(root / "Lambda64/system/product.bin").write_bytes(b"fixture-product-input\n")
PY

git -C "$fixture" init -q
git -C "$fixture" config user.name "Lambda64 scanner fixture"
git -C "$fixture" config user.email "scanner-fixture@example.invalid"
git -C "$fixture" add .
git -C "$fixture" commit -qm "scanner fixture baseline"
head=$(git -C "$fixture" rev-parse HEAD)

# The bootstrap index is the authoritative source baseline. Keep an ordinary
# product input staged before bootstrap so freeze would fail if it compared
# only against HEAD instead of the recorded index tree.
printf 'bootstrap index product input\n' >>"$fixture/Lambda64/system/product.bin"
git -C "$fixture" add Lambda64/system/product.bin

bootstrap_output=$(cd "$fixture" && python3 scripts/check-todo-fixme.py bootstrap --expected-head "$head")
python3 - "$fixture" "$bootstrap_output" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

root = Path(sys.argv[1])
result = json.loads(sys.argv[2])
assert result["status"] == "ok"
assert (result["raw"], result["source"], result["documentation"], result["data"]) == (484, 451, 4, 29)
authority = root / "docs/modernization/todo-fixme"
for name in ("occurrences.json", "unicode-allowlist.json", "baseline-snapshot.json"):
    data = (authority / name).read_bytes()
    value = json.loads(data.decode("utf-8"))
    canonical = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    assert data == canonical, name
ledger = json.loads((authority / "occurrences.json").read_text(encoding="utf-8"))
counts = {kind: sum(item["kind"] == kind for item in ledger["occurrences"])
          for kind in ("source", "documentation", "data-false-positive")}
assert counts == {"source": 451, "documentation": 4, "data-false-positive": 29}
PY

first_hashes=$(cd "$fixture" && sha256sum \
    docs/modernization/todo-fixme/occurrences.json \
    docs/modernization/todo-fixme/unicode-allowlist.json \
    docs/modernization/todo-fixme/baseline-snapshot.json)
rm "$fixture/docs/modernization/todo-fixme/occurrences.json" \
   "$fixture/docs/modernization/todo-fixme/unicode-allowlist.json" \
   "$fixture/docs/modernization/todo-fixme/baseline-snapshot.json"
(cd "$fixture" && python3 scripts/check-todo-fixme.py bootstrap --expected-head "$head" >/dev/null)
second_hashes=$(cd "$fixture" && sha256sum \
    docs/modernization/todo-fixme/occurrences.json \
    docs/modernization/todo-fixme/unicode-allowlist.json \
    docs/modernization/todo-fixme/baseline-snapshot.json)
test "$first_hashes" = "$second_hashes"

python3 - "$fixture/docs/modernization/todo-fixme" <<'PY'
from pathlib import Path
import json
import sys

authority = Path(sys.argv[1])
snapshot = json.loads((authority / "baseline-snapshot.json").read_text(encoding="utf-8"))
occurrences = json.loads((authority / "occurrences.json").read_text(encoding="utf-8"))["occurrences"]
baseline_id = snapshot["baseline-id"]
work_items = {
    "schema-version": 1,
    "baseline-id": baseline_id,
    "work-items": [
        {
            "id": "TF-WI-001",
            "title": "Fixture inventory work item",
            "risk": "low",
            "work-kind": "missing-feature",
            "contract-source": "fixture contract",
            "expected-behavior": "All actionable fixture markers remain explicitly mapped.",
            "acceptance-criteria": ["The scanner proves complete actionable coverage."],
            "required-test-levels": ["host"],
            "required-resource-ids": ["host-local"],
            "test-before": "The scanner fixture fails closed on missing links."
        }
    ]
}
links = [
    {"occurrence-id": item["id"], "work-item-id": "TF-WI-001", "relation": "implements"}
    for item in occurrences if item["kind"] != "data-false-positive"
]
mapping = {"schema-version": 1, "baseline-id": baseline_id, "links": sorted(links, key=lambda item: (item["occurrence-id"], item["work-item-id"], item["relation"]))}
ownership = {"schema-version": 1, "leases": []}
for name, value in (
    ("work-items.json", work_items),
    ("occurrence-work-items.json", mapping),
    ("ownership-leases.json", ownership),
):
    (authority / name).write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
git -C "$fixture" add docs/modernization/todo-fixme
git -C "$fixture" commit -qm "add fixture logical ledgers"

baseline_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["baseline-id"])' "$fixture/docs/modernization/todo-fixme/baseline-snapshot.json")

printf 'mutated-product-input\n' >>"$fixture/Lambda64/system/product.bin"
set +e
product_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py freeze-ledger --baseline-id "$baseline_id" 2>&1 >/dev/null)
product_status=$?
set -e
test "$product_status" -eq 5
printf '%s' "$product_error" | grep -q '"error-code":"PRODUCT_BASELINE_DRIFT"'
git -C "$fixture" checkout -q -- Lambda64/system/product.bin

python3 - "$fixture/Lambda64/system/inventory.lisp" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8").replace("TODO fixture source requirement 000", "TODO mutated source requirement 000", 1), encoding="utf-8")
PY
set +e
raw_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py freeze-ledger --baseline-id "$baseline_id" 2>&1 >/dev/null)
raw_status=$?
set -e
test "$raw_status" -eq 5
printf '%s' "$raw_error" | grep -q '"error-code":"RAW_SCAN_DRIFT"'
git -C "$fixture" checkout -q -- Lambda64/system/inventory.lisp

printf '\n' >>"$fixture/Lambda64/tools/UnicodeData.txt"
set +e
freeze_unicode_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py freeze-ledger --baseline-id "$baseline_id" 2>&1 >/dev/null)
freeze_unicode_status=$?
set -e
test "$freeze_unicode_status" -eq 6
printf '%s' "$freeze_unicode_error" | grep -q '"error-code":"UNICODE_INPUT_DRIFT"'
git -C "$fixture" checkout -q -- Lambda64/tools/UnicodeData.txt

echo "outside governance" >"$fixture/README.md"
git -C "$fixture" add README.md
git -C "$fixture" commit -qm "illegal non-governance drift"
set +e
scope_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py freeze-ledger --baseline-id "$baseline_id" 2>&1 >/dev/null)
scope_status=$?
set -e
test "$scope_status" -eq 5
printf '%s' "$scope_error" | grep -q '"error-code":"GOVERNANCE_PATH_NOT_ALLOWED"'
git -C "$fixture" reset --hard -q HEAD^

freeze_output=$(cd "$fixture" && python3 scripts/check-todo-fixme.py freeze-ledger --baseline-id "$baseline_id")
python3 - "$fixture" "$freeze_output" <<'PY'
from pathlib import Path
import json
import sys

root = Path(sys.argv[1])
result = json.loads(sys.argv[2])
assert result["status"] == "ok"
assert result["phase"] == "frozen"
assert result["actionable-occurrences"] == 455
assert result["logical-total"] == 1
snapshot = json.loads((root / "docs/modernization/todo-fixme/baseline-snapshot.json").read_text(encoding="utf-8"))
statuses = json.loads((root / "docs/modernization/todo-fixme/work-item-status.json").read_text(encoding="utf-8"))
assert snapshot["phase"] == "frozen"
assert snapshot["counts"]["logical-total"] == 1
assert statuses["statuses"][0]["status"] == "specified"
assert statuses["statuses"][0]["history"][0]["from"] is None
PY

set +e
refreeze_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py freeze-ledger --baseline-id "$baseline_id" 2>&1 >/dev/null)
refreeze_status=$?
set -e
test "$refreeze_status" -eq 6
printf '%s' "$refreeze_error" | grep -q '"error-code":"LEDGER_ALREADY_FROZEN"'

git -C "$fixture" add docs/modernization/todo-fixme
git -C "$fixture" commit -qm "freeze fixture authority"

immutable_before_transition=$(cd "$fixture" && sha256sum \
    docs/modernization/todo-fixme/baseline-snapshot.json \
    docs/modernization/todo-fixme/work-items.json \
    docs/modernization/todo-fixme/occurrence-work-items.json)
status_before_transition=$(sha256sum "$fixture/docs/modernization/todo-fixme/work-item-status.json")

set +e
wrong_from_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py status-transition \
    --work-item-id TF-WI-001 --from inventoried --to specified \
    --evidence-id EVIDENCE-wrong-from --actor fixture-verifier 2>&1 >/dev/null)
wrong_from_status=$?
set -e
test "$wrong_from_status" -eq 5
printf '%s' "$wrong_from_error" | grep -q '"error-code":"INVALID_STATUS_TRANSITION"'
test "$status_before_transition" = "$(sha256sum "$fixture/docs/modernization/todo-fixme/work-item-status.json")"

set +e
illegal_jump_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py status-transition \
    --work-item-id TF-WI-001 --from specified --to verified \
    --evidence-id EVIDENCE-illegal-jump --actor fixture-verifier 2>&1 >/dev/null)
illegal_jump_status=$?
set -e
test "$illegal_jump_status" -eq 5
printf '%s' "$illegal_jump_error" | grep -q '"error-code":"INVALID_STATUS_TRANSITION"'
test "$status_before_transition" = "$(sha256sum "$fixture/docs/modernization/todo-fixme/work-item-status.json")"

transition_output=$(cd "$fixture" && python3 scripts/check-todo-fixme.py status-transition \
    --work-item-id TF-WI-001 --from specified --to test-locked \
    --evidence-id EVIDENCE-test-locked --actor fixture-verifier)
python3 - "$transition_output" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
assert result["status"] == "ok"
assert result["phase"] == "status-transition"
item = result["work-item"]
assert item["status"] == "test-locked"
assert item["updated-by"] == "fixture-verifier"
assert item["evidence-ids"] == ["EVIDENCE-test-locked"]
assert item["history"][-1]["from"] == "specified"
assert item["history"][-1]["to"] == "test-locked"
PY
immutable_after_transition=$(cd "$fixture" && sha256sum \
    docs/modernization/todo-fixme/baseline-snapshot.json \
    docs/modernization/todo-fixme/work-items.json \
    docs/modernization/todo-fixme/occurrence-work-items.json)
test "$immutable_before_transition" = "$immutable_after_transition"

lease_output=$(cd "$fixture" && python3 scripts/check-todo-fixme.py lease-acquire \
    --lease-id LEASE-fixture-001 --holder fixture-executor \
    --work-item-id TF-WI-001 --target-file Lambda64/system/product.bin \
    --expires-at 2099-01-01T00:00:00Z)
python3 - "$lease_output" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
assert result["status"] == "ok"
lease = result["lease"]
assert lease["state"] == "active"
assert lease["work-item-ids"] == ["TF-WI-001"]
assert lease["target-files"] == ["Lambda64/system/product.bin"]
assert lease["target-pre-state"][0]["exists"] is True
PY
lease_hash_before_overlap=$(sha256sum "$fixture/docs/modernization/todo-fixme/ownership-leases.json")
set +e
overlap_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py lease-acquire \
    --lease-id LEASE-fixture-overlap --holder another-executor \
    --work-item-id TF-WI-001 --target-file Lambda64/system/product.bin \
    --expires-at 2099-01-01T00:00:00Z 2>&1 >/dev/null)
overlap_status=$?
set -e
test "$overlap_status" -eq 8
printf '%s' "$overlap_error" | grep -q '"error-code":"LEASE_OVERLAP"'
test "$lease_hash_before_overlap" = "$(sha256sum "$fixture/docs/modernization/todo-fixme/ownership-leases.json")"

cp "$fixture/docs/modernization/todo-fixme/ownership-leases.json" "$fixture/expired-lease-backup.json"
python3 - "$fixture/docs/modernization/todo-fixme/ownership-leases.json" <<'PY'
from pathlib import Path
import json
import sys
path = Path(sys.argv[1])
ledger = json.loads(path.read_text(encoding="utf-8"))
ledger["leases"][0]["expires-at"] = "2000-01-01T00:00:00Z"
path.write_text(json.dumps(ledger, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
set +e
expired_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py --verify 2>&1 >/dev/null)
expired_status=$?
set -e
test "$expired_status" -eq 8
printf '%s' "$expired_error" | grep -q '"error-code":"LEASE_EXPIRED"'
mv "$fixture/expired-lease-backup.json" "$fixture/docs/modernization/todo-fixme/ownership-leases.json"

printf 'staged base drift\n' >>"$fixture/Lambda64/system/product.bin"
git -C "$fixture" add Lambda64/system/product.bin
set +e
base_drift_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py --verify 2>&1 >/dev/null)
base_drift_status=$?
set -e
test "$base_drift_status" -eq 8
printf '%s' "$base_drift_error" | grep -q '"error-code":"LEASE_BASE_DRIFT"'
git -C "$fixture" reset -q HEAD -- Lambda64/system/product.bin
git -C "$fixture" checkout -q -- Lambda64/system/product.bin

printf 'target drift\n' >>"$fixture/Lambda64/system/product.bin"
set +e
target_drift_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py --verify 2>&1 >/dev/null)
target_drift_status=$?
set -e
test "$target_drift_status" -eq 8
printf '%s' "$target_drift_error" | grep -q '"error-code":"LEASE_TARGET_DRIFT"'
git -C "$fixture" checkout -q -- Lambda64/system/product.bin

close_output=$(cd "$fixture" && python3 scripts/check-todo-fixme.py lease-close \
    --lease-id LEASE-fixture-001 --evidence-id EVIDENCE-lease-close-001)
python3 - "$close_output" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
assert result["status"] == "ok"
assert result["lease"]["state"] == "closed"
assert result["lease"]["evidence-ids"] == ["EVIDENCE-lease-close-001"]
assert result["lease"]["target-post-state"][0]["exists"] is True
PY

second_lease_output=$(cd "$fixture" && python3 scripts/check-todo-fixme.py lease-acquire \
    --lease-id LEASE-fixture-002 --holder fixture-executor \
    --work-item-id TF-WI-001 --target-file Lambda64/system/product.bin \
    --expires-at 2099-01-01T00:00:00Z)
python3 - "$second_lease_output" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
assert result["status"] == "ok"
assert result["lease"]["lease-id"] == "LEASE-fixture-002"
assert result["lease"]["state"] == "active"
PY
implemented_output=$(cd "$fixture" && python3 scripts/check-todo-fixme.py status-transition \
    --work-item-id TF-WI-001 --from test-locked --to implemented \
    --evidence-id EVIDENCE-implemented --actor fixture-executor)
python3 - "$implemented_output" <<'PY'
import json
import sys
item = json.loads(sys.argv[1])["work-item"]
assert item["status"] == "implemented"
assert item["lease-ids"] == ["LEASE-fixture-002"]
PY
(cd "$fixture" && python3 scripts/check-todo-fixme.py lease-close \
    --lease-id LEASE-fixture-002 --evidence-id EVIDENCE-lease-close-002 >/dev/null)
verified_output=$(cd "$fixture" && python3 scripts/check-todo-fixme.py status-transition \
    --work-item-id TF-WI-001 --from implemented --to verified \
    --evidence-id EVIDENCE-verified --actor fixture-independent-verifier)
python3 - "$verified_output" <<'PY'
import json
import sys
item = json.loads(sys.argv[1])["work-item"]
assert item["status"] == "verified"
assert item["lease-ids"] == ["LEASE-fixture-002"]
assert item["updated-by"] == "fixture-independent-verifier"
PY

before_verify=$(cd "$fixture" && find docs/modernization/todo-fixme scripts/check-todo-fixme.py Lambda64/tests/host/test-todo-fixme-ledger.sh Makefile -type f -print0 | sort -z | xargs -0 sha256sum)
verify_output=$(cd "$fixture" && python3 scripts/check-todo-fixme.py --verify)
after_verify=$(cd "$fixture" && find docs/modernization/todo-fixme scripts/check-todo-fixme.py Lambda64/tests/host/test-todo-fixme-ledger.sh Makefile -type f -print0 | sort -z | xargs -0 sha256sum)
test "$before_verify" = "$after_verify"
python3 - "$verify_output" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
assert result["status"] == "ok"
assert result["phase"] == "verify"
assert result["unknown-untracked"] == 0
assert result["raw"] == 484
assert result["verified-logical"] == 1
PY

cat >"$fixture/Lambda64/system/unknown-untracked.lisp" <<'EOF'
(in-package :cl-user)
EOF
set +e
unknown_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py --verify 2>&1 >/dev/null)
unknown_status=$?
set -e
test "$unknown_status" -eq 7
printf '%s' "$unknown_error" | grep -q '"error-code":"UNKNOWN_UNTRACKED_SOURCE"'
rm "$fixture/Lambda64/system/unknown-untracked.lisp"

printf '\n' >>"$fixture/Lambda64/tools/UnicodeData.txt"
set +e
unicode_error=$(cd "$fixture" && python3 scripts/check-todo-fixme.py --verify 2>&1 >/dev/null)
unicode_status=$?
set -e
test "$unicode_status" -eq 6
printf '%s' "$unicode_error" | grep -q '"error-code":"UNICODE_ALLOWLIST_MISMATCH"'

echo "TODO/FIXME ledger scanner contract passed"
