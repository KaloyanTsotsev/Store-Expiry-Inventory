# Confirmed PocketBase finalization repair — 11 November 2026

## Scope and findings

The supplied production investigation identifies a deployed runtime incompatible with the actual product schema. The existing local adapter already stopped requiring `products.active`; this repair completes the work by removing all product-availability checks and creation writes based on that field. Batch `status` remains independent and unchanged.

Catalog had a separate finalizer which required verified supplier mappings, resolved products before invoking V2, then passed rewritten `product_id` values into a second staged-line comparison. That duplicate resolution path was the integration defect. The two Catalog delivery endpoints now call the same transaction-bound exact-code finalizer as the Flutter client's `/api/store/deliveries/{id}/finalize-by-code` route.

The shared finalizer validates the original requested/staged lines before resolving product IDs. It then finds an exact string `products.barcode`, refuses duplicate/conflicting codes, reuses the canonical record/name, or creates the employee-confirmed new product. Explicitly selecting a staged existing product with an empty barcode permits confirmed backfill; an existing different code is never overwritten. Leading zeroes are preserved. No supplier association or supplier approval is required or created. Existing mappings remain untouched.

Catalog routes retain their enclosing transaction, catalog operation replay and product create/backfill audit. V2 retains ownership, role/authentication, revision CAS, server checked evidence, page/photo checks, operation replay, batch creation and receipt movements. Historical committed responses are not rewritten. The old V2 `/finalize` route remains for legacy frozen requests; the current Flutter normal workflow uses the exact-code route. No name-based fallback is introduced when that route is missing.

## Exact source changes in this repair

- `backend/pb_hooks/lib/pocketbase_store.js`: products no longer read/write active; safe explicit code backfill; schema/rule/index diagnostics identify the collection and missing field/index. Actual SQLite unique-index SQL is checked in addition to PocketBase metadata.
- `backend/pb_hooks/lib/delivery_finalization.js`: no inactive-product rejection; exact-code finalization supports confirmed empty-code backfill without changing staged input or overwriting a different code.
- `backend/pb_hooks/lib/handlers.js`: detailed private logs for capability/prerequisite failures, sanitized public 503 responses. Existing discard implementation/registration is preserved.
- `backend/catalog_v3/pb_hooks/lib/catalog_v3.js`: one shared finalization process for both Catalog routes, no mandatory supplier/verified mapping/UI approval flags, no required active/aliases/supplier fields, no GTIN checksum requirement or normalized-GTIN collision matching for internal codes. Omitted historical alias/mapping data is preserved during updates. Private capability diagnostics; failure rather than finalization capability success when inventory prerequisites fail. Legacy active remains readable only as snapshot metadata, never as availability or a catalog write requirement.
- `lib/services/product_matcher.dart`, `lib/screens/known_product_batch_screen.dart`, `lib/screens/products_screen.dart`: an existing record is available regardless of a historical active flag; no obsolete inactive label/rejection. Authentication, automatic validation and the existing finalization service remain intact.
- Tests: `backend/tool/test_backend.py`, `backend/tool/test_catalog.py`, `backend/tool/test_delivery_catalog.py`, new `backend/tool/test_confirmed_finalization.py`, new `backend/test/fixtures/capability_fault.pb.js`, `test/catalog_v3_test.dart`, `test/delivery_identity_test.dart`.
- Packaging: new `backend/tool/package_confirmed_finalization.py`; this report.

No collection, migration, API Rule, production table, existing product ID, barcode, supplier mapping, batch status or OCR implementation was changed by this repair. The protected inventory rules remain null. Generic standalone catalog editing retains its existing permissions; ordinary employee delivery finalization bypasses no security controls and requires no manager approval.

## Verification and reproduction

```powershell
flutter analyze --no-pub
flutter test --no-pub
& 'C:\Users\cocev\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' backend/tool/test_backend.py --catalog --without-product-fields --flutter
& 'C:\Users\cocev\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' backend/tool/test_backend.py --catalog --flutter
```

Verified results: `flutter analyze --no-pub` reported no issues; the general suite passed **129 tests** (4 live SDK tests skipped outside the harness). Both backend configurations passed the **16 inventory scenarios**, **6 new confirmed-cause regression groups**, and **6 Paddle proxy groups**. The no-removed-fields run passed **3 delivery SDK tests**; the legacy-schema run additionally passed **12 Catalog groups**, **10 Catalog delivery groups**, and **4 combined live SDK tests**. The latter includes Catalog editing compatibility.

Both backend runs start actual **localhost-only PocketBase 0.40.4** with synthetic accounts and data. Their fixture migrations are applied to disposable test databases only. They do not contact production or rerun its migrations.

