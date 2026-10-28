# UX V3 — Flutter implementation and proposed server contract

Status: Flutter prototype implemented against the supplied PocketBase exports. **No migrations, API Rules, hooks or custom endpoints have been deployed.** The contracts below are proposals, not existing APIs. PocketBase version supplied by the owner: 0.40.4.

## Implemented on the phone

- OCR review exposes Article, Name, Requested, Expiry and Lot; Received is prefilled from valid Requested and remains unconfirmed. Legacy unit/difference values remain readable in saved JSON but are absent from the workflow. Both the original seven-column photographs and a five-header table layout are supported. Unclear layout creates no invented rows.
- Inline editing, per-row physical checkbox, reviewed progress, All / Unchecked / Unclear filters. Editing any visible value removes that row's confirmation. Mark-all requires a separate physical-verification declaration and skips invalid rows.
- Photos have Preview / Retake / Delete controls. Replacement keeps page ID and position, resets that page's OCR/confirmation and re-runs local OCR. SHA-256 detects identical files; OCR-text similarity also flags likely duplicate pages. Warning never silently merges rows. Camera lost-data recovery preserves the page ID.
- Catalog matching uses existing product IDs, exact normalized names or an explicitly verified supplier-specific mapping. Duplicate names require a human choice. Supplier article is never assumed to be an EAN. Missing products are staged locally, without category or a network create call. The current products export has no verified supplier mapping, so that branch only becomes available after a future backend change.
- Deleting an owned unfinished local draft requires confirmation. The draft's app-private copies, OCR snapshots and pending camera recovery are removed. A tombstone prevents a late save from restoring it. Deleting a page removes only its owned photo and replaces the previous snapshot so removed OCR is not retained there. Original gallery files are retained. Finalized local records are rejected. This is ordinary filesystem deletion, not forensic secure erasure.
- Home reads actual batches with product expansion through the shared employee-authenticated PocketBase client. It sorts by calendar expiry, excludes `status=closed`, has non-overlapping Expired / Today / 1–7 / 8–30 day counters, and marks missing legacy status/date for review. Delivery quantity is never presented as live stock. Failed refresh keeps the previous view with a stale/error message; initial load uses unknown counters rather than false zeroes.
- Product `expiry_warning_days` (if provided by a future schema) overrides a default of 7 days. Expired products always say remove from sale; discount guidance is only shown before/on expiry. Day arithmetic uses the phone's calendar date; phones must use the shop timezone (Europe/Sofia). No local notifications or permissions are requested at this stage.
- None / Count / Waste require explicit confirmation. Waste requires positive quantity and reason. Commands have stable operation keys, are separated by employee and reject a second pending command for the same batch on that phone. They remain **not_sent**, can be cancelled and never close/hide a server batch or claim to have posted waste. They are not yet server audit history.

## Atomic delivery finalization (proposed)

`POST /api/store/deliveries/{draft_id}/finalize`

Authenticated employee; authorize ownership or manager/admin privilege on the server. Body: `operation_key`, `expected_revision`, document fields, pages with stable `page_id` and photo references, and lines with stable `line_id`, checked fields, requested/received quantity, expiry, lot, explicit existing product ID or proposed new product name. Never trust the client employee ID, physical flag, product resolution or revision without validation. Require all submitted rows physically checked and all pages fully processed. Zero receipt is retained in the delivery audit but does not create an active batch.

Within ONE real server-side SQLite/PocketBase transaction: load/authorize draft, compare revision/status, validate every line, resolve verified supplier identifiers and selected product IDs, recheck proposed product names/codes, create agreed new products, create delivery lines and batches, add receipt movements and immutable audit events, persist the idempotency response, transition draft to finalized. Any failure rolls back ALL writes. File cleanup must use an outbox/commit-aware lifecycle; do not pretend arbitrary filesystem changes are rolled back by SQLite.

Unique operation key scoped to actor/operation; store request hash and result. Same key + same payload returns the original response. Same key + changed payload returns 409. Unique `(delivery_id,line_id)` prevents duplicate batches. Proposed products use a stable resolution key within the transaction so repeated lines share the appropriate product. Do not impose global uniqueness on normalized names: distinct products may share names. If multiple candidates or a newly concurrent conflicting mapping exists, return 409 `product_resolution_required` with candidates and no partial writes.

Proposed verified supplier identifier mapping: supplier ID + supplier article -> product ID, unique within that supplier, explicitly verified with actor/time provenance. An article must never be copied automatically into `products.barcode`. Category is optional. Product matching must be revalidated on finalize; a draft's cached product list is not authoritative.

Return finalized delivery ID, revision and stable line -> product/batch IDs. Direct client creates/updates to protected inventory and finalized records must be closed by approved API Rules; hiding a UI button is not authorization.

## Server draft deletion (proposed)

`DELETE /api/store/deliveries/{id}` with operation key and expected revision. Authenticate, load real server record, require owned draft or explicitly approved manager/admin policy and status=draft. Transactionally tombstone it, reject late writes/finalization, remove dependent draft-only OCR/line rows, keep an immutable deletion audit. Reject finalized records with 409; corrections require an audited reversal workflow. Delete only that delivery's file references through an authorized, retryable cleanup job. Never accept filesystem paths from the client. Expose no broad destructive cascade for finalized batches/movements.

