routerAdd('GET','/api/store/catalog/capabilities',e=>require(__hooks+'/lib/catalog_v3.js').capabilities(e),$apis.requireAuth('employees'));
routerAdd('POST','/api/store/catalog/products',e=>require(__hooks+'/lib/catalog_v3.js').save(e),$apis.requireAuth('employees'),$apis.bodyLimit(524288));
routerAdd('POST','/api/store/catalog/corrections',e=>require(__hooks+'/lib/catalog_v3.js').suggest(e),$apis.requireAuth('employees'),$apis.bodyLimit(524288));
routerAdd('POST','/api/store/catalog/confirm-match',e=>require(__hooks+'/lib/catalog_v3.js').confirmMatch(e),$apis.requireAuth('employees'),$apis.bodyLimit(524288));
onRecordUpdateRequest(e=>require(__hooks+'/lib/catalog_v3.js').protectRole(e,false),'employees');
onRecordCreateRequest(e=>require(__hooks+'/lib/catalog_v3.js').protectRole(e,true),'employees');

routerAdd('POST','/api/store/catalog/deliveries/{id}/finalize',e=>require(__hooks+'/lib/catalog_v3.js').finalizeDelivery(e),$apis.requireAuth('employees'),$apis.bodyLimit(4194304));
