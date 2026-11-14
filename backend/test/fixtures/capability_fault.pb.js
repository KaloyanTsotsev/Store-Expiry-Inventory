// Local harness only. Faults affect an in-memory schema view, never the database.
routerAdd('GET','/api/store-test/capability/{scope}/{kind}',e=>{
  if($os.getenv('STORE_V2_TEST_FAULTS')!=='LOCAL_ONLY')throw new ForbiddenError();
  const scope=e.request.pathValue('scope'),kind=e.request.pathValue('kind'),logged=[];
  const target=scope==='catalog'?(kind==='index'?'catalog_operations':'products'):'batches';
  const app={
    findCollectionByNameOrId(name){
      const c=e.app.findCollectionByNameOrId(name);
      if(name!==target)return c;
      return {fields:kind==='fields'?{getByName:f=>f===(scope==='catalog'?'name':'expiry_date')?null:c.fields.getByName(f)}:c.fields,
        createRule:kind==='rules'?'':c.createRule,updateRule:c.updateRule,deleteRule:c.deleteRule,
        indexes:kind==='index'?[]:c.indexes};
    },
    logger:()=>({error:(...args)=>logged.push(args.map(String).join(' '))}),
    db:()=>e.app.db(),
    findRecordById:(...args)=>e.app.findRecordById(...args),
  };
  const event={app,auth:e.auth,json:(status,body)=>({status,body})};
  const result=scope==='catalog'?require(__hooks+'/lib/catalog_v3.js').capabilities(event):
    require(__hooks+'/lib/handlers.js').capabilities(event);
  return e.json(200,{result,logged});
},$apis.requireAuth('employees'));
