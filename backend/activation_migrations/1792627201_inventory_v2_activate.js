// SEPARATE ACTIVATION PHASE. Never copy automatically with additive migrations.
migrate((app)=>{
  if($os.getenv('STORE_V2_ACTIVATE')!=='I_HAVE_BACKUP_AND_TESTS') throw new Error('Explicit activation acknowledgement required');
  for(const name of ['delivery_items','delivery_pages','inventory_operations']) app.findCollectionByNameOrId(name);
  for(const name of ['deliveries','batches','stock_movements']) {
    const c=app.findCollectionByNameOrId(name);
    c.createRule=null;c.updateRule=null;c.deleteRule=null;app.save(c);
  }
},()=>{throw new Error('Restore the reviewed backup and previous release; never reopen direct writes with history present.');});
