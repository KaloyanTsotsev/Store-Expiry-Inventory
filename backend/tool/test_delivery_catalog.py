"""Atomic employee delivery/catalog integration on synthetic localhost PB only."""
import concurrent.futures
import copy
import json
import pathlib


def execute_delivery_catalog_tests(api, admin, owner, work):
    results = []
    def ok(reply, code=200):
        assert reply[0] == code, reply
        return reply[1]
    def login(identity):
        return ok(api('POST', '/api/collections/employees/auth-with-password',
                      {'identity': identity, 'password': 'synthetic-test-only-40.4!'}))['token']
    manager, admin_role = login('manager'), login('catalogadmin')
    def records(name):
        return ok(api('GET', '/api/collections/'+name+'/records?perPage=500', token=admin))['items']
    def counts():
        return {n: len(records(n)) for n in ['products','batches','stock_movements','catalog_operations','inventory_operations','product_catalog_audit']}
    def passed(name):
        results.append(name)
        print('PASS DELIVERY CATALOG', name, flush=True)
    def body(client, codes=('CODE1',), qty=6, expiry='2026-11-08'):
        return {'client_id': client, 'operation_key': 'stage:'+client, 'expected_revision': 0,
                'supplier': 'Bulk synthetic supplier', 'pages': [{'id':'page1','recognized':True}],
                'lines': [{'line_id':'line'+str(i), 'source_row_id':'row'+str(i), 'page_id':'page1',
                           'name':'Bulk '+code, 'supplier_code':code, 'product_id':'', 'proposed_new':True,
                           'requested_quantity':qty, 'received_quantity':qty, 'expiry_date':expiry,
                           'lot_number':'N/A','checked':True} for i,code in enumerate(codes)]}
    def stage(b, token=owner):
        return ok(api('POST','/api/store/drafts/stage',b,token))
    def packet(d,b):
        return {'operation_key':'finalize:'+d['delivery_id'], 'expected_revision':d['revision'],
                'lines':copy.deepcopy(b['lines']), 'catalog_confirmed':True}
    def finish(d,p,token=owner):
        return api('POST','/api/store/catalog/deliveries/'+d['delivery_id']+'/finalize',p,token)
    for token in [owner, manager, admin_role]:
        assert ok(api('GET','/api/store/catalog/capabilities',token=token))['delivery_catalog_finalize'] is True
    ok(api('POST','/api/store/catalog/deliveries/invalid/finalize',{}),401)
    passed('employee, manager and admin capability; anonymous rejected')
    b=body('bulk37', tuple('ROW'+str(i) for i in range(37)))
    before=counts(); d=stage(b)
    assert counts()['products']==before['products'] and counts()['batches']==before['batches']
    before=counts()
    p=packet(d,b); missing=copy.deepcopy(p); missing['catalog_confirmed']=False
    ok(finish(d,missing),400); assert counts()==before
    receipt=ok(finish(d,p)); after=counts()
    assert after['products']==before['products']+37 and after['batches']==before['batches']+37
    assert after['stock_movements']==before['stock_movements']+37
    assert after['product_catalog_audit']==before['product_catalog_audit']+37
    assert len(receipt['lines'])==37
    created=[r for r in records('products') if r['name'].startswith('Bulk ROW')]
    assert len(created)==37 and all(r['barcode']=='' for r in created)
    assert all(r['supplier_identifiers'][0]['verified'] is True for r in created)
    assert ok(finish(d,p))==receipt and counts()==after
    changed=copy.deepcopy(p);changed['lines'][0]['name']='Changed'
    ok(finish(d,changed),409); assert counts()==after
    other=stage(body('otherDelivery', ('OTHER',)))
    after_other_stage=counts()
    ok(finish(other,p),409); assert counts()==after_other_stage
    passed('37 new products, associations and receipts in one commit; explicit confirmation; exact replay; changed payload/target rejected')
    for index,token in enumerate([manager,admin_role]):
        b=body('rolebulk'+str(index), ('ROLE'+str(index),));d=stage(b,token)
        ok(finish(d,packet(d,b),token))
    passed('manager and admin create new OCR products through same atomic route')
    # One identity, independent deliveries and distinct expiry batches, plus two rows in a document.
    ids=[]
    for index,(qty,expiry) in enumerate([(12,'2026-11-08'),(8,'2026-11-15'),(6,'2026-11-22')]):
        b=body('bulkseq'+str(index), ('SEQUENTIAL',),qty,expiry);d=stage(b)
        reply=ok(finish(d,packet(d,b)));ids.append(reply['lines'][0]['product_id'])
    assert len(set(ids))==1
    b=body('bulkTwoLots', ('SEQUENTIAL','SEQUENTIAL'));b['lines'][1].update(expiry_date='2026-12-15',lot_number='L2')
    d=stage(b);reply=ok(finish(d,packet(d,b)))
    assert len({r['batch_id'] for r in reply['lines']})==2
    assert all(r['product_id']==ids[0] for r in reply['lines'])
    passed('one identity across 12/8/6 deliveries and separate expiry/lot rows; no quantity merging')
    b=body('bulkrollback', ('ROLLBACK1','ROLLBACK2'));b['lines'][1]['received_quantity']=13
    d=stage(b);before=counts();staged_before=copy.deepcopy(records('delivery_items'))
    ok(finish(d,packet(d,b)),409);assert counts()==before
    assert records('delivery_items')==staged_before
    current=next(r for r in records('deliveries') if r['id']==d['delivery_id'])
    assert current['status']=='draft' and current['revision']==d['revision']
    passed('real receipt fault rolls back products, associations, audits, staged IDs, stock and operation journals')
    # Reject invented product identity instead of guessing by name.
    b=body('bulkconflict', ('NEWCODE',));b['lines'][0]['name']='Bulk ROW0'
    d=stage(b);before=counts();ok(finish(d,packet(d,b)),409);assert counts()==before
    b=body('bulkinvalid', ('INVALID',));b['lines'][0]['expiry_date']=''
    ok(api('POST','/api/store/drafts/stage',b,owner),400)
    b=body('bulkunchecked', ('INVALID',));b['lines'][0]['checked']=False
    ok(api('POST','/api/store/drafts/stage',b,owner),400)
    b=body('bulkphoto', ('MISSINGPHOTO',));b['pages'][0].update(has_photo=True,image_hash='a'*64)
    d=stage(b);before=counts();ok(finish(d,packet(d,b)),409);assert counts()==before
    b=body('bulkforeign', ('FOREIGN',));d=stage(b,manager);before=counts()
    ok(finish(d,packet(d,b),owner),403);assert counts()==before
    passed('conflicting identity/name, missing expiry/photo, unchecked rows and foreign employee cannot write')
    b=body('bulkrace', ('RACE',));d=stage(b);p=packet(d,b);before=counts()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        replies=list(pool.map(lambda token:finish(d,p,token), [owner,manager]))
    assert sorted(r[0] for r in replies)==[200,409],replies
    assert counts()['products']==before['products']+1 and counts()['batches']==before['batches']+1
    # Independently confirmed deliveries share a code, not a stock operation.
    a,b=body('twophones1',('RACECODE',)),body('twophones2',('RACECODE',))
    da,db=stage(a),stage(b,manager)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        replies=list(pool.map(lambda args:finish(*args), [(da,packet(da,a),owner),(db,packet(db,b),manager)]))
    # SQLite may return busy; replay the SAME request, never generate a new key.
    for i,args in enumerate([(da,packet(da,a),owner),(db,packet(db,b),manager)]):
        if replies[i][0]!=200: replies[i]=finish(*args)
    assert all(r[0]==200 for r in replies),replies
    assert replies[0][1]['lines'][0]['product_id']==replies[1][1]['lines'][0]['product_id']
    assert sum(p['name']=='Bulk RACECODE' for p in records('products'))==1
    passed('two callers cannot double-finalize; concurrent independent deliveries reuse one catalog identity')
    report={'runtime':'0.40.4','count':len(results),'passed':results,'production_contacted':False,'workspace':str(work)}
    target=pathlib.Path(__file__).resolve().parents[2]/'build/backend-v3/delivery-catalog-report.json'
    target.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
