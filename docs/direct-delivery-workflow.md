# StoreFlow: direct delivery by product code

Normal delivery is **scan → review → select → check and save → finalize**. “Провери и запази” stores reviewed rows in the local draft. “Приключи доставката” submits once and marks the draft complete only when PocketBase confirms the transaction. A lost reply keeps the same saved request for replay.

## Investigation

- The old `DeliveryEditorScreen._prepareIdentity` depended on Catalog capabilities. `ProductMatcher.supplierIdentity`, `DeliveryRowStatus` and `DeliveryCatalogService.confirm` introduced the verified supplier mapping and manager-only alternate path. The old `_finish` also required `articleBarcode` from Catalog capabilities and selected a Catalog-specific finalizer. Ordinary deliveries no longer use those paths.
- Read-only SSH inspection of the deployed PocketBase 0.40.4 instance at `192.168.100.46:8090` confirmed the existing protected stage, photo and finalize routes. It has the Catalog routes, but no `finalize-by-code`, no server discard endpoint and no handled-expiry hooks. The product table intentionally has no `active`, `aliases` or `supplier_identifiers`. The old V2 store required the first field; the old Catalog gate required the other two. Neither gate requires those fields now. No fields are recreated, no collection is added, and no migration is shipped.
- The draft repository used to refuse deletion once a stage/finalization packet was present. Production currently has no server delivery rows, and the device's file was not inspected, so the condition of that specific local draft is unverified. The package includes owner-scoped draft discard, which safely confirms absence or discards an unfinished server row without touching stock or finalized deliveries. A malformed local file can be moved to quarantine without deleting evidence.

## Behavior and changed files

- `lib/screens/delivery_editor_screen.dart`, `lib/screens/delivery_item_screen.dart`, `lib/widgets/bulk_review_row.dart`: exact-code review, one confirmation action, one finalization action, optional inline document metadata. A known product shows its catalog name and code and the editable batch fields; a new code has editable name and code. The first document OCR pass reads the table; a matched product never needs a second recognition request.
- `lib/models/delivery_draft.dart`, `lib/services/product_matcher.dart`, `lib/services/delivery_finalization_service.dart`: validate nonempty name and code, positive finite quantity, valid expiration date and technical field limits. Lot is optional. When the document did not supply a requested quantity, the existing numeric field uses its neutral zero value; this never changes the employee-confirmed received quantity. Existing staged legacy requests are replayed unchanged.
- `backend/pb_hooks/delivery_finalize.pb.js`, `lib/handlers.js`, `lib/delivery_finalization.js`, `lib/pocketbase_store.js`: a dedicated authenticated `finalize-by-code` route invokes the existing transaction. It reuses only an exact barcode, preserves leading zeroes, creates a missing product once, and creates a new batch and received movement for each valid row. It keeps revision, idempotency, photo and authorization checks. The dedicated route prevents an older server from silently processing the request with name-based legacy behavior. The client does not require a new version or Catalog capability.
- `backend/catalog_v3/pb_hooks/lib/catalog_v3.js` and `lib/screens/product_form_screen.dart`, `lib/screens/products_screen.dart`, `lib/screens/known_product_batch_screen.dart`: catalog editing and barcode lookup work without the three removed fields. The product form has only name, code and category. Older installs that still have optional fields keep their stored data; this change does not drop columns.
- The already prepared discard and expiry handling hooks are included. They use the existing collections and do not change stock on an expiry check.

## Verification

Run `flutter analyze --no-pub`, `flutter test --no-pub`, and the isolated harness:

```text
python backend/tool/test_backend.py --catalog --without-product-fields --flutter
python backend/tool/test_backend.py --catalog --flutter
```

The first run models the actual product schema. It verifies that both capability endpoints return 200, ordinary employees can finalize without supplier metadata or Catalog approval, a code with leading zeroes reuses one product across separate quantities and dates, concurrent finalizations do not duplicate a code, exact replay is harmless, and rollback leaves no partial stock or catalog writes. It also verifies editing the simple product form, successful draft discard/replay, refusal to delete finalized inventory, and handled-expiry synchronization across authenticated sessions. The second run covers older installations that still have the fields and their legacy endpoints.

## Rollout

Use the **direct delivery** hook archive only. The earlier `storeflow-delivery-repair.tar.gz` is superseded and must not be deployed; it would restore the three fields.

1. Verify the archive checksum and internal `SHA256SUMS`. Extract it to a separate staging directory and review the eight hook files. There is no migration directory.
2. After approval of a short maintenance window, pause writes and stop only `pocketbase.service`. Back up and verify `/home/user/pocketbase/pb_data` (including storage), `pb_hooks`, and service configuration. Leave the OCR service and systemd flags unchanged.
3. Copy only the packaged hooks into `/home/user/pocketbase/pb_hooks`, with the existing ownership and permissions. Start PocketBase and check its journal and authenticated capabilities. Do not run a schema migration or write a real delivery as a health check.
4. The simplified screen requires an updated Flutter client. Verify the full phone workflow on test data before resuming live use. If startup fails, restore the backed-up hooks and restart; do not overwrite a live database containing newer writes.

No production changes or APK build were performed during this implementation.
