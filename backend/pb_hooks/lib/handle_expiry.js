'use strict';

function fail(status, code) {
  const error = new Error(code); error.status = status; throw error;
}

function available(app) {
  const batches = app.findCollectionByNameOrId('batches');
  const movements = app.findCollectionByNameOrId('stock_movements');
  return Boolean(batches.deleteRule === null && batches.fields.getByName('revision') &&
    movements.updateRule === null && movements.fields.getByName('notes'));
}

// Inspect all incoming schema relations BEFORE PocketBase's normal delete.
function dependencies(app, batch) {
  let movements = [];
  for (const collection of Array.from(app.findAllCollections())) {
    if (collection.type === 'view') continue;
    for (const field of Array.from(collection.fields)) {
      const type = typeof field.type === 'function' ? field.type() : field.type;
      if (type !== 'relation' || field.collectionId !== batch.collection().id) continue;
      const refs = app.findRecordsByFilter(collection.id, field.name + ' ?= {:batch}', '', 0, 0, {batch: batch.id});
      if (!refs.length) continue;
      if (field.cascadeDelete || field.required || field.minSelect > 0) fail(409, 'incompatible_batch_dependency');
      if (collection.name !== 'stock_movements' || field.name !== 'batch' || field.maxSelect !== 1) {
        fail(409, 'unsupported_batch_dependency');
      }
      movements = refs;
    }
  }
  return movements;
}

function handle(e) {
  try {
    let receipt;
    e.app.runInTransaction(app => {
      if (!available(app)) fail(503, 'protected_batch_deletion_schema_required');
      const actor = app.findRecordById('employees', e.auth.id);
      if (!['employee', 'manager', 'admin'].includes(actor.getString('role'))) fail(403, 'employee_role_required');
      const id = e.request.pathValue('id');
      if (!/^[a-z0-9]{15}$/.test(id)) fail(400, 'invalid_batch_id');
      const body = e.requestInfo().body;
      // Old close-only clients/outboxes must never silently become deletes.
      if (body.action !== 'delete_batch') fail(409, 'batch_deletion_confirmation_required');
      if (!Number.isSafeInteger(body.expected_revision) || body.expected_revision < 0 ||
          typeof body.expiry_date !== 'string' || (body.expiry_date !== '' && !/^\d{4}-\d{2}-\d{2}$/.test(body.expiry_date))) {
        fail(400, 'invalid_batch_deletion');
      }
      const found = app.findRecordsByFilter('batches', 'id={:id}', '', 1, 0, {id});
      receipt = {batch_id: id, status: 'deleted', deleted: true};
      // No revision remains for an absent target: confirm absence only.
      if (!found.length) return;
      const batch = found[0];
      if (batch.getString('expiry_date').slice(0, 10) !== body.expiry_date) fail(409, 'expiry_changed');
      if (batch.getInt('revision') !== body.expected_revision) fail(409, 'batch_revision_conflict');
      const movements = dependencies(app, batch);
      const productId = batch.getString('product');
      const products = app.findRecordsByFilter('products', 'id={:id}', '', 1, 0, {id: productId});
      const snapshot = {event: 'batch_deleted', batch_id: id, deleted_at: new Date().toISOString(),
        deleted_by: actor.id, product_id: productId,
        product_name: products.length ? products[0].getString('name') : '',
        product_code: products.length ? products[0].getString('barcode') : '',
        delivery_id: batch.getString('delivery'), source_item_id: batch.getString('source_item'),
        created_by: batch.getString('created_by'), created: batch.getString('created'), updated: batch.getString('updated'),
        closed_at: batch.getString('closed_at'), closed_by: batch.getString('closed_by'), photo: batch.getStringSlice('photo'),
        expiry_date: batch.getString('expiry_date'), lot_number: batch.getString('lot_number'),
        quantity: batch.getFloat('quantity'), revision: batch.getInt('revision'), status: batch.getString('status'),
        has_observed_count: batch.getBool('has_observed_count'), observed_quantity: batch.getFloat('observed_quantity'),
        observed_at: batch.getString('observed_at'), observed_by: batch.getString('observed_by')};
      for (const movement of movements) {
        const notes = movement.getString('notes');
        movement.set('notes', notes + (notes ? '\n' : '') + '[StoreFlow batch deletion] ' + JSON.stringify(snapshot));
        app.save(movement);
      }
      app.delete(batch); // PB unsets optional references inside this transaction.
    });
    return e.json(200, receipt);
  } catch (error) {
    if (error.status) return e.json(error.status, {code: error.message});
    e.app.logger().error('batch.delete.failed', 'error', String(error));
    return e.json(409, {code: 'batch_deletion_not_confirmed'});
  }
}

module.exports = {handle, available, mode: 'delete'};
