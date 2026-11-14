routerAdd('POST', '/api/store/batches/{id}/handle', e => {
  require(__hooks + '/lib/handle_expiry.js').handle(e);
}, $apis.requireAuth('employees'), $apis.bodyLimit(4096));
