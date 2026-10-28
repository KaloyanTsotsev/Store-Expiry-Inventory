// Prepared locally for PB 0.40.4. No schema/inventory writes.
routerAdd('POST', '/api/store/ocr/recognize', e => {
  const logic = require(__hooks + '/lib/paddle_proxy.js');
  return logic.recognize(e);
}, $apis.requireAuth('employees'), $apis.bodyLimit(12587008));
