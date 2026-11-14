'use strict';
function error(status,message){const e=new Error(message);e.status=status;throw e;}
function gate(){if($os.getenv('STORE_FINALIZE_V2_ENABLED')!=='approved')error(503,'backend_v2_not_active');}
function run(e,callback){try {gate();let response;e.app.runInTransaction(app=>{const store=require(__hooks+'/lib/pocketbase_store.js').create(app);store.requireSchemaAndRules();response=callback(app,store);});return e.json(200,response);}catch(err){if(err.status>=500){e.app.logger().error('store.v2.prerequisites.failed','error',String(err));return e.json(err.status,{code:'backend_v2_unavailable'});}if(err.status)return e.json(err.status,{code:err.message,message:err.message});e.app.logger().error('store.v2.failed','error',String(err));return e.json(409,{code:'transaction_not_confirmed',message:'Retry the same operation key; no success was confirmed.'});}}
function json(record,field,shape){const result=new DynamicModel(shape);record.unmarshalJSONField(field,result);return JSON.parse(JSON.stringify(result));}
function rows(app,name,filter,params){return app.findRecordsByFilter(name,filter,'id',0,0,params||{});}
function insert(app,name,values){const r=new Record(app.findCollectionByNameOrId(name));r.load(values);app.save(r);return r;}
function body(e){return JSON.parse(JSON.stringify(e.requestInfo().body));}
function owned(app,id,actor){const d=app.findRecordById('deliveries',id);if(d.getString('received_by')!==actor)error(403,'not_delivery_owner');return d;}
function stage(e){return run(e,(app,store)=>{
  const logic=require(__hooks+'/lib/delivery_finalization.js'),b=body(e),actor=e.auth.id;
  if(!/^[a-zA-Z0-9]{1,64}$/.test(b.client_id||'')||!/^[a-zA-Z0-9:_-]{1,128}$/.test(b.operation_key||'')||!Number.isSafeInteger(b.expected_revision)||b.expected_revision<0)error(400,'invalid_stage_request');
  if(b.operation_key.startsWith('discard:'))error(400,'invalid_stage_request');
  if(store.operation(actor,'discard:'+b.client_id))error(409,'delivery_draft_discarded');
  const lines=logic.lines(b.lines);
  if(!Array.isArray(b.pages)||b.pages.length<1||b.pages.length>50)error(400,'invalid_pages');
  const pageIds=new Set();
  for(const p of b.pages){if(!/^[a-zA-Z0-9_-]{1,64}$/.test(p.id||'')||pageIds.has(p.id)||p.recognized!==true||p.error||
      (p.has_photo===true&&!/^[a-f0-9]{64}$/.test(p.image_hash||'')))error(400,'invalid_or_unprocessed_page');pageIds.add(p.id);}
  if(lines.some(l=>!pageIds.has(l.page_id)))error(400,'unknown_source_page');
  if(String(b.supplier||'').length>1000||String(b.document_number||'').length>256||JSON.stringify(b).length>4194304)error(400,'stage_payload_too_large');
  const hash=$security.sha256(logic.canonical(b)),existing=store.operation(actor,b.operation_key);
  if(existing){if(existing.kind!=='draft_save'||existing.target!==b.client_id||existing.hash!==hash)error(409,'idempotency_key_payload_conflict');return existing.response;}
  const found=rows(app,'deliveries','received_by={:owner} && client_id={:client}',{owner:actor,client:b.client_id});
  let d;
  if(found.length){d=found[0];if(d.getString('status')!=='draft'||d.getInt('revision')!==b.expected_revision)error(409,'delivery_revision_conflict');store.claim(d.id,b.expected_revision);d=app.findRecordById('deliveries',d.id);}
  else {if(b.expected_revision!==0)error(409,'delivery_missing_for_revision');d=new Record(app.findCollectionByNameOrId('deliveries'));d.set('received_by',actor);d.set('client_id',b.client_id);d.set('revision',1);d.set('status','draft');}
  const manifest={pages:b.pages.map(p=>({id:p.id,recognized:true,image_hash:p.image_hash||'',has_photo:p.has_photo===true}))};
  d.set('supplier',String(b.supplier||''));d.set('document_number',String(b.document_number||''));
  if(b.document_date!==undefined){
    const date=b.document_date;
    if(typeof date!=='string')error(400,'invalid_document_date');
    if(date){
      const value=new Date(date+'T00:00:00Z');
      if(!/^\d{4}-\d{2}-\d{2}$/.test(date)||!Number.isFinite(value.getTime())||value.toISOString().slice(0,10)!==date)error(400,'invalid_document_date');
    }
    d.set('document_date',date?date+' 00:00:00.000Z':'');
  }
  d.set('ocr_draft',manifest);app.save(d);
  const oldItems=rows(app,'delivery_items','delivery={:delivery}',{delivery:d.id}),kept=new Set();
  const checkedAt=new Date().toISOString();
  for(let position=0;position<b.lines.length;position++){
    const raw=b.lines[position],line=lines.find(l=>l.line_id===raw.line_id);let item=oldItems.find(i=>i.getString('client_id')===line.line_id);
    if(!item)item=new Record(app.findCollectionByNameOrId('delivery_items'));
    item.load({delivery:d.id,client_id:line.line_id,page_id:line.page_id,document_row:line.source_row_id,position,
      name_snapshot:line.name,supplier_code:line.supplier_code,product:line.product_id,proposed_new_product:line.proposed_new,
      requested_quantity:line.requested_quantity,received_quantity:line.received_quantity,received_confirmed:true,
      expiry_date:line.expiry_date?line.expiry_date+' 00:00:00.000Z':'',lot_number:line.lot_number,
      review_status:'checked',checked_by:actor,checked_at:checkedAt,original_ocr:raw.original_ocr||{}});
    app.save(item);kept.add(item.id);
  }
  for(const old of oldItems)if(!kept.has(old.id))app.delete(old); // draft-only rows; finalized status rejected above
  const oldPages=rows(app,'delivery_pages','delivery={:delivery}',{delivery:d.id});
  if(oldPages.some(p=>!pageIds.has(p.getString('client_id'))&&p.getString('photo')))error(409,'photo_page_removal_requires_review');
  const pages=[];
  for(const p of b.pages){let record=oldPages.find(r=>r.getString('client_id')===p.id);if(!record)record=new Record(app.findCollectionByNameOrId('delivery_pages'));
    record.load({delivery:d.id,client_id:p.id,image_hash:p.image_hash||'',raw_ocr:{text:String(p.text||''),words:p.words||[],width:p.width||0,height:p.height||0}});
    app.save(record);pages.push({id:p.id,uploaded_hash:record.getString('uploaded_hash')});}
  for(const old of oldPages)if(!pageIds.has(old.getString('client_id')))app.delete(old);
  const response={delivery_id:d.id,status:'draft',revision:d.getInt('revision'),pages};
  const op=insert(app,'inventory_operations',{employee:actor,key:b.operation_key,kind:'draft_save',target:b.client_id,payload_hash:hash,response});
  return response;
});}
function finalize(e){return run(e,(app,store)=>{
  const logic=require(__hooks+'/lib/delivery_finalization.js');return logic.finalize(store,e.auth.id,e.request.pathValue('id'),body(e),value=>$security.sha256(value));
});}
function finalizeByCode(e){return run(e,(app,store)=>{
  const logic=require(__hooks+'/lib/delivery_finalization.js');
  return logic.finalize(store,e.auth.id,e.request.pathValue('id'),body(e),v=>$security.sha256(v),true);
});}
function photo(e){return run(e,(app,store)=>{
  const b=body(e),d=owned(app,e.request.pathValue('id'),e.auth.id),pageId=e.request.pathValue('page');
  const found=rows(app,'delivery_pages','delivery={:delivery} && client_id={:page}',{delivery:d.id,page:pageId});
  if(!found.length)error(404,'page_not_staged');const p=found[0];
  if(d.getString('status')!=='draft')error(409,'delivery_not_editable');
  if(!/^[a-f0-9]{64}$/.test(b.image_hash||'')||p.getString('image_hash')!==b.image_hash)error(409,'photo_does_not_match_staged_page');
  if(p.getString('uploaded_hash')===b.image_hash&&p.getString('photo'))return {delivery_id:d.id,revision:d.getInt('revision'),page_id:pageId,uploaded_hash:b.image_hash};
  const revision=Number(b.expected_revision);if(!Number.isSafeInteger(revision)||revision!==d.getInt('revision'))error(409,'delivery_revision_conflict');
  const files=e.findUploadedFiles('photo');if(files.length!==1||files[0].size>15728640)error(400,'one_photo_required');
  store.claim(d.id,revision);p.set('photo',files[0]);p.set('uploaded_hash',b.image_hash);app.save(p);
  return {delivery_id:d.id,revision:revision+1,page_id:pageId,uploaded_hash:b.image_hash};
});}
function discard(e){return run(e,(app,store)=>{
  const b=body(e),actor=e.auth.id,id=b.client_id;
  if(typeof id!=='string'||!/^[a-zA-Z0-9]{1,64}$/.test(id))error(400,'invalid_client_draft_id');
  const key='discard:'+id,previous=store.operation(actor,key);
  if(previous){
    if(previous.kind!=='draft_save'||previous.target!==id||previous.response.status!=='discarded')error(409,'idempotency_key_payload_conflict');
    return previous.response;
  }
  const found=rows(app,'deliveries','received_by={:owner} && client_id={:client}',{owner:actor,client:id});
  if(found.length){
    const delivery=found[0],params={delivery:delivery.id};
    if(delivery.getString('status')!=='draft')error(409,'delivery_not_editable');
    const items=rows(app,'delivery_items','delivery={:delivery}',params);
    if(rows(app,'batches','delivery={:delivery}',params).length||
       items.some(i=>rows(app,'batches','source_item={:item}',{item:i.id}).length))error(409,'delivery_has_inventory');
    store.claim(delivery.id,delivery.getInt('revision'));
    for(const item of items)app.delete(item);
    for(const page of rows(app,'delivery_pages','delivery={:delivery}',params))app.delete(page);
    app.delete(delivery);
  }
  // Prevent delayed or replayed stage requests from recreating this draft.
  const response={status:'discarded',client_id:id};
  insert(app,'inventory_operations',{employee:actor,key,kind:'draft_save',target:id,payload_hash:$security.sha256(key),response});
  return response;
});}
function capabilities(e){
  try {
    gate();
    const store=require(__hooks+'/lib/pocketbase_store.js').create(e.app);
    store.requireSchemaAndRules();
    let expiry=false,deletion=false;
    try {const handling=require(__hooks+'/lib/handle_expiry.js');expiry=handling.available(e.app);deletion=expiry&&handling.mode==='delete';}catch(_){}
    return e.json(200,{protocol:2,atomic_finalization:true,staging:true,photos:true,
      draft_discard:true,expiry_handling:expiry,batch_deletion:deletion,tested_runtime:'0.40.4'});
  }catch(err){
    e.app.logger().error('store.v2.capabilities.failed','error',String(err));
    return e.json(503,{protocol:2,atomic_finalization:false,code:'backend_v2_unavailable'});
  }
}
function status(e){return run(e,(app,store)=>{
  const d=store.delivery(e.request.pathValue('id')),actor=store.employee(e.auth.id);
  if(d.owner!==e.auth.id && actor.role!=='manager' && actor.role!=='admin')error(403,'not_delivery_owner');
  const pages=rows(app,'delivery_pages','delivery={:delivery}',{delivery:d.id}).map(p=>({id:p.getString('client_id'),image_hash:p.getString('image_hash'),uploaded_hash:p.getString('uploaded_hash')}));
  return {delivery_id:d.id,status:d.status,revision:d.revision,pages};
});}
module.exports={stage,finalize,photo,capabilities,status,discard,finalizeByCode};
