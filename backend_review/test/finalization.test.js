'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {finalize}=require('../pb_hooks/lib/delivery_finalization.js');
const clone=value=>JSON.parse(JSON.stringify(value));
const hash=value=>createHash('sha256').update(value).digest('hex');
function fixture() {
  const line=(id,expiry)=>({line_id:id,source_row_id:'source1',page_id:'page1',name:'Кисело мляко',supplier_code:'9001',
    product_id:'',proposed_new:true,requested_quantity:12,received_quantity:6,expiry_date:expiry,lot_number:'N/A',checked:true});
  return {employees:{owner:{role:'employee'},manager:{role:'manager'},other:{role:'employee'}},
    delivery:{id:'delivery1',owner:'owner',status:'draft',revision:3,pages:[{id:'page1',recognized:true}]},
    items:[{id:'item1',confirmed:true,checkedBy:'owner',checkedAt:'2026-10-22',line:line('line1','2026-11-08')},
      {id:'item2',confirmed:true,checkedBy:'owner',checkedAt:'2026-10-22',line:line('line2','2026-11-15')}],
    products:[],batches:[],movements:[],operations:[],sequence:0};
}
function request(db) {return {operation_key:'finalize:delivery1',expected_revision:3,lines:db.items.map(item=>clone(item.line))};}
function transaction(db,actor,body,{failSecondBatch=false}={}) {
  // Transactional fake exercises business semantics and rollback. This is NOT
  // an SQLite/PocketBase integration or proof of runtime two-phone locking.
  const staged=clone(db);
  const id=()=>String(++staged.sequence);
  const store={
    employee:key=>staged.employees[key],delivery:key=>key===staged.delivery.id?staged.delivery:null,
    operation:(actor,key)=>staged.operations.find(op=>op.actor===actor && op.key===key),
    items:()=>staged.items,
    claim:(key,revision)=>{if(staged.delivery.status!=='draft'||staged.delivery.revision!==revision) throw Object.assign(new Error('CAS'),{status:409});staged.delivery.revision++;},
    createOperation:(actor,key,target,hash)=>{const op={id:id(),actor,key,target,hash,kind:'finalize'};staged.operations.push(op);return op;},
    products:()=>staged.products.slice(),
    createProduct:name=>{const product={id:id(),name,active:true};staged.products.push(product);return product;},
    resolveItem:(key,product,lot)=>{const item=staged.items.find(i=>i.id===key);item.line.product_id=product;item.line.lot_number=lot;},
    createBatch:(delivery,item,product,line)=>{
      if(failSecondBatch && staged.batches.length===1) throw new Error('injected disk/database failure');
      const batch={id:id(),delivery,item,product,expiry:line.expiry_date,lot:line.lot_number,quantity:line.received_quantity};staged.batches.push(batch);return batch.id;
    },
    createReceipt:(batch,item,quantity,actor,operation)=>{const move={id:id(),batch,item,quantity,actor,operation};staged.movements.push(move);return move.id;},
    completeDelivery:(key,actor,revision)=>Object.assign(staged.delivery,{status:'finalized',revision,finalized_by:actor}),
    completeOperation:(key,response)=>{staged.operations.find(op=>op.id===key).response=clone(response);},
  };
  const response=finalize(store,actor,'delivery1',clone(body),hash);
  Object.assign(db,staged);return response;
}
test('Separate expiry groups and N/A create two batches and receipts, one new product',()=>{
  const db=fixture();const response=transaction(db,'owner',request(db));
  assert.equal(db.products.length,1);assert.equal(db.batches.length,2);assert.equal(db.movements.length,2);
  assert.notEqual(db.batches[0].id,db.batches[1].id);assert.deepEqual(db.batches.map(b=>b.expiry),['2026-11-08','2026-11-15']);
  assert.ok(db.batches.every(b=>b.lot==='N/A'));assert.equal(response.status,'finalized');assert.equal(response.revision,4);
  assert.equal(db.items[1].line.source_row_id,'source1');
});
test('Retry returns committed response; changed payload with same key is rejected',()=>{
  const db=fixture();const body=request(db);const response=transaction(db,'owner',body);
  assert.deepEqual(transaction(db,'owner',body),response);assert.equal(db.batches.length,2);
  const changed=clone(body);changed.lines[0].received_quantity=5;
  assert.throws(()=>transaction(db,'owner',changed),error=>error.status===409);
  assert.equal(db.movements.length,2);
});
test('Stale second phone/manager is rejected without double finalization',()=>{
  const db=fixture();const body=request(db);transaction(db,'owner',body);
  assert.throws(()=>transaction(db,'manager',body),error=>error.status===409);assert.equal(db.batches.length,2);
});
test('Foreign employee, unreviewed server row and stale preview cannot write',()=>{
  const db=fixture();const before=clone(db);
  assert.throws(()=>transaction(db,'other',request(db)),error=>error.status===403);assert.deepEqual(db,before);
  db.items[0].checkedBy='';assert.throws(()=>transaction(db,'owner',request(db)),error=>error.status===409);
  db.items[0].checkedBy='owner';const body=request(db);body.lines[0].received_quantity=5;
  assert.throws(()=>transaction(db,'owner',body),error=>error.status===409);assert.equal(db.batches.length,0);
});
test('Failure after first receipt rolls back products, batches, journal, status and revision',()=>{
  const db=fixture();const before=clone(db);
  assert.throws(()=>transaction(db,'owner',request(db),{failSecondBatch:true}),/injected/);assert.deepEqual(db,before);
});
test('Zero receipt creates no batch/product; missing expiry blocks positive receipt',()=>{
  const db=fixture();db.items.forEach(item=>{item.line.received_quantity=0;item.line.expiry_date='';});
  transaction(db,'owner',request(db));assert.equal(db.batches.length,0);assert.equal(db.products.length,0);
  const invalid=fixture();invalid.items[0].line.expiry_date='';
  assert.throws(()=>transaction(invalid,'owner',request(invalid)),error=>error.status===400);assert.equal(invalid.batches.length,0);
});
test('Ambiguous catalog names require a choice; no product barcode assumption',()=>{
  const db=fixture();db.products=[{id:'p1',name:'Кисело мляко',active:true},{id:'p2',name:'Кисело мляко',active:true}];
  assert.throws(()=>transaction(db,'owner',request(db)),error=>error.status===409);assert.equal(db.batches.length,0);
  db.items.forEach(item=>item.line.product_id='p2');transaction(db,'owner',request(db));
  assert.ok(db.batches.every(b=>b.product==='p2'));assert.equal(db.products.length,2);
});
test('Same product and same expiry also remain distinct received line records',()=>{
  const db=fixture();db.items[1].line.expiry_date=db.items[0].line.expiry_date;
  transaction(db,'owner',request(db));assert.equal(db.batches.length,2);
});
