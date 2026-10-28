routerAdd('GET','/api/store/capabilities',e=>require(__hooks+'/lib/handlers.js').capabilities(e),$apis.requireAuth('employees'));
routerAdd('POST','/api/store/drafts/stage',e=>require(__hooks+'/lib/handlers.js').stage(e),$apis.requireAuth('employees'),$apis.bodyLimit(8388608));
routerAdd('POST','/api/store/deliveries/{id}/finalize',e=>require(__hooks+'/lib/handlers.js').finalize(e),$apis.requireAuth('employees'),$apis.bodyLimit(2097152));
routerAdd('POST','/api/store/deliveries/{id}/pages/{page}/photo',e=>require(__hooks+'/lib/handlers.js').photo(e),$apis.requireAuth('employees'),$apis.bodyLimit(16777216));

routerAdd('GET','/api/store/deliveries/{id}/status',e=>require(__hooks+'/lib/handlers.js').status(e),$apis.requireAuth('employees'));
