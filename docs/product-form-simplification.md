# StoreFlow: simplified product editor

The main form shows **Име на продукт**, **Код**, and **Категория**. Код is the string stored in `products.barcode` and follows the “Артикул” format, including leading zeroes. The old heading, alias input and active switch are gone. A collapsed supplier-code section is available only to a signed-in administrator. History and correction review remain available to their existing roles.

The old form sent a full product snapshot, including values hidden from some users. The version-2 form sends only the three visible values and optional admin changes to supplier codes. The server keeps the stored aliases and active status; new products are active. Existing supplier metadata is retained unless an administrator edits it. Legacy full-form and match endpoints also reject manual supplier-code changes by other roles. Supplier mappings remain readable for delivery matching, and controlled associations created by confirmed delivery finalization are unchanged.

The new delete action preserves the existing manager/admin permission scope. It needs confirmation, checks the product revision and checks incoming relations on the server in the same transaction as deletion. Batches, delivery items, corrections, audit history and other incoming relations block deletion. A stock movement references the product through its batch, so that batch also blocks deletion. A catalog-created product already has an audit entry and is therefore protected. No records are automatically deactivated or deleted, and there is no direct REST delete fallback.

Changed files:

- `lib/screens/product_form_screen.dart`: three-field form, admin-only expansion, confirmation and error handling.
- `lib/services/product_catalog_service.dart`: admin role check, delete capability and protected request, actionable errors.
- `lib/screens/delivery_item_screen.dart`: legacy match suggestions still support aliases; only an admin can manually add supplier mappings.
- `backend/catalog_v3/pb_hooks/catalog_v3.pb.js` and `backend/catalog_v3/pb_hooks/lib/catalog_v3.js`: version-2 form validation, server-side permissions and transactional deletion guard.
- `test/catalog_v3_test.dart`, `test/catalog_v3_http_test.dart` and `backend/tool/test_catalog.py`: role UI, confirmation, protected history, permission bypass, preserved hidden data and existing delivery regression checks.

To verify on a test server, open an existing product under each role. All roles should see the three main fields; only admin should see the supplier-code section. Save a code such as `000ABC` and verify it is stored literally and found by barcode lookup. Edit an existing inactive record and confirm that its active flag, aliases and supplier mappings did not change. As manager or admin, cancel a delete confirmation, then confirm deletion for a product with linked history: it should remain unchanged with an explanation. Separately test deletion and replay using an unreferenced legacy fixture.

The updated client needs the two updated Catalog V3 hooks. The existing collections, API Rules and delivery hooks are unchanged; no migration or APK rebuild was performed, and no production records were touched.
