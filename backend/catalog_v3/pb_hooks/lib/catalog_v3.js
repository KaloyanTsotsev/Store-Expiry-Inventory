'use strict';
function fail(status,code){const e=new Error(code);e.status=status;throw e;}
function norm(value){return String(value||'').trim().toLowerCase().replace(/\s+/g,' ');}
function canonical(value){if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';return JSON.stringify(value);}
function gtin(value){
  const text=String(value||'').trim();if(!/^(?:\d{8}|\d{12}|\d{13}|\d{14})$/.test(text))return '';
  let sum=0;for(let i=text.length-2,weight=3;i>=0;i--,weight=4-weight)sum+=Number(text[i])*weight;
  return (10-sum%10)%10===Number(text[text.length-1])?text.padStart(14,'0'):'';
}
function json(record,field,fallback){const raw=toString(record.get(field));return raw&&raw!=='null'?JSON.parse(raw):fallback;}
function snapshot(record){return {id:record.id,name:record.getString('name'),barcode:record.getString('barcode'),category:record.getString('category'),active:record.getBool('active'),aliases:json(record,'aliases',[]),supplier_identifiers:json(record,'supplier_identifiers',[]),catalog_revision:record.getInt('catalog_revision')};}
function gate(app){
  if($os.getenv('STORE_CATALOG_V3_ENABLED')!=='approved')fail(503,'catalog_v3_not_active');
  const c=app.findCollectionByNameOrId('products');
  if(['catalog_revision','aliases','supplier_identifiers'].some(f=>!c.fields.getByName(f))||[c.createRule,c.updateRule,c.deleteRule].some(r=>r!==null))fail(503,'catalog_rules_not_active');
  for(const name of ['product_catalog_audit','product_corrections','catalog_operations']){
    const other=app.findCollectionByNameOrId(name);if([other.createRule,other.updateRule,other.deleteRule].some(r=>r!==null))fail(503,'catalog_rules_not_active');
  }
  const indexes=Array.from(app.findCollectionByNameOrId('catalog_operations').indexes).map(s=>String(s).toLowerCase().replace(/if\s+not\s+exists/g,'').replace(/[\s;"`\[\]]/g,''));
  if(!indexes.includes('createuniqueindexidx_catalog_operationoncatalog_operations(employee,key)'))fail(503,'catalog_unique_index_required');
}
function privileged(app,actor){return ['admin','manager'].includes(app.findRecordById('employees',actor).getString('role'));}
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
  }catch(err){if(err.status)return e.json(err.status,{code:err.message,message:err.message});e.app.logger().error('catalog.v3.failed','error',String(err));return e.json(409,{code:'catalog_transaction_not_confirmed',message:'Retry the same operation key.'});}
}
function fields(raw){
  if(!raw||typeof raw!=='object'||Array.isArray(raw)||Object.keys(raw).some(k=>!['name','barcode','category','active','aliases','supplier_identifiers'].includes(k)))fail(400,'invalid_catalog_fields');
  if(typeof raw.name!=='string'||typeof raw.barcode!=='string'||typeof raw.category!=='string')fail(400,'invalid_catalog_field_types');
  const name=raw.name.trim(),barcode=raw.barcode.trim(),category=raw.category.trim();
  if(!name||name.length>1000||category.length>256||(barcode&&!gtin(barcode))||typeof raw.active!=='boolean')fail(400,'invalid_name_barcode_or_status');
  if(!Array.isArray(raw.aliases)||raw.aliases.length>100||raw.aliases.some(a=>typeof a!=='string'||!a.trim()||a.length>500))fail(400,'invalid_aliases');
  const aliases=[...new Set(raw.aliases.map(a=>a.trim()))];
  if(!Array.isArray(raw.supplier_identifiers)||raw.supplier_identifiers.length>100)fail(400,'invalid_supplier_identifiers');
  const identifiers=raw.supplier_identifiers.map(m=>{
    if(!m||typeof m.supplier!=='string'||!m.supplier.trim()||m.supplier.length>256||typeof m.code!=='string'||!m.code.trim()||m.code.length>128)fail(400,'supplier_and_code_required');
    return {supplier:m.supplier.trim(),code:m.code.trim(),verified:true};
  });
  const keys=identifiers.map(m=>JSON.stringify([norm(m.supplier),m.code]));if(new Set(keys).size!==keys.length)fail(400,'duplicate_supplier_identifier');
  return {name,barcode,category,active:raw.active,aliases,supplier_identifiers:identifiers};
}
function conflicts(app,id,patch){
  const barcode=gtin(patch.barcode);
  for(const other of app.findAllRecords('products')){
    if(other.id===id)continue;
    if(norm(other.getString('name'))===norm(patch.name))fail(409,'duplicate_product_name');
    if(barcode&&gtin(other.getString('barcode'))===barcode)fail(409,'conflicting_barcode');
    const mappings=json(other,'supplier_identifiers',[]);
    if(patch.supplier_identifiers.some(m=>mappings.some(o=>o.verified===true&&norm(o.supplier)===norm(m.supplier)&&o.code===m.code)))fail(409,'conflicting_supplier_identifier');
  }
}
function apply(app,actor,id,revision,patch,suggestion){
  const product=id?app.findRecordById('products',id):new Record(app.findCollectionByNameOrId('products'));
  if(!Number.isSafeInteger(revision)||revision<0||product.getInt('catalog_revision')!==revision)fail(409,'catalog_revision_conflict');
  const before=id?snapshot(product):{};conflicts(app,id,patch);
  product.load(patch);product.set('catalog_revision',revision+1);app.save(product);
  const after=snapshot(product);record(app,'product_catalog_audit',{product:product.id,actor,action:id?'update':'create',before,after});
  if(suggestion){const pending=app.findRecordById('product_corrections',suggestion);if(pending.getString('product')!==id||pending.getString('status')!=='pending')fail(409,'suggestion_not_pending');pending.set('status','approved');pending.set('reviewed_by',actor);pending.set('reviewed_at',new Date().toISOString());app.save(pending);}
  return {product:after,status:'saved'};
}
function save(e){return transaction(e,'save',(app,b,actor)=>{
  if(!privileged(app,actor))fail(403,'catalog_manager_required');return apply(app,actor,b.product_id||'',b.expected_revision,fields(b.fields),b.suggestion_id);
});}
function proposal(app,b,actor,patch){
  const product=app.findRecordById('products',b.product_id);
  if(!Number.isSafeInteger(b.expected_revision)||product.getInt('catalog_revision')!==b.expected_revision)fail(409,'catalog_revision_conflict');
  const p=record(app,'product_corrections',{product:product.id,employee:actor,patch,expected_revision:b.expected_revision,status:'pending'});
  return {status:'pending',suggestion_id:p.id,product_id:product.id};
}
function suggest(e){return transaction(e,'suggest',(app,b,actor)=>proposal(app,b,actor,fields(b.fields)));}
function confirmMatch(e){return transaction(e,'confirm_match',(app,b,actor)=>{
  const product=app.findRecordById('products',b.product_id),patch=snapshot(product);delete patch.id;delete patch.catalog_revision;
  const alias=String(b.alias||'').trim(),supplier=String(b.supplier||'').trim(),code=String(b.code||'').trim();
  if(!alias&&!code)fail(400,'match_evidence_required');
  if(alias&&!patch.aliases.some(a=>norm(a)===norm(alias))&&norm(alias)!==norm(patch.name))patch.aliases.push(alias);
  if(code){if(!supplier)fail(400,'supplier_required');if(!patch.supplier_identifiers.some(m=>norm(m.supplier)===norm(supplier)&&m.code===code))patch.supplier_identifiers.push({supplier,code});}
  const validated=fields(patch);
  if(privileged(app,actor))return apply(app,actor,product.id,b.expected_revision,validated);
  return proposal(app,b,actor,validated);
});}
// Additive Catalog route: all catalog writes and the UNMODIFIED V2 finalizer
// share this txApp. No stock is written by OCR, stage, or catalog resolution.
function finalizeDelivery(e){return transaction(e,'delivery_finalize',(app,b,actor)=>{
  const logic=require(__hooks+'/lib/delivery_finalization.js');
  const store=require(__hooks+'/lib/pocketbase_store.js').create(app);
  store.requireSchemaAndRules();
  const id=e.request.pathValue('id'),delivery=app.findRecordById('deliveries',id);
  if(b.catalog_confirmed!==true)fail(400,'catalog_confirmation_required');
  if(delivery.getString('received_by')!==actor&&!privileged(app,actor))fail(403,'not_delivery_owner');
  if(delivery.getString('status')!=='draft'||delivery.getInt('revision')!==b.expected_revision)fail(409,'delivery_revision_conflict');
  const requested=logic.lines(b.lines),staged=store.items(id);
  if(logic.canonical(requested)!==logic.canonical(logic.lines(staged.map(i=>i.line))))fail(409,'preview_does_not_match_server_draft');
  const supplier=delivery.getString('supplier').trim();
  if(!supplier||supplier.length>256)fail(400,'supplier_required');
  const newNames=new Map();
  const resolved=requested.map(line=>{
    if(line.received_quantity===0)return line;
    if(!/^[A-Za-z0-9][A-Za-z0-9._/\-]{0,127}$/.test(line.supplier_code))fail(400,'invalid_supplier_code');
    const matches=app.findAllRecords('products').filter(p=>json(p,'supplier_identifiers',[]).some(m=>norm(m.supplier)===norm(supplier)&&m.code===line.supplier_code));
    let product;
    if(matches.length){
      if(matches.length!==1||!matches[0].getBool('active')||!json(matches[0],'supplier_identifiers',[]).some(m=>m.verified===true&&norm(m.supplier)===norm(supplier)&&m.code===line.supplier_code))fail(409,'conflicting_supplier_identifier');
      product=matches[0];
      if(line.product_id&&line.product_id!==product.id)fail(409,'conflicting_supplier_identifier');
    }else{
      if(line.product_id||!line.proposed_new)fail(409,'supplier_identity_missing');
      const saved=apply(app,actor,'',0,fields({name:line.name,barcode:'',category:'',active:true,aliases:[],supplier_identifiers:[{supplier,code:line.supplier_code,verified:true}]}));
      product=app.findRecordById('products',saved.product.id);
      newNames.set(line.supplier_code,norm(line.name));
    }
    if(newNames.has(line.supplier_code)&&newNames.get(line.supplier_code)!==norm(line.name))fail(409,'conflicting_new_product_names');
    const source=staged.find(i=>i.line.line_id===line.line_id);
    const item=app.findRecordById('delivery_items',source.id);
    item.set('product',product.id);app.save(item);
    return Object.assign({},line,{product_id:product.id});
  });
  // V2 still validates photos, checked evidence, CAS, operations and creates
  // a distinct batch/receipt per positive source item. Any failure rolls back
  // the product, association, audit, staged IDs, batches and both journals.
  return logic.finalize(store,actor,id,Object.assign({},b,{lines:resolved}),v=>$security.sha256(v));
});}
function deliveryEnabled(app,actor){
  if($os.getenv('STORE_FINALIZE_V2_ENABLED')!=='approved'||$os.getenv('STORE_CATALOG_DELIVERY_FINALIZE_ENABLED')!=='approved'||!['employee','manager','admin'].includes(app.findRecordById('employees',actor).getString('role')))return false;
  try{require(__hooks+'/lib/pocketbase_store.js').create(app).requireSchemaAndRules();return typeof require(__hooks+'/lib/delivery_finalization.js').finalize==='function';}catch(_){return false;}
}
function capabilities(e){try{gate(e.app);return e.json(200,{protocol:3,catalog:true,can_manage:privileged(e.app,e.auth.id),delivery_catalog_finalize:deliveryEnabled(e.app,e.auth.id)});}catch(_){return e.json(503,{catalog:false,code:'catalog_v3_not_active'});}}
function protectRole(e,creating){
  if($os.getenv('STORE_CATALOG_V3_ENABLED')!=='approved')return e.next();
  const changed=creating?e.record.getString('role')!=='employee'&&e.record.getString('role')!=='':e.record.getString('role')!==e.record.original().getString('role');
  if(!changed||e.hasSuperuserAuth())return e.next();
  const admin=e.auth&&e.auth.collection().name==='employees'&&e.app.findRecordById('employees',e.auth.id).getString('role')==='admin';
  if(!admin)throw new ForbiddenError('Only an administrator can assign employee roles.');
  return e.next();
}
module.exports={save,suggest,confirmMatch,capabilities,protectRole,finalizeDelivery};
