'use strict';
function fail(status,code){const e=new Error(code);e.status=status;throw e;}
function norm(value){return String(value||'').trim().toLowerCase().replace(/\s+/g,' ');}
function canonical(value){if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';return JSON.stringify(value);}
function json(record,field,fallback){if(!record.collection().fields.getByName(field))return fallback;const raw=toString(record.get(field));return raw&&raw!=='null'?JSON.parse(raw):fallback;}
function snapshot(record){return {id:record.id,name:record.getString('name'),barcode:record.getString('barcode'),category:record.getString('category'),active:!record.collection().fields.getByName('active')||record.getBool('active'),aliases:json(record,'aliases',[]),supplier_identifiers:json(record,'supplier_identifiers',[]),catalog_revision:record.getInt('catalog_revision')};}
function gate(app){
  if($os.getenv('STORE_CATALOG_V3_ENABLED')!=='approved')fail(503,'catalog_v3_not_active');
  const c=app.findCollectionByNameOrId('products');
  const missing=['name','barcode','category','catalog_revision'].filter(f=>!c.fields.getByName(f));
  if(missing.length)fail(503,'catalog_missing_fields:products:'+missing.join(','));
  if([c.createRule,c.updateRule,c.deleteRule].some(r=>r!==null))fail(503,'catalog_rules_not_active:products');
  for(const name of ['product_catalog_audit','product_corrections','catalog_operations']){
    const other=app.findCollectionByNameOrId(name);if([other.createRule,other.updateRule,other.deleteRule].some(r=>r!==null))fail(503,'catalog_rules_not_active:'+name);
  }
  const indexes=Array.from(app.findCollectionByNameOrId('catalog_operations').indexes).map(s=>String(s).toLowerCase().replace(/if\s+not\s+exists/g,'').replace(/[\s;"`\[\]]/g,''));
  if(!indexes.includes('createuniqueindexidx_catalog_operationoncatalog_operations(employee,key)'))fail(503,'catalog_unique_index_required');
  const actual=new DynamicModel({sql:''});
  try {app.db().newQuery("SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_catalog_operation'").one(actual);}
  catch(_) {fail(503,'catalog_sqlite_index_missing:idx_catalog_operation');}
  if(String(actual.sql).toLowerCase().replace(/if\s+not\s+exists/g,'').replace(/[\s;"`\[\]]/g,'')!=='createuniqueindexidx_catalog_operationoncatalog_operations(employee,key)')fail(503,'catalog_sqlite_index_invalid:idx_catalog_operation');
}
function role(app,actor){return app.findRecordById('employees',actor).getString('role');}
function privileged(app,actor){return ['admin','manager'].includes(role(app,actor));}
function record(app,name,values){const r=new Record(app.findCollectionByNameOrId(name));r.load(values);app.save(r);return r;}
function transaction(e,kind,fn){
  try {
    let response;e.app.runInTransaction(app=>{
      gate(app);if(kind==='delivery_finalize' && ($os.getenv('STORE_FINALIZE_V2_ENABLED')!=='approved'||$os.getenv('STORE_CATALOG_DELIVERY_FINALIZE_ENABLED')!=='approved'||!['employee','manager','admin'].includes(app.findRecordById('employees',e.auth.id).getString('role'))))fail(403,'delivery_catalog_finalize_not_allowed');const b=JSON.parse(JSON.stringify(e.requestInfo().body));
      if(!/^[a-zA-Z0-9:_-]{1,128}$/.test(b.operation_key||''))fail(400,'invalid_operation_key');
      const hash=$security.sha256(canonical(kind==='delivery_finalize'?{kind,target:e.request.pathValue('id'),body:b}:{kind,body:b}));
      const previous=app.findRecordsByFilter('catalog_operations','employee={:actor} && key={:key}','',1,0,{actor:e.auth.id,key:b.operation_key});
      if(previous.length){if(previous[0].getString('hash')!==hash)fail(409,'catalog_key_conflict');response=json(previous[0],'response',{});return;}
      response=fn(app,b,e.auth.id);
      record(app,'catalog_operations',{employee:e.auth.id,key:b.operation_key,hash,response});
    });return e.json(200,response);
  }catch(err){if(err.status>=500){e.app.logger().error('catalog.prerequisites.failed','error',String(err));return e.json(err.status,{code:'catalog_unavailable'});}if(err.status)return e.json(err.status,{code:err.message,message:err.message});e.app.logger().error('catalog.v3.failed','error',String(err));return e.json(409,{code:'catalog_transaction_not_confirmed',message:'Retry the same operation key.'});}
}
function articleCode(value){return typeof value==='string'&&/^[A-Za-z0-9][A-Za-z0-9._/\-]{0,127}$/.test(value);}
function fields(raw,existingBarcode='',article=false){
  if(!raw||typeof raw!=='object'||Array.isArray(raw)||Object.keys(raw).some(k=>!['name','barcode','category','active','aliases','supplier_identifiers'].includes(k)))fail(400,'invalid_catalog_fields');
  if(typeof raw.name!=='string'||typeof raw.barcode!=='string'||typeof raw.category!=='string')fail(400,'invalid_catalog_field_types');
  const name=raw.name.trim(),barcode=raw.barcode.trim(),category=raw.category.trim();
  if(!name||name.length>1000||category.length>256||(barcode&&!articleCode(barcode)))fail(400,'invalid_name_barcode_or_status');
  if(raw.aliases!==undefined&&(!Array.isArray(raw.aliases)||raw.aliases.length>100||raw.aliases.some(a=>typeof a!=='string'||!a.trim()||a.length>500)))fail(400,'invalid_aliases');
  const aliases=[...new Set((raw.aliases||[]).map(a=>a.trim()))];
  return {name,barcode,category,aliases,supplier_identifiers:validatedIdentifiers(raw.supplier_identifiers||[])};
}
function validatedIdentifiers(raw){
  if(!Array.isArray(raw)||raw.length>100)fail(400,'invalid_supplier_identifiers');
  const identifiers=raw.map(m=>{
    if(!m||typeof m.supplier!=='string'||!m.supplier.trim()||m.supplier.length>256||typeof m.code!=='string'||!m.code.trim()||m.code.length>128)fail(400,'supplier_and_code_required');
    return {supplier:m.supplier.trim(),code:m.code.trim(),verified:true};
  });
  const keys=identifiers.map(m=>JSON.stringify([norm(m.supplier),m.code]));
  if(new Set(keys).size!==keys.length)fail(400,'duplicate_supplier_identifier');
  return identifiers;
}
function supplierEdits(app,actor,existing,input){
  const key=m=>JSON.stringify([m.supplier,m.code]);
  const before=existing.map(key).sort(), after=input.map(key).sort();
  if(canonical(before)===canonical(after))return existing; // Keep verification and other metadata.
  if(role(app,actor)!=='admin')fail(403,'catalog_supplier_admin_required');
  return input.map(m=>existing.find(o=>key(o)===key(m))||m);
}
function formFields(app,b,actor){
  const current=b.product_id?snapshot(app.findRecordById('products',b.product_id)):{barcode:'',active:true,aliases:[],supplier_identifiers:[]};
  const raw=b.fields;
  if(b.form_version!==2){
    const patch=fields({...raw,aliases:raw?.aliases===undefined?current.aliases:raw.aliases,supplier_identifiers:raw?.supplier_identifiers===undefined?current.supplier_identifiers:raw.supplier_identifiers},current.barcode.trim());
    patch.supplier_identifiers=supplierEdits(app,actor,current.supplier_identifiers,patch.supplier_identifiers);
    return patch;
  }
  if(!raw||typeof raw!=='object'||Array.isArray(raw)||Object.keys(raw).some(k=>!['name','barcode','category','supplier_identifiers'].includes(k))||
     ['name','barcode','category'].some(k=>typeof raw[k]!=='string'))fail(400,'invalid_catalog_fields');
  const name=raw.name.trim(),barcode=raw.barcode.trim(),category=raw.category.trim();
  if(!name||name.length>1000||category.length>256||
     (barcode&&barcode!==current.barcode.trim()&&!articleCode(barcode)))fail(400,'invalid_catalog_form');
  let identifiers=current.supplier_identifiers;
  if(Object.prototype.hasOwnProperty.call(raw,'supplier_identifiers')){
    if(role(app,actor)!=='admin')fail(403,'catalog_supplier_admin_required');
    identifiers=supplierEdits(app,actor,identifiers,validatedIdentifiers(raw.supplier_identifiers||[]));
  }
  return {name,barcode,category,aliases:current.aliases,supplier_identifiers:identifiers};
}

function conflicts(app,id,patch,products=app.findAllRecords('products'),article=false){
  for(const other of products){
    if(other.id===id)continue;
    if(norm(other.getString('name'))===norm(patch.name))fail(409,'duplicate_product_name');
    if(patch.barcode&&(other.getString('barcode').trim()===patch.barcode))fail(409,'conflicting_barcode');
    const mappings=json(other,'supplier_identifiers',[]);
    if(patch.supplier_identifiers.some(m=>mappings.some(o=>o.verified===true&&norm(o.supplier)===norm(m.supplier)&&o.code===m.code)))fail(409,'conflicting_supplier_identifier');
  }
}
function apply(app,actor,id,revision,patch,suggestion,products,article,simple=false){
  const product=id?app.findRecordById('products',id):new Record(app.findCollectionByNameOrId('products'));
  if(!Number.isSafeInteger(revision)||revision<0||product.getInt('catalog_revision')!==revision)fail(409,'catalog_revision_conflict');
  const before=id?snapshot(product):{};conflicts(app,id,patch,products,article);
  if(simple&&id){
    const {name,barcode,category}=patch;
    product.load({name,barcode,category});
    if(product.collection().fields.getByName('supplier_identifiers')&&canonical(before.supplier_identifiers)!==canonical(patch.supplier_identifiers))product.set('supplier_identifiers',patch.supplier_identifiers);
  }else product.load(Object.fromEntries(Object.entries(patch).filter(([key])=>product.collection().fields.getByName(key))));
  product.set('catalog_revision',revision+1);app.save(product);
  const after=snapshot(product);record(app,'product_catalog_audit',{product:product.id,actor,action:id?'update':'create',before,after});
  if(suggestion){const pending=app.findRecordById('product_corrections',suggestion);if(pending.getString('product')!==id||pending.getString('status')!=='pending')fail(409,'suggestion_not_pending');pending.set('status','approved');pending.set('reviewed_by',actor);pending.set('reviewed_at',new Date().toISOString());app.save(pending);}
  return {product:after,status:'saved'};
}
function save(e){return transaction(e,'save',(app,b,actor)=>{
  if(!privileged(app,actor))fail(403,'catalog_manager_required');return apply(app,actor,b.product_id||'',b.expected_revision,formFields(app,b,actor),b.suggestion_id,undefined,b.form_version===2,b.form_version===2);
});}
function proposal(app,b,actor,patch){
  const product=app.findRecordById('products',b.product_id);
  if(!Number.isSafeInteger(b.expected_revision)||product.getInt('catalog_revision')!==b.expected_revision)fail(409,'catalog_revision_conflict');
  const p=record(app,'product_corrections',{product:product.id,employee:actor,patch,expected_revision:b.expected_revision,status:'pending'});
  return {status:'pending',suggestion_id:p.id,product_id:product.id};
}
function suggest(e){return transaction(e,'suggest',(app,b,actor)=>proposal(app,b,actor,formFields(app,b,actor)));}
function confirmMatch(e){return transaction(e,'confirm_match',(app,b,actor)=>{
  const product=app.findRecordById('products',b.product_id),patch=snapshot(product);delete patch.id;delete patch.catalog_revision;
  const alias=String(b.alias||'').trim(),supplier=String(b.supplier||'').trim(),code=String(b.code||'').trim();
  if(!alias&&!code)fail(400,'match_evidence_required');
  if((alias&&!product.collection().fields.getByName('aliases'))||
     (code&&!product.collection().fields.getByName('supplier_identifiers')))fail(400,'catalog_match_fields_removed');
  if(alias&&!patch.aliases.some(a=>norm(a)===norm(alias))&&norm(alias)!==norm(patch.name))patch.aliases.push(alias);
  if(code){if(!supplier)fail(400,'supplier_required');if(!patch.supplier_identifiers.some(m=>norm(m.supplier)===norm(supplier)&&m.code===code))patch.supplier_identifiers.push({supplier,code});}
  const validated=fields(patch,product.getString('barcode').trim());
  validated.supplier_identifiers=supplierEdits(app,actor,json(product,'supplier_identifiers',[]),validated.supplier_identifiers);
  if(privileged(app,actor))return apply(app,actor,product.id,b.expected_revision,validated);
  return proposal(app,b,actor,validated);
});}
function removeProduct(e){return transaction(e,'product_delete',(app,b,actor)=>{
  if(!privileged(app,actor))fail(403,'catalog_manager_required');
  if(typeof b.product_id!=='string'||!b.product_id||!Number.isSafeInteger(b.expected_revision)||b.expected_revision<0)fail(400,'invalid_delete_request');
  const found=app.findRecordsByFilter('products','id={:id}','',1,0,{id:b.product_id});
  if(!found.length)fail(404,'catalog_product_not_found');
  const product=found[0];
  if(product.getInt('catalog_revision')!==b.expected_revision)fail(409,'catalog_revision_conflict');
  // Deleting with PocketBase relation hooks could unlink or cascade records.
  // Verify the expected history schema, then refuse any incoming relation.
  const required={batches:'product',delivery_items:'product',product_catalog_audit:'product',product_corrections:'product'};
  for(const name of Object.keys(required)){
    const field=app.findCollectionByNameOrId(name).fields.getByName(required[name]);
    if(!field||field.type()!=='relation'||field.collectionId!==product.collection().id)fail(503,'catalog_delete_schema_required');
  }
  for(const collection of app.findAllCollections('base','auth')){
    for(const field of Array.from(collection.fields)){
      if(field.type()!=='relation'||field.collectionId!==product.collection().id)continue;
      const operator=field.maxSelect>1?'?=':'=';
      if(app.findRecordsByFilter(collection.name,field.getName()+operator+'{:id}','',1,0,{id:product.id}).length)fail(409,'catalog_product_has_history');
    }
  }
  // Movement history references products through batches, which are checked above.
  app.delete(product);
  return {status:'deleted',product_id:product.id};
});}
// Resolve products only after checking the original staged lines in the shared
// finalizer. Catalog audits and stock writes commit in the same transaction.
function finalizeDelivery(e,article=false){return transaction(e,'delivery_finalize',(app,b,actor)=>{
  const logic=require(__hooks+'/lib/delivery_finalization.js');
  const store=require(__hooks+'/lib/pocketbase_store.js').create(app);
  store.requireSchemaAndRules();
  const create=store.createProduct,assign=store.assignProductCode;
  store.createProduct=(name,code)=>{
    const result=create(name,code),product=app.findRecordById('products',result.id);
    record(app,'product_catalog_audit',{product:result.id,actor,action:'create',before:{},after:snapshot(product)});
    return result;
  };
  store.assignProductCode=(selected,code)=>{
    const before=snapshot(app.findRecordById('products',selected.id));
    const result=assign(selected,code);
    record(app,'product_catalog_audit',{product:result.id,actor,action:'update',before,after:snapshot(app.findRecordById('products',result.id))});
    return result;
  };
  return logic.finalize(store,actor,e.request.pathValue('id'),b,v=>$security.sha256(v),true);
});}
function deliveryEnabled(app,actor){
  if($os.getenv('STORE_FINALIZE_V2_ENABLED')!=='approved'||$os.getenv('STORE_CATALOG_DELIVERY_FINALIZE_ENABLED')!=='approved'||!['employee','manager','admin'].includes(app.findRecordById('employees',actor).getString('role')))return false;
  try{require(__hooks+'/lib/pocketbase_store.js').create(app).requireSchemaAndRules();return typeof require(__hooks+'/lib/delivery_finalization.js').finalize==='function';}catch(err){app.logger().error('catalog.delivery.capabilities.failed','error',String(err));return false;}
}
function capabilities(e){try{gate(e.app);const delivery=deliveryEnabled(e.app,e.auth.id);if(!delivery)fail(503,'catalog_delivery_prerequisites_required');return e.json(200,{protocol:3,catalog:true,can_manage:privileged(e.app,e.auth.id),can_delete_product:privileged(e.app,e.auth.id),delivery_catalog_finalize:delivery,delivery_article_barcode:delivery});}catch(err){e.app.logger().error('catalog.capabilities.failed','error',String(err));return e.json(503,{catalog:false,code:'catalog_unavailable'});}}
function protectRole(e,creating){
  if($os.getenv('STORE_CATALOG_V3_ENABLED')!=='approved')return e.next();
  const changed=creating?e.record.getString('role')!=='employee'&&e.record.getString('role')!=='':e.record.getString('role')!==e.record.original().getString('role');
  if(!changed||e.hasSuperuserAuth())return e.next();
  const admin=e.auth&&e.auth.collection().name==='employees'&&e.app.findRecordById('employees',e.auth.id).getString('role')==='admin';
  if(!admin)throw new ForbiddenError('Only an administrator can assign employee roles.');
  return e.next();
}
module.exports={save,suggest,confirmMatch,capabilities,protectRole,finalizeDelivery,removeProduct};
