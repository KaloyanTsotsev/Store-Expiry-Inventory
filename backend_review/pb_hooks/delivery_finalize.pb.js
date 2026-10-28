// REVIEW ONLY. This directory is NOT the deployed PocketBase pb_hooks folder.
// Explicit deployment gate; schema/rules/staging must be approved separately.
routerAdd('POST', '/api/store/deliveries/{id}/finalize', (e) => {
  if ($os.getenv('STORE_FINALIZE_V2_ENABLED') !== 'approved') {
    return e.json(503, {code:'backend_v2_required',message:'Finalization is not enabled.'});
  }
  const logic = require(__hooks + '/lib/delivery_finalization.js');
  const adapters = require(__hooks + '/lib/pocketbase_store.js');
  const body = JSON.parse(JSON.stringify(e.requestInfo().body));
  let response;
  try {
    e.app.runInTransaction((txApp) => {
      const store = adapters.create(txApp);
      try { store.requireSchemaAndRules(); }
      catch (error) {
        if (!error.status) { error.status=503; error.message='backend_v2_required'; }
        throw error;
      }
      response = logic.finalize(store, e.auth.id, e.request.pathValue('id'), body, value => $security.sha256(value));
    });
  } catch (error) {
    if (error.status) return e.json(error.status,{code:error.message,message:error.message});
    // Includes SQLite busy/unique constraint failures: transaction rolled back.
    // Never claim success or expose DB internals. Retry the SAME operation key.
    e.app.logger().error('delivery.finalize.failed','error',String(error));
    return e.json(409,{code:'transaction_not_confirmed',message:'Reload and retry with the same operation key.'});
  }
  return e.json(200,response);
}, $apis.requireAuth('employees'));
