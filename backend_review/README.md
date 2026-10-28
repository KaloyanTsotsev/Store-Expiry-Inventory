# Delivery finalization — code for review, NOT deployed

> Historical prototype. The current executable implementation, real PocketBase 0.40.4 integration tests and Flutter staging/photo integration are in [../backend/](../backend/README.md). Deployment is still manual and requires the [approved maintenance plan](../docs/pocketbase-v2-deployment.md). The limitations below describe this old prototype only; do not deploy it.

This folder is separate from a PocketBase server. It is not an application startup hook directory and Flutter never copies it to the server. There are **no migrations**, deployment scripts or changes to existing API Rules here. The supplied backend version is 0.40.4; the code must be exercised on a disposable exact-version instance before approval. Current official documentation is 0.40.5, and the exact 0.40.4 source could not be retrieved in this session, so JSVM adapter compatibility is NOT claimed as verified.

## What is ready

- `pb_hooks/delivery_finalize.pb.js`: authenticated employee route `POST /api/store/deliveries/{id}/finalize`, explicit environment gate, one `runInTransaction` using only `txApp`, and response after commit.
- `pb_hooks/lib/delivery_finalization.js`: request validation, authorization, replay by journal key/hash, server-staged physical confirmation, exact preview comparison, optimistic revision claim, product resolution/creation, separate batch per positive line, receipt movements and operation journal.
- `pb_hooks/lib/pocketbase_store.js`: real PocketBase record operations and a bound SQL CAS. No REST loops, filesystem operations or remote requests in the transaction.
- `test/finalization.test.js`: business unit tests using an explicitly transactional in-memory fake. These are NOT tests of SQLite locking or a running PocketBase instance.

The hook defaults to HTTP 503 unless `STORE_FINALIZE_V2_ENABLED=approved`. Even with that setting, schema/rules/index preflight must pass before writes. Do not set it or install the hook as part of this Flutter change.

## Dependencies requiring separate approval

Use the proposed V2 schema in `../docs/backend-v2-proposal.md`, including locked Create/Update/Delete on deliveries, delivery_items, batches, stock_movements and inventory_operations. Finalization itself does not apply these changes. Existing current-schema collections are insufficient.

Additional field on the proposed (not yet created) `delivery_items`: `proposed_new_product` bool. The protected draft staging operation must save the explicit existing product selection or new-product intent and assign `review_status=checked`, `received_confirmed=true`, checked_by and checked_at on an authorized employee's physical declaration. The endpoint re-reads these server values and never promotes a checked flag merely because the finalize request contains true.

The endpoint needs an ALREADY staged server delivery record ID and revision, all document photos staged before finalization, `ocr_draft.pages` with stable IDs and processed state, and persisted delivery items with their original OCR. The Flutter app currently has local drafts only: no protected V2 staging/upload endpoint is implemented by this task. Therefore the production finalization client stays disabled. Enabling the route alone is insufficient.

Required exact unique indexes (validated at runtime):

```sql
CREATE UNIQUE INDEX idx_items_client ON delivery_items(delivery, client_id);
CREATE UNIQUE INDEX idx_batch_source ON batches(source_item) WHERE source_item != '';
CREATE UNIQUE INDEX idx_movement_line ON stock_movements(line_key) WHERE line_key != '';
CREATE UNIQUE INDEX idx_operation_key ON inventory_operations(employee, key);
```

The schema/rules and staging path must protect revisions, finalization fields and the immutable operation journal against direct client CRUD. Only reviewed mutation endpoints may change inventory history; API rules alone do not affect privileged server hooks.

## Request and result

Request contains `operation_key`, `expected_revision`, and `lines`. Each line includes line_id, source_row_id, page_id, name, supplier_code, product_id, proposed_new, requested_quantity, received_quantity, ISO calendar expiry_date, lot_number, checked. The preview must match the full staged line set, not a subset. Identifiers are validated, quantities must be finite nonnegative numbers; every positive receipt needs a valid date and resolved/proposed product. All server pages must be processed and all items physically confirmed. The draft staging operation must record typed quantities (including an explicit zero) so absence cannot be mistaken for zero. Request maximum is 500 lines; staging/UI limits must be aligned before enabling production.

