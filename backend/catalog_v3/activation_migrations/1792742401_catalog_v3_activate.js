migrate(app=>{
  if($os.getenv('STORE_CATALOG_V3_ACTIVATE')!=='I_HAVE_BACKUP_AND_TESTS')throw new Error('Catalog activation acknowledgement required');
  for(const name of ['product_catalog_audit','product_corrections','catalog_operations'])app.findCollectionByNameOrId(name);
  const products=app.findCollectionByNameOrId('products');
  products.createRule=null;products.updateRule=null;products.deleteRule=null;app.save(products);
},()=>{throw new Error('Do not reopen unaudited catalog writes automatically.');});