The current drafts are local only; this Flutter version never calls this proposed endpoint or deletes existing server deliveries.

## Checks, waste and concurrent devices (proposed)

`POST /api/store/batches/{id}/checks`: operation_key, expected_revision, kind none/count/waste, quantity, reason, observed_at_local. Server derives employee and timestamp, verifies role and batch status, validates integer/fractional quantities per product policy, and writes a check event, optional waste movement, batch revision/state and idempotency result in one transaction. Waste requires explicit confirmation and non-empty reason. None records a physical zero and closes the batch only by the approved server policy. Count records observed remaining quantity; it must not reconstruct current stock from original receipt. Partial waste must not close a batch with remaining stock.

Optimistic concurrency: reject stale revision (409), fetch current state, require re-review; no silent replay or last-write-wins on stock. Preserve immutable audit, reversal references and all server timestamps. Client operation keys protect retries; server uniqueness protects multiple phones. This local prototype has no dispatcher, so enabling backend later must require re-review of old not_sent requests and cannot blindly send a backlog with null revisions.

## Warning policy and notification contract (proposed)

Add nullable integer `products.expiry_warning_days` in 0..365 and global shop `default_expiry_warning_days` (initially 7), with policy revision. Protected manager/admin endpoint edits either value with expected_revision and audit. An employee may read effective values; ownership of a receipt does not grant policy editing. Future UI editor must use that endpoint, never unrestricted record updates. Null product value inherits the shop default; zero is an explicit override, not null.

Store expiry as a shop calendar date, with shop timezone Europe/Sofia. Server provides current shop date/effective policy, batch revision and authoritative status. Closed batches are excluded on every device. Server alert identity includes batch ID, expiry/policy revision and transition (near-expiry/expired). Dedupe delivery/acknowledgement per recipient and logical alert, reconcile cancellations and acknowledged state after check/finalize/waste, and never re-emit identical alerts on each app open.

Only after two-phone concurrency tests: add Android notification channel and runtime POST_NOTIFICATIONS on API 33+, request contextually, keep in-app warnings usable on denial; Android 11 has no such runtime permission. Cancel stale schedules after authoritative sync, avoid duplicate delivery across phones according to the approved recipient policy. Offline local schedules alone cannot guarantee shared state or deduplication. No notification implementation is claimed by this build.

## Validation and phone checklist

Run `flutter analyze`, `flutter test`, `flutter build apk --debug`. `tool/run_ocr_device_tests.ps1` uses a disposable .ocrtest package for native OCR regression; never uninstall the normal app to run tests. Android launch test: USB debugging authorized, `adb devices -l` state=device, `adb install -r build/app/outputs/flutter-apk/app-debug.apk`, then launch `com.expiry_tracker.expiry_tracker/.MainActivity`.

On phone: log in with an employee, same LAN as PocketBase; check dashboard against real batches, scan/import photos, correct a row inline, verify edits uncheck only that row, inspect Unchecked/Unclear, test mark-all declaration, retake one page and verify stable position, delete a page then reopen, delete a disposable draft and verify it stays deleted. Test None/Count/Waste on a batch and check it remains visible with an unsent label. There is no server finalize/sync in this stage.


## Optional lot number — requirement 10 (current contract)

`lot_number` is descriptive text, never a batch identity or merge key. Normalize null, empty/whitespace or exactly `1` to `N/A`; canonicalize existing case variants of `N/A`. Keep real lot values (including `01`, `L1`, `1A`) as supplied, trimming only surrounding whitespace. Apply this normalization again on the future protected finalization endpoint and write `lot_number: "N/A"` into PocketBase for missing/uninformative lots. The supplied existing text field accepts this value; no schema migration is needed for this rule.

`N/A` has no validation error or missing-lot warning and requires no separate lot verification. Manual replacement with a real number is allowed. Product, received quantity and expiry still require physical review, and a valid expiry is mandatory for every positive receipt. The checked flag is never set by normalization.

A stable line ID identifies each received group. Each distinct expiry group creates its own `batches` record with its own PocketBase record ID, even when product and lot (`N/A` or a real number) are identical. Do not add uniqueness constraints or upsert/merge by product+lot (or by product+lot+expiry). Retry protection remains operation key and delivery line ID. Example: 6 yoghurts expiring 08.11.2026 + 6 expiring 15.11.2026, both N/A, produce TWO batch records. Zero receipt produces no active batch.

Provenance: retain draft/document ID, stable page ID, stable original `sourceRowId`, current line ID, original OCR field values and page word boxes/image reference. Splitting a row gives each new group a different line ID while retaining sourceRowId and original OCR. Normalizing the editable lot never overwrites the raw original lot value (`1` or empty). Local JSON is backward compatible with older drafts; an old row without sourceRowId uses its existing row ID. The future delivery_items document_row must persist this sourceRowId. This Flutter stage still has no deployed finalize endpoint and performs no new PocketBase writes.