Coverage includes both Catalog routes without supplier or approval flags; internal non-GTIN codes; historical active=false product reuse where that column exists; optional removed fields; exact-code conflicts; staged input tampering; product create/backfill audits; transaction rollback; concurrent callers; independent batches/deliveries; exact replay; authenticated draft discard; preserved historical fixtures; and the protected Paddle proxy.

The diagnostic tests simulate missing fields, unsafe rules and missing index metadata through an **in-memory schema view**. They assert 503, private actionable log messages and sanitized public responses. They do not alter the real test database schema, rules or indexes. The test-only diagnostic hook and rollback fault hook are not in the deployment archive.

The Flutter SDK test uploads the supplied real document photograph with its recorded Paddle response, explicitly corrects the 14 missing dates with synthetic employee-entered dates, saves 37 batches, verifies exact persisted codes/dates/quantities and dashboard retrieval, checks completed draft state, and repeats without duplicates. This is real persistence in isolated PocketBase, not a claim of production phone acceptance.

Logs: `build/confirmed-finalization-analyze.log`, `build/confirmed-finalization-flutter.log`, `build/confirmed-finalization-no-fields.log`, `build/confirmed-finalization-legacy.log`.

## Deployment package and approval boundary

The archive `build/backend-repair/releases/storeflow-confirmed-finalization.tar.gz` supersedes the earlier four-file delivery-saving package for this repair. It contains six runtime files, this report and SHA256 checksums:

```text
pb_hooks/delivery_finalize.pb.js
pb_hooks/lib/handlers.js
pb_hooks/lib/delivery_finalization.js
pb_hooks/lib/pocketbase_store.js
pb_hooks/catalog_v3.pb.js
pb_hooks/lib/catalog_v3.js
```

The route files are included because the deployed runtime is missing `/api/store/drafts/discard` and the exact-code route. The archive contains **no** migrations, database, service configuration, OCR/expiry hooks, credentials, test fault hooks or automatic installer. It requires the already applied V2/Catalog schema and existing approved service flags described in the investigation. Do not enable new flags or reapply migrations as part of this repair.

Production has not been changed, stopped or backed up by this implementation. The owner's earlier explicit production-change approval restriction remains in force; the attached investigation was not treated as approval to stop the service. Before deployment, approve this exact six-file replacement and a short write pause.

After approval, use the following process on the OnePlus. Preserve `/home/user/pocketbase/pocketbase`, `pb_data`, the working OCR hooks and `store-ocr.service`.

1. Upload the archive plus `.sha256` to `/home/user/storeflow-releases/confirmed-finalization-20261111`. Run the external checksum check, inspect archive members, extract there, then run `sha256sum -c SHA256SUMS`. Check executable version 0.40.4 and the existing `pocketbase.service` configuration. Verify all six source/destination paths and available backup storage **before** stopping.
2. Wait for employee writes to stop. Run the following only after approval:

```sh
set -eu
release=/home/user/storeflow-releases/confirmed-finalization-20261111
backup=/home/user/pocketbase-backups/confirmed-finalization-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
chmod 700 "$backup"
sudo cp -p /etc/systemd/system/pocketbase.service "$backup/pocketbase.service"
cd "$release"
sha256sum -c SHA256SUMS
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
printf '%s\n' "Verified backup: $backup"
for file in delivery_finalize.pb.js lib/handlers.js lib/delivery_finalization.js lib/pocketbase_store.js catalog_v3.pb.js lib/catalog_v3.js; do
  cp -p "pb_hooks/$file" "/home/user/pocketbase/pb_hooks/$file"
done
sudo systemctl start pocketbase.service
systemctl is-active pocketbase.service
sudo journalctl -u pocketbase.service -n 50 --no-pager
curl --fail http://127.0.0.1:8090/api/health
```

If backup verification fails, do not copy hooks. If copying/startup fails, restore the **six previous files** from the verified backup before restarting. Do not overwrite the whole hooks directory or discard unrelated files. Keep an off-device copy of the backup. Do not manually alter SQLite or run migrations.

3. With an authenticated employee, verify both capability endpoints return 200 and true finalization capability. Verify missing/expired authentication is rejected. Verify the discard route is registered. If a capability returns 503, inspect the new private journal/log details; do not relax rules or remove integrity checks.
4. Run the scan → correction → Save → persisted product/batch/dashboard → completed draft acceptance flow in a separate safe environment first. A production acceptance delivery creates real inventory and requires an explicitly agreed test record. Repeating the exact packet must return the same receipt and unchanged counts. A separate unfinished test draft must discard without affecting inventory or products.
5. On a regression, pause writes, stop PocketBase, restore only these six old hook files, start and inspect logs. Do not restore `pb_data` over newer production writes without a separate recovery decision.

No APK was rebuilt/installed. No fresh live OCR run or production write is claimed. Existing automatic row validation, manual date formatting and protected PaddleOCR remain in place. Two independent drafts of one paper document are still not claimed to be globally deduplicated.
