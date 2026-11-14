# StoreFlow: delivery workflow and production repair (superseded)

**Do not deploy this earlier package.** The three product fields were removed intentionally. The current [direct delivery rollout](direct-delivery-workflow.md) needs no schema migration and does not restore them.


## Verified diagnosis

Read-only inspection of `192.168.100.46:8090` found a healthy PocketBase 0.40.4 service. Both capability routes are registered (anonymous requests returned 401); authenticated GET requests in the server log returned 503. The running process has all three relevant V2/Catalog flags set to `approved`. Both migration pairs are marked applied, but the live `products` schema lacks `active`, `aliases` and `supplier_identifiers`. V2's schema gate fails on `active`; Catalog V3's gate fails on the two JSON fields. The logs do not establish how those fields went missing. The fix restores the fields and keeps the capability gates and verified server receipt requirement.

The Dashboard POST to `/api/store/batches/{id}/handle` returned 404. Neither expiry handling hook file was deployed. The repair supplies both files and advertises support through the existing V2 capabilities GET. The updated Dashboard sends queued checks only after the server advertises support, keeps unacknowledged checks, and places raw diagnostics under “Подробности за синхронизацията”.

An existing draft was not inspected on the employee phone. The local repository stored drafts under `application support/delivery_drafts/{employeeId}/{draftId}`. It refused any draft with a staged or pending finalization packet, and one unreadable snapshot could stop the entire list. Staged drafts can now be discarded by their employee-scoped client ID, even if the stage response was lost. The protected server route removes only unfinished deliveries and their temporary rows/photos, refuses finalized deliveries or inventory, and prevents stale requests from recreating a discarded draft. If the server does not confirm, local evidence is retained. An unreadable draft can be moved to a local quarantine folder without deleting its files or making a server request.

## Changed files and test coverage

- `lib/screens/delivery_editor_screen.dart`, `lib/widgets/bulk_review_row.dart`: select/deselect all across all pages and filters, selection count, physical confirmation and per-row validation. “Провери и запази” saves review progress; “Приключи доставката” performs the separate confirmed server write. Invalid rows stay highlighted and prevent finalization.
- `lib/services/delivery_finalization_service.dart`, `lib/services/product_catalog_service.dart`: actionable capability failures and strict V2 detection. Blank metadata is accepted; entered values are preserved and impossible document dates are rejected before staging.
- `lib/services/draft_repository.dart`, `lib/screens/deliveries_screen.dart`, `lib/services/pocketbase_service.dart`: confirmed server discard, local cleanup, unreadable-draft quarantine and picker recovery.
- `lib/widgets/expiry_dashboard.dart`, `lib/services/pocketbase_service.dart`: capability-gated queue and separate diagnostic details.
- `backend/pb_hooks/delivery_finalize.pb.js`, `backend/pb_hooks/lib/handlers.js`, `backend/pb_hooks/lib/pocketbase_store.js`: draft-only cleanup and idempotence, optional metadata and capability checks. `backend/pb_hooks/expiry_handling.pb.js` and `backend/pb_hooks/lib/handle_expiry.js`: protected expiry handler and support check. `backend/catalog_v3/pb_hooks/catalog_v3.pb.js` and its `lib/catalog_v3.js`: Catalog compatibility and article-code finalization.
- `backend/catalog_v3/pb_migrations/1794355200_repair_product_schema.js`: adds only the missing fields. Existing field values are preserved. If `active` was absent, existing legacy rows are initialized as active; no catalog mappings are inferred from audit files. No collection or operational row is removed.

The isolated PocketBase harness reproduces both 503 responses by removing the three fields from a synthetic schema with already-applied migrations. It tests the approval guard, restores the fields, verifies both capability responses are 200, then exercises real finalization, blank and supplied metadata, article barcode reuse, role checks, discard/replay, and cross-session visibility of a handled batch. Flutter tests cover selection across multiple pages, review validation, blocked sync when the route is unavailable, retry after reconnect and local draft recovery.

## Production rollout — pending approval

The [release archive](../build/backend-repair/releases/storeflow-delivery-repair.tar.gz) is a local artifact. No server files, flags or records were changed. No APK was rebuilt. Deploy only after approval for the additive migration, hook installation and a brief PocketBase maintenance window. A fresh client build from the updated Flutter source is needed for the new interface.

1. Transfer the archive and checksum to a staging directory outside `/home/user/pocketbase`. Verify the archive checksum and the included `SHA256SUMS`; inspect the manifest. The archive contains only the eight reviewed backend source files plus documentation and checksums.
2. Confirm that `pocketbase.service` still runs as `user` in `/home/user/pocketbase` with `--automigrate=false`. Recheck the schema and flags before proceeding; if any earlier unexpected changes are found, stop and review. Leave `store-ocr.service` and the existing environment flags unchanged.
3. Pause delivery work, stop only `pocketbase.service`, confirm it is inactive, and make a verified offline backup of `pb_data` (including file storage), `pb_hooks`, `pb_migrations` and the service unit/drop-ins outside the working directory. Verify the archive can be read and record its checksum. Abort before modifying files if backup verification fails.
4. Copy only the packaged hook files into the existing `pb_hooks` directory, preserving ownership and read permissions. Keep the migration in the staged `pb_migrations` directory so the following command applies only the new repair rather than any unreviewed pending migrations. Substitute the verified release directory for `RELEASE`:

   ```sh
   sudo -u user env STORE_PRODUCT_SCHEMA_REPAIR=I_HAVE_BACKUP_AND_TESTS \
     /home/user/pocketbase/pocketbase migrate up \
     --dir=/home/user/pocketbase/pb_data \
     --hooksDir=/home/user/pocketbase/pb_hooks \
     --migrationsDir=RELEASE/pb_migrations
   ```

5. Retain the reviewed migration with the installed migrations for traceability, start PocketBase and inspect the journal. Using an existing employee session, verify `GET /api/store/capabilities` returns protocol 2 with `atomic_finalization`, `draft_discard` and `expiry_handling` true, and `GET /api/store/catalog/capabilities` returns protocol 3 with `catalog` and `delivery_article_barcode` true. Do not use a real delivery or batch write as a health check.
6. On a test environment or with separately authorized test data, confirm two-phone behavior: finalize and refresh on the second phone; handle a single expiry and refresh on the other; discard a staged test draft and confirm finalized inventory stays visible.

If startup or capability checks fail before new user writes, stop PocketBase and recover from the verified backup. After any new writes, do not restore the older database blindly; reconcile those writes before selecting a rollback. The repair migration intentionally does not remove fields on rollback.
