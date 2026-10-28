'use strict';
// PocketBase JSVM adapter. No network, files, settings changes or schema writes.
function create(app) {
  function all(collection, filter, params) {
    return app.findRecordsByFilter(collection, filter, 'id', 0, 0, params || {});
  }
  function record(collection, id) { return app.findRecordById(collection,id); }
  function insert(collection, values) {
    const result = new Record(app.findCollectionByNameOrId(collection));
    Object.keys(values).forEach(key => result.set(key, values[key]));
    app.save(result); return result;
  }
  function jsonField(record, field, shape) {
    const result = new DynamicModel(shape);
    record.unmarshalJSONField(field,result);
    return JSON.parse(JSON.stringify(result));
  }
  const required = {
    deliveries:['status','revision','received_by','ocr_draft','finalized_by','finalized_at'],
    delivery_items:['delivery','client_id','page_id','document_row','name_snapshot','supplier_code','product',
      'proposed_new_product','requested_quantity','received_quantity','received_confirmed','expiry_date','lot_number','review_status','checked_by','checked_at'],
    batches:['product','delivery','source_item','quantity','expiry_date','lot_number','created_by','status','revision'],
    stock_movements:['batch','type','quantity','employee','operation','line_key'],
    inventory_operations:['employee','key','kind','target','payload_hash','response'],
    delivery_pages:['delivery','client_id','photo','image_hash','uploaded_hash','raw_ocr'],
    products:['name','barcode','category','active'],
  };
  return {
    requireSchemaAndRules() {
      for(const name of Object.keys(required)) {
        const collection = app.findCollectionByNameOrId(name);
        if(required[name].some(field => !collection.fields.getByName(field))) {
          const error = new Error('backend_v2_required');error.status=503;throw error;
        }
        if(name!=='products' && [collection.createRule,collection.updateRule,collection.deleteRule].some(rule => rule!==null)) {
          const error = new Error('protected_inventory_rules_required');error.status=503;throw error;
        }
      }
      // Exact unique index definitions are part of the reviewed schema contract.
      const indexes = {
        delivery_items:"CREATE UNIQUE INDEX idx_items_client ON delivery_items(delivery, client_id)",
        batches:"CREATE UNIQUE INDEX idx_batch_source ON batches(source_item) WHERE source_item != ''",
        stock_movements:"CREATE UNIQUE INDEX idx_movement_line ON stock_movements(line_key) WHERE line_key != ''",
        inventory_operations:"CREATE UNIQUE INDEX idx_operation_key ON inventory_operations(employee, key)",
      };
      function normalizedDDL(value) {return String(value).toLowerCase().replace(/if\s+not\s+exists/g,'').replace(/[\s;"`\[\]]/g,'');}
      for(const name of Object.keys(indexes)) {
        const ddl=Array.from(app.findCollectionByNameOrId(name).indexes);
        if(!ddl.some(value=>normalizedDDL(value)===normalizedDDL(indexes[name]))) {
          const error=new Error('unique_inventory_indexes_required');error.status=503;throw error;
        }
      }
    },
    employee(id) {const actor=record('employees',id);return {id:actor.id,role:actor.getString('role')};},
    delivery(id) {
      const d=record('deliveries',id);
      const manifest=jsonField(d,'ocr_draft',{pages:[]});
      const uploaded=all('delivery_pages','delivery = {:delivery}',{delivery:id});
      for(const page of manifest.pages){if(page.has_photo===true && !uploaded.some(p=>p.getString('client_id')===page.id && p.getString('photo') && p.getString('uploaded_hash')===page.image_hash)) {page.recognized=false;}}
      return {id:d.id,owner:d.getString('received_by'),status:d.getString('status'),revision:d.getInt('revision'),
        pages:manifest.pages};
    },
    operation(employee,key) {
      const found=all('inventory_operations','employee = {:employee} && key = {:key}',{employee:employee,key:key});
      if(!found.length) return null;
      const op=found[0];
      return {target:op.getString('target'),kind:op.getString('kind'),hash:op.getString('payload_hash'),
        response:JSON.parse(toString(op.get('response')))};
    },
    items(delivery) {
      return all('delivery_items','delivery = {:delivery}',{delivery:delivery}).map(item=>({
        id:item.id,confirmed:item.getBool('received_confirmed'),checkedBy:item.getString('checked_by'),checkedAt:item.getString('checked_at'),
        line:{line_id:item.getString('client_id'),source_row_id:item.getString('document_row'),page_id:item.getString('page_id'),
          name:item.getString('name_snapshot'),supplier_code:item.getString('supplier_code'),product_id:item.getString('product'),
          proposed_new:item.getBool('proposed_new_product'),requested_quantity:item.getFloat('requested_quantity'),
          received_quantity:item.getFloat('received_quantity'),expiry_date:item.getString('expiry_date'),
          lot_number:item.getString('lot_number'),checked:item.getString('review_status')==='checked'},
      }));
    },
    claim(id,revision) {
      const result=new DynamicModel({id:''});
      try {
        app.db().newQuery("UPDATE deliveries SET revision=revision+1 WHERE id={:id} AND status='draft' AND revision={:revision} RETURNING id")
          .bind({id:id,revision:revision}).one(result);
      } catch(error) {const conflict=new Error('delivery_revision_conflict');conflict.status=409;throw conflict;}
      if(result.id!==id) {const error=new Error('delivery_revision_conflict');error.status=409;throw error;}
    },
    createOperation(employee,key,target,hash) {
      return insert('inventory_operations',{employee:employee,key:key,target:target,kind:'finalize',payload_hash:hash});
    },
    products() {return app.findAllRecords('products').map(p=>({id:p.id,name:p.getString('name'),active:p.getBool('active')}));},
    createProduct(name) {const p=insert('products',{name:name,barcode:'',category:'',active:true});return {id:p.id,name:name,active:true};},
    resolveItem(id,product,lot) {const item=record('delivery_items',id);item.set('product',product);item.set('lot_number',lot);app.save(item);},
    createBatch(delivery,item,product,line,actor) {
      return insert('batches',{delivery:delivery,source_item:item,product:product,quantity:line.received_quantity,
        expiry_date:line.expiry_date+' 00:00:00.000Z',lot_number:line.lot_number,created_by:actor,status:'active',revision:1}).id;
    },
    createReceipt(batch,item,quantity,actor,operation) {
      return insert('stock_movements',{batch:batch,type:'received',quantity:quantity,employee:actor,operation:operation,
        line_key:operation+':'+item+':received'}).id;
    },
    completeDelivery(id,actor,revision) {
      const d=record('deliveries',id);d.set('status','finalized');d.set('revision',revision);
      d.set('finalized_by',actor);d.set('finalized_at',new Date().toISOString());app.save(d);
    },
    completeOperation(id,response) {const op=record('inventory_operations',id);op.set('response',response);app.save(op);},
  };
}
module.exports={create};

