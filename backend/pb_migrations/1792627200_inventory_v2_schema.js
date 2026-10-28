/// Additive V2 schema only. Existing records and API Rules are untouched.
migrate((app) => {
  const expected={employees:'pbc_2964849126',products:'pbc_4092854851',deliveries:'pbc_2444735992',batches:'pbc_1631394489',stock_movements:'pbc_3471998555'};
  for(const name of Object.keys(expected)) {
    const c=app.findCollectionByNameOrId(name);
    if(c.id!==expected[name]) throw new Error('Unexpected collection ID: '+name);
  }
  for(const name of ['delivery_items','delivery_pages','inventory_operations']) {
    let exists=false;try {app.findCollectionByNameOrId(name);exists=true;} catch(_) {}
    if(exists) throw new Error('Refusing to overwrite pre-existing collection '+name);
  }
  const employee=expected.employees,delivery=expected.deliveries,product=expected.products;
  function rel(name,collectionId,required=false) {return {type:'relation',name,collectionId,maxSelect:1,cascadeDelete:false,required};}
  function text(name,max=128) {return {type:'text',name,max};}
  function num(name) {return {type:'number',name,min:0,onlyInt:false};}
  function integer(name) {return {type:'number',name,min:0,onlyInt:true};}
  const timestamps=[{type:'autodate',name:'created',onCreate:true,onUpdate:false},{type:'autodate',name:'updated',onCreate:true,onUpdate:true}];
  function create(name,fields,indexes,readRule='@request.auth.id != ""') {
    const c=new Collection({name,type:'base',fields:fields.concat(timestamps),indexes,listRule:readRule,viewRule:readRule,createRule:null,updateRule:null,deleteRule:null});app.save(c);return c;
  }
  const operations=create('inventory_operations',[rel('employee',employee,true),{...text('key'),required:true},
    {type:'select',name:'kind',values:['draft_save','finalize','photo'],maxSelect:1},text('target'),
    {type:'text',name:'payload_hash',min:64,max:64,required:true}, {type:'json',name:'response',maxSize:1048576}],
    ['CREATE UNIQUE INDEX idx_operation_key ON inventory_operations(employee, key)'],'employee = @request.auth.id');
  const items=create('delivery_items',[rel('delivery',delivery,true),{...text('client_id',64),required:true},text('page_id',64),text('document_row',64),integer('position'),
    text('supplier_code'),text('name_snapshot',1000),rel('product',product),{type:'bool',name:'proposed_new_product'},
    num('requested_quantity'),num('received_quantity'),{type:'bool',name:'received_confirmed'},text('unit',32),
    {type:'date',name:'expiry_date'},text('lot_number'),text('difference_raw'),{type:'json',name:'original_ocr',maxSize:65536},
    {type:'select',name:'review_status',values:['unchecked','checked'],maxSelect:1},rel('checked_by',employee),{type:'date',name:'checked_at'}],
    ['CREATE UNIQUE INDEX idx_items_client ON delivery_items(delivery, client_id)']);
  create('delivery_pages',[rel('delivery',delivery,true),{...text('client_id',64),required:true},
    {type:'file',name:'photo',maxSelect:1,maxSize:15728640,mimeTypes:['image/jpeg','image/png','image/webp'],protected:true},
    text('image_hash',64),text('uploaded_hash',64),{type:'json',name:'raw_ocr',maxSize:2097152}],
    ['CREATE UNIQUE INDEX idx_delivery_page ON delivery_pages(delivery, client_id)'],'delivery.received_by = @request.auth.id || @request.auth.role = "manager" || @request.auth.role = "admin"');
  function add(name,fields,indexes) {
    const c=app.findCollectionByNameOrId(name);
    for(const field of fields) {
      if(c.fields.getByName(field.name)) throw new Error('Unexpected pre-existing field '+name+'.'+field.name);
      c.fields.add(new Field(field));
    }
    c.indexes=Array.from(c.indexes).concat(indexes);app.save(c);
  }
  add('deliveries',[{type:'select',name:'status',values:['legacy','draft','finalized','cancelled'],maxSelect:1},integer('revision'),text('client_id',64),
    {type:'date',name:'document_date'},{type:'json',name:'ocr_draft',maxSize:4194304},rel('finalized_by',employee),{type:'date',name:'finalized_at'}],
    ["CREATE UNIQUE INDEX idx_deliveries_client ON deliveries(received_by, client_id) WHERE client_id != ''"]);
  add('batches',[rel('source_item',items.id),{type:'select',name:'status',values:['needs_review','active','closed'],maxSelect:1},integer('revision'),
    {type:'bool',name:'has_observed_count'},num('observed_quantity'),{type:'date',name:'observed_at'},rel('observed_by',employee),{type:'date',name:'closed_at'},rel('closed_by',employee)],
    ["CREATE UNIQUE INDEX idx_batch_source ON batches(source_item) WHERE source_item != ''"]);
  add('stock_movements',[rel('operation',operations.id),text('line_key',160),text('reason',2000)],
    ["CREATE UNIQUE INDEX idx_movement_line ON stock_movements(line_key) WHERE line_key != ''"]);
}, () => {throw new Error('V2 rollback must restore a verified backup; down migration must not delete inventory history.');});
