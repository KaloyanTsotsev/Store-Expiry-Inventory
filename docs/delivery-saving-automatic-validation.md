# Delivery saving and automatic validation — 11 November 2026

## Findings

The editor still required `item.checked` in `allReviewed`, while inline edits reset that flag. Correcting all fields therefore did not enable finalization until a separate selection/review action was performed. Server failures appeared at the top of a long scrollable form. Capability probing could also fail after cancelling autosave, before preserving the latest corrections.

Read-only inspection of the deployed PocketBase 0.40.4 at `192.168.100.46:8090` found the legacy stage/photo/status/finalize routes, but **not** `/api/store/deliveries/{id}/finalize-by-code`. The newer Flutter client uses that route for exact `products.barcode` identity. A client-only update cannot make the missing route persist deliveries. Falling back to the old name-based finalizer would risk incorrect product matching.

The three intentionally removed product fields (`active`, `aliases`, `supplier_identifiers`) stay removed. Existing prepared runtime files already support their absence. No schema migration, API Rule change, Catalog deployment, or OCR service change is required for this repair.

## Implemented client changes

- `lib/models/delivery_draft.dart`: readiness is derived from valid fields and processed pages, separately from final human confirmation.
- `lib/screens/delivery_editor_screen.dart`: no row selection/review step; automatic Ready/Needs correction counts, correction shortcut, sticky **Запази доставката**, loading, visible error/result, and durable local saving before network probing. Final Save confirms valid rows. Retries preserve the frozen packet and operation key; a committed receipt is saved locally without resubmitting inventory.
- `lib/widgets/bulk_review_row.dart`: automatic row status and field errors. No normal-flow checkbox. Suggested quantity is still described as unconfirmed until final Save.
- `lib/widgets/expiry_date_field.dart`: numeric DMY formatting with cursor/deletion handling; explicit slash/dash/ISO formats accepted. The existing calendar picker remains intact. Validation rejects impossible or incomplete dates; persistence uses `yyyy-MM-dd` as before.
- `lib/services/delivery_finalization_service.dart`: automatic validity replaces selection as eligibility; bounded request waits; require a matching receipt for every requested row, including product, batch and movement IDs for positive quantities. HTTP 200/status alone is insufficient.

Tests changed/added: `test/automatic_delivery_validation_test.dart`, `test/finalization_test.dart`, `test/finalization_http_test.dart`, `test/storeflow_workflow_test.dart`, `test/ux_v3_widget_test.dart`, `test/backend_v2_http_test.dart`. Added the supplied redacted original `test/fixtures/paddle/document.jpg` and documented it in that directory's README.

## Actual persistence verification

`flutter analyze --no-pub`, `flutter test --no-pub`, and:

```powershell
& 'C:\Users\cocev\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' backend/tool/test_backend.py --catalog --without-product-fields --flutter
```

Results: analysis reported no issues; the general Flutter suite passed 129 tests (4 localhost integration tests are intentionally skipped outside the harness). The harness passed all 3 delivery SDK tests, 16 transaction/security scenarios, the direct-code/no-removed-fields checks, and 6 Paddle proxy scenario groups. It did not run the legacy Catalog SDK test in this schema configuration.

The last command starts a **real isolated localhost PocketBase 0.40.4**, not an HTTP mock. It does not contact production. It uses synthetic accounts and a copy of the schema without the three removed fields.

The real Paddle response supplies 37 rows and 23 valid dates. The test explicitly substitutes synthetic employee-confirmed dates for the remaining 14; it never infers dates from `1`. It uploads the original supplied JPEG, stages the full OCR evidence, reuses one previously established product, saves all 37 batches, reads back exact codes/quantities/dates, checks dashboard retrieval and completed local/server status, and repeats the same request without duplicates. The earlier delivery's quantity/date stay unchanged.

The harness also verifies real transaction rollback, concurrent authenticated requests, authorization, leading zeroes, separate deliveries/batches, unchanged legacy data, and Paddle proxy behavior. General Flutter tests skip the localhost-only live tests; the harness runs them separately. Logs: `build/automatic-validation-analyze.log`, `build/automatic-validation-tests.log`, `build/automatic-validation-backend.log`.