The application uses one deterministic key `finalize:<server-record-id>`, persists the exact packet before sending, freezes edits while the outcome is uncertain, and reuses that packet on retry. The server hashes canonical business input, target and revision. Same employee/key with same hash returns the original result; changed payload is HTTP 409. Other employees/devices encounter the committed finalized status or a revision conflict. The CAS update is performed before product/batch creation; transaction and unique indexes are required together. A transaction/SQLite busy failure never returns success. DB failure details go only to the server log.

A successful result has delivery_id, status=finalized, revision, and line -> product/batch/movement IDs. Zero receipt retains its line but creates no product, batch or movement. Each positive line creates a distinct batch by source_item, even for the same product, same N/A and same expiry. Different expiry groups always create distinct records. N/A is accepted and normalization happens server-side as well as in Flutter. Record IDs are the identity; lot numbers are descriptive only.

Product resolution rechecks explicit selected IDs and active status. Proposed new products are checked against normalized catalog names inside the transaction. Ambiguity causes rollback and `product_resolution_required`. Equal names with inconsistent supplier codes within new-product proposals require explicit resolution. Newly created products have optional empty category and barcode; supplier article is never assumed to be EAN. The current implementation scans the product catalog in the transaction; measure this on a realistic store dataset and consider an approved indexed lookup design before enabling at scale. It does not write an unverified supplier-code mapping.

## Flutter behavior in the current build

The bottom action is always visible with reviewed progress; it is active only for a fully reviewed valid delivery. It opens a scrollable per-line summary of requested/received quantities and the newly calculated difference `received − requested`. It does not use the old OCR Difference column. The last confirmation is disabled with an explicit backend V2 message because the endpoint/staging path is not deployed. No network finalize call is made and no fake success is displayed.

A typed, disabled-by-default PocketBase client and test injection cover the future success/error flow. Only a validated server success changes local status to finalized and returns to Home. If response is lost, the stored packet remains and the checks are preserved. If local receipt persistence fails after server commit, only local persistence is retried; no additional finalize call is sent. A prepared unresolved request cannot be deleted or overwritten by an older local save.

## Validation before any production approval

1. Bootstrap a disposable PocketBase **0.40.4** instance with approved proposed collections/rules/indexes and synthetic data; do not point this folder at production.
2. Verify JSVM APIs/types, JSON fields and exact schema preflight. Exercise the authenticated route through HTTP, not just the pure module.
3. Test owner/manager authorization, anonymous rejection, preview mismatch, changed key hash, invalid quantities/dates, missing pages, N/A, duplicate catalog names and zero receipt.
4. Run concurrent HTTP requests for the same delivery from two independent authenticated clients and verify one finalized record set. Force a failure after a first receipt and verify real SQLite rollback including products and journal. Repeat after dropped HTTP response.
5. Confirm direct collection CRUD cannot bypass status/revision/audit rules, photos are protected and source OCR stays accessible only to authorized users. Check local receipt recovery and two-phone staging revision conflicts.
6. Only after review and approval deploy together with staging, rule changes, indexes and operational backup/recovery. Remove the client availability gate in a separately reviewed change.

Official API references used for the draft adapter:

- [Custom routes and request auth/body](https://pocketbase.io/docs/js-routing/)
- [Record operations and JSON unmarshalling](https://pocketbase.io/docs/js-records/)
- [Database transactions and bound queries](https://pocketbase.io/docs/js-database/)
- [App runInTransaction API](https://pocketbase.io/jsvm/interfaces/core.App.html#runInTransaction)

## Device test safety

Use `tool/run_finalization_device_tests.ps1` with an unlocked authorized phone. It validates a separately built .ocrtest APK and passes `--use-application-binary` to the driver, so the cleanup package is parsed from the actual test APK. A plain Flutter test invocation may cache the main package ID before building a conditional Gradle applicationId; it must not be used against the employee app. The test-only Android window flag keeps the already unlocked test screen awake without changing global device settings. Physical unlock is still required.
