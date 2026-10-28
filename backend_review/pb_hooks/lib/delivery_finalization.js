'use strict';
// REVIEW ONLY. No migrations or installation. Storage must wrap this entire
// function in one REAL database transaction; a JS mutex is not sufficient.
function fail(status, code) { const error = new Error(code); error.status = status; throw error; }
function lot(value) { const text = String(value || '').trim(); return !text || text === '1' || text.toUpperCase() === 'N/A' ? 'N/A' : text; }
function nameKey(value) { return String(value || '').trim().toLowerCase().replace(/\s+/g, ' '); }
function date(value) {
  const text = String(value || '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return '';
  const parsed = new Date(text + 'T00:00:00Z');
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === text &&
    Number(text.slice(0, 4)) >= 2000 && Number(text.slice(0, 4)) <= 2100 ? text : '';
}
function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  return JSON.stringify(value);
}
function lines(values) {
  if (!Array.isArray(values) || values.length < 1 || values.length > 500) fail(400, 'invalid_lines');
  const seen = new Set();
  return values.map(raw => {
    if (!raw || typeof raw !== 'object') fail(400, 'invalid_line');
    const line = {
      line_id: String(raw.line_id || ''), source_row_id: String(raw.source_row_id || ''), page_id: String(raw.page_id || ''),
      name: String(raw.name || '').trim(), supplier_code: String(raw.supplier_code || '').trim(),
      product_id: String(raw.product_id || ''), proposed_new: raw.proposed_new === true,
      requested_quantity: raw.requested_quantity, received_quantity: raw.received_quantity,
      expiry_date: date(raw.expiry_date), lot_number: lot(raw.lot_number), checked: raw.checked === true,
    };
    if (!/^[a-zA-Z0-9_-]{1,64}$/.test(line.line_id) || seen.has(line.line_id) ||
      !/^[a-zA-Z0-9_-]{1,64}$/.test(line.source_row_id) || !/^[a-zA-Z0-9_-]{1,64}$/.test(line.page_id) ||
      !line.name || line.name.length > 1000 || line.supplier_code.length > 128 || line.lot_number.length > 128 ||
      !Number.isFinite(line.requested_quantity) || line.requested_quantity < 0 ||
      !Number.isFinite(line.received_quantity) || line.received_quantity < 0 || !line.checked ||
      (line.received_quantity > 0 && (!line.expiry_date || (!line.product_id && !line.proposed_new)))) fail(400, 'unreviewed_or_invalid_line');
    seen.add(line.line_id);
    return line;
  }).sort((a, b) => a.line_id < b.line_id ? -1 : a.line_id > b.line_id ? 1 : 0);
}

function finalize(store, actorId, deliveryId, body, sha256) {
  if (!body || !/^[a-zA-Z0-9:_-]{1,128}$/.test(body.operation_key || '') ||
    !Number.isSafeInteger(body.expected_revision) || body.expected_revision < 0) fail(400, 'invalid_request');
  const requested = lines(body.lines);
  const hash = sha256(canonical({kind:'finalize',target:deliveryId,expected_revision:body.expected_revision,lines:requested}));
  // All reads and writes below use a transactional store bound to txApp.
  const actor = store.employee(actorId);
  if (!actor) fail(401, 'employee_auth_required');
  const delivery = store.delivery(deliveryId);
  if (!delivery) fail(404, 'delivery_not_found');
  if (delivery.owner !== actorId && actor.role !== 'admin' && actor.role !== 'manager') fail(403, 'not_delivery_owner');
  const previous = store.operation(actorId, body.operation_key);
  if (previous) {
    if (previous.target !== deliveryId || previous.kind !== 'finalize' || previous.hash !== hash) fail(409, 'idempotency_key_payload_conflict');
    return previous.response;
  }
  if (delivery.status !== 'draft' || delivery.revision !== body.expected_revision) fail(409, 'delivery_status_or_revision_conflict');
  if (!Array.isArray(delivery.pages) || !delivery.pages.length ||
    delivery.pages.some(p => !p.id || p.recognized !== true || p.error)) fail(409, 'unprocessed_document_pages');
  const staged = store.items(deliveryId);
  if (staged.some(item => !item.confirmed || !item.checkedBy || !item.checkedAt)) fail(409, 'server_review_missing');
  const stagedLines = lines(staged.map(item => item.line));
  const pageIds = new Set(delivery.pages.map(p => p.id));
  if (stagedLines.some(line => !pageIds.has(line.page_id)) || canonical(requested) !== canonical(stagedLines)) fail(409, 'preview_does_not_match_server_draft');
  // Acquires the delivery revision with a SQL compare-and-swap before creating
  // any products/batches. SQLite busy/CAS failures abort; never retry new keys.
  store.claim(deliveryId, body.expected_revision);
  const operation = store.createOperation(actorId, body.operation_key, deliveryId, hash);
  const products = store.products();
  const createdByName = new Map();
  const responseLines = [];
  for (const item of staged) {
    const line = stagedLines.find(row => row.line_id === item.line.line_id);
    if (line.received_quantity === 0) {
      responseLines.push({line_id:line.line_id,product_id:line.product_id,batch_id:null,movement_id:null}); continue;
    }
    let product;
    if (line.product_id) {
      product = products.find(p => p.id === line.product_id);
      if (!product || !product.active) fail(409, 'selected_product_missing_or_inactive');
    } else {
      const key = nameKey(line.name);
      const matches = products.filter(p => nameKey(p.name) === key);
      if (matches.length > 1 || (createdByName.has(key) && createdByName.get(key) !== line.supplier_code)) fail(409, 'product_resolution_required');
      if (matches.length === 1) {
        product = matches[0];
        if (!product.active) fail(409, 'product_resolution_required');
      } else {
        // Supplier article is kept on the delivery line; never used as EAN.
        product = store.createProduct(line.name);
        products.push(product); createdByName.set(key,line.supplier_code);
      }
    }
    store.resolveItem(item.id, product.id, line.lot_number);
    // ALWAYS one new record per positive delivery item. No product/lot/expiry
    // upsert: N/A and distinct expiry groups must never merge.
    const batchId = store.createBatch(deliveryId, item.id, product.id, line, actorId);
    const movementId = store.createReceipt(batchId, item.id, line.received_quantity, actorId, operation.id);
    responseLines.push({line_id:line.line_id,product_id:product.id,batch_id:batchId,movement_id:movementId});
  }
  const response = {delivery_id:deliveryId,status:'finalized',revision:body.expected_revision + 1,lines:responseLines};
  store.completeDelivery(deliveryId, actorId, response.revision);
  store.completeOperation(operation.id, response);
  return response; // Caller returns this ONLY AFTER database commit.
}
module.exports = {finalize, canonical, lines, lot};