This verifies persistence in the isolated environment. It **does not** verify a newly scanned phone delivery against production. The production hook deployment and phone acceptance test remain outstanding. No APK was rebuilt or installed during this repair.

## Minimal deployment package, requiring approval

`build/backend-repair/releases/storeflow-delivery-saving.tar.gz` contains only these already integration-tested runtime files, this document and checksums:

```text
pb_hooks/delivery_finalize.pb.js
pb_hooks/lib/handlers.js
pb_hooks/lib/delivery_finalization.js
pb_hooks/lib/pocketbase_store.js
```

It preserves the existing legacy finalizer and adds exact-code finalization and safe draft discard. It does not contain migrations, Catalog hooks, expiry handling hooks, OCR hooks, service files, databases, credentials or installers. The optional expiry capability stays false if its separately deployed implementation is absent. Never replace the entire `pb_hooks` directory: preserve the working Paddle proxy and all other hooks.

**Do not execute the stop/copy/start steps before the owner approves the maintenance window and this exact four-file replacement.** This follows the owner's explicit restriction on production changes.

1. Copy the archive and its `.sha256` to a new directory on OnePlus, e.g. `/home/user/storeflow-releases/delivery-saving-20261111`. Verify the external checksum there, inspect `tar -tzf`, extract, then run `sha256sum -c SHA256SUMS` in the extracted directory. Confirm `/home/user/pocketbase/pocketbase --version` reports 0.40.4. No executable replacement is needed.
2. Inspect `systemctl cat pocketbase.service` and preserve the current flags and OCR configuration. Wait until no employee is writing. After approval only, run the following on OnePlus:

```sh
set -eu
release=/home/user/storeflow-releases/delivery-saving-20261111
backup=/home/user/pocketbase-backups/delivery-saving-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
chmod 700 "$backup"
sudo cp -p /etc/systemd/system/pocketbase.service "$backup/pocketbase.service"
sudo systemctl stop pocketbase.service
if ! tar -C /home/user/pocketbase -czf "$backup/pocketbase-before.tar.gz" pb_data pb_hooks; then
  sudo systemctl start pocketbase.service
  exit 1
fi
if ! tar -tzf "$backup/pocketbase-before.tar.gz" > "$backup/contents.txt"; then
  sudo systemctl start pocketbase.service
  exit 1
fi
sha256sum "$backup/pocketbase-before.tar.gz" > "$backup/SHA256SUMS"
# Retain this backup and its printed path before copying any runtime files.
printf '%s\n' "$backup"
cd "$release"
sha256sum -c SHA256SUMS
for file in delivery_finalize.pb.js lib/handlers.js lib/delivery_finalization.js lib/pocketbase_store.js; do
  cp -p "pb_hooks/$file" "/home/user/pocketbase/pb_hooks/$file"
done
sudo systemctl start pocketbase.service
systemctl is-active pocketbase.service
sudo journalctl -u pocketbase.service -n 50 --no-pager
curl --fail http://127.0.0.1:8090/api/health
```

Use the **actual extracted directory** for `release`; verify all four source/destination paths before stopping. If extraction/checksum/permissions fail, stop and investigate rather than continuing. If copying fails while stopped, restore the four runtime files from the verified backup before restarting. Keep backups outside `pb_data`. Copy the archive off-device as well. Do not run `migrate up`, alter environment flags, or restart `store-ocr.service`.

3. Verify authenticated capabilities with an employee account. With no writes, an unauthenticated POST to the new finalization route must be rejected with authentication required rather than route-not-found. Then test a clearly identified non-production fixture in a separate acceptance environment first. A real production acceptance delivery must be agreed with the owner because it creates inventory records.
4. Build/update the Flutter client separately, preserving application ID/signing key. On the phone: scan → correct all red rows → see Ready automatically → physically inspect the goods → tap Save once. Verify a finalized receipt, server product and batch records, expiry dashboard, absence from unfinished drafts, and unchanged record counts after retry. Do not create a second draft to retry an uncertain request.
5. If a runtime regression occurs, pause writes, stop PocketBase, restore only the four prior hook files from the backup into the existing directory, then start and inspect the journal. Do not overwrite live `pb_data` after new writes; database restore requires a separate recovery decision.

Idempotency is scoped to the same delivery and operation key. Detecting two independent drafts of the same paper document is not claimed by this repair.
