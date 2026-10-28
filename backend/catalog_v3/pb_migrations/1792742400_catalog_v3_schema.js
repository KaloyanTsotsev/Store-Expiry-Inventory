// Additive catalog schema. Existing records and API Rules are preserved.
migrate(app => {
  const products = app.findCollectionByNameOrId('products');
  const employees = app.findCollectionByNameOrId('employees');
  for (const field of [
    {type:'json',name:'aliases',maxSize:65536},
    {type:'json',name:'supplier_identifiers',maxSize:131072},
    {type:'number',name:'catalog_revision',min:0,onlyInt:true},
  ]) {
    if (products.fields.getByName(field.name)) throw new Error('Catalog field collision: '+field.name);
    products.fields.add(new Field(field));
  }
  app.save(products);
  const rel=(name,id)=>({type:'relation',name,collectionId:id,maxSelect:1,cascadeDelete:false,required:true});
  const timestamps=[{type:'autodate',name:'created',onCreate:true,onUpdate:false},{type:'autodate',name:'updated',onCreate:true,onUpdate:true}];
  function create(name,fields,rule,indexes=[]) {
    let exists=false;try{app.findCollectionByNameOrId(name);exists=true;}catch(_){}
    if(exists)throw new Error('Catalog collection collision: '+name);
    app.save(new Collection({name,type:'base',fields:fields.concat(timestamps),listRule:rule,viewRule:rule,createRule:null,updateRule:null,deleteRule:null,indexes}));
  }
  create('product_catalog_audit',[rel('product',products.id),rel('actor',employees.id),{type:'text',name:'action',max:32},
    {type:'json',name:'before',maxSize:262144},{type:'json',name:'after',maxSize:262144}], '@request.auth.role = "admin" || @request.auth.role = "manager"');
  create('product_corrections',[rel('product',products.id),rel('employee',employees.id),{type:'json',name:'patch',maxSize:262144},
    {type:'number',name:'expected_revision',min:0,onlyInt:true},{type:'select',name:'status',values:['pending','approved','rejected'],maxSelect:1},
    {type:'relation',name:'reviewed_by',collectionId:employees.id,maxSelect:1,cascadeDelete:false},{type:'date',name:'reviewed_at'}],
    'employee = @request.auth.id || @request.auth.role = "admin" || @request.auth.role = "manager"');
  create('catalog_operations',[rel('employee',employees.id),{type:'text',name:'key',required:true,max:128},
    {type:'text',name:'hash',required:true,min:64,max:64},{type:'json',name:'response',maxSize:524288}],
    'employee = @request.auth.id',['CREATE UNIQUE INDEX idx_catalog_operation ON catalog_operations(employee, key)']);
},()=>{throw new Error('Restore an approved backup or reconcile catalog history; destructive down is disabled.');});
