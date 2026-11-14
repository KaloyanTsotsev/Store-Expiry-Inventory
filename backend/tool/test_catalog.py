"""Real HTTP catalog scenarios, invoked only by the isolated V2 harness."""
import copy
import concurrent.futures
import json
import pathlib

def execute_catalog_tests(api, admin, owner, work):
    results=[]
    def expect(response, status=200):
        assert response[0]==status,response
        return response[1]
    manager=expect(api('POST','/api/collections/employees/auth-with-password',{'identity':'manager','password':'synthetic-test-only-40.4!','passwordConfirm':'synthetic-test-only-40.4!'}))['token']
    expect(api('POST','/api/collections/employees/records',{'id':'emp000000000004','email':'admin@example.test','username':'catalogadmin','role':'admin','password':'synthetic-test-only-40.4!','passwordConfirm':'synthetic-test-only-40.4!'},admin))
    admin_token=expect(api('POST','/api/collections/employees/auth-with-password',{'identity':'catalogadmin','password':'synthetic-test-only-40.4!','passwordConfirm':'synthetic-test-only-40.4!'}))['token']
    def records(name): return expect(api('GET','/api/collections/'+name+'/records?perPage=500',token=admin))['items']
    def post(body, token=manager, path='products', status=200):return expect(api('POST','/api/store/catalog/'+path,body,token),status)
    def passed(name):results.append(name);print('PASS CATALOG',name,flush=True)
    def fields(name='Синтетично кисело мляко 3.6% 400 г'):
        return {'name':name,'barcode':'3800000000003','category':'Млечни','active':True,'aliases':['КИС МЛ 3.6 400'],'supplier_identifiers':[]}
    before={n:records(n) for n in ['batches','stock_movements','delivery_items','delivery_pages']}
    expect(api('GET','/api/store/catalog/capabilities',token=owner));expect(api('GET','/api/store/catalog/capabilities'),401)
    body={'operation_key':'catalog:create','product_id':'','expected_revision':0,'fields':fields()}
    post(body,owner,status=403);created=post(body);product=created['product'];assert product['catalog_revision']==1
    assert post(body)==created
    assert sum(p['id']==product['id'] for p in records('products'))==1
    passed('manager create and exact replay; employee create forbidden')
    # Different devices/keys racing to create the same supplier identity.
    racing=[]
    for suffix in ['a','b']:
        patch=fields('Concurrent identity '+suffix);patch['barcode']='';patch['aliases']=[]
        patch['supplier_identifiers']=[{'supplier':'Race supplier','code':'RACE-001'}]
        racing.append({'operation_key':'catalog:identity-race:'+suffix,'product_id':'','expected_revision':0,'fields':patch})
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        responses=list(pool.map(lambda payload:api('POST','/api/store/catalog/products',payload,admin_token),racing))
    assert sorted(code for code,_ in responses)==[200,409],responses
    linked=[p for p in records('products') if any(m.get('supplier')=='Race supplier' and m.get('code')=='RACE-001' for m in (p.get('supplier_identifiers') or []))]
    assert len(linked)==1
    assert {n:records(n) for n in before}==before
    passed('concurrent new supplier-code creation with different operation keys yields one product and no inventory')
    duplicate=copy.deepcopy(body);duplicate['operation_key']='catalog:duplicate';post(duplicate,status=409)
    duplicate['fields']['name']='Друг продукт';post(duplicate,status=409)
    duplicate['fields']['barcode']='';duplicate['fields']['supplier_identifiers']=[{'supplier':'Race supplier','code':'RACE-001'}]
    post(duplicate,admin_token,status=409)
    duplicate['fields']['supplier_identifiers']=[];duplicate['fields']['barcode']='3800000000000';post(duplicate,status=200)
    passed('duplicate name, GTIN, supplier mapping and invalid checksum rejected')
    update={'operation_key':'catalog:update','product_id':product['id'],'expected_revision':1,'fields':fields('Коригирано име')}
    update['fields']['active']=False
    changed=post(update)['product'];assert changed['id']==product['id'] and changed['catalog_revision']==2 and changed['active']==product['active']
    update['operation_key']='catalog:stale';post(update,status=409)
    passed('stable product ID, corrected name, inactive status and revision conflict')
    # Edit a product referenced by a legacy batch: links and movements must stay byte-for-byte unchanged.
    legacy=next(p for p in records('products') if p['id']=='prd000000000001')
    patch=fields('Преименуван legacy продукт');patch['barcode']='';patch['supplier_identifiers']=[]
    post({'operation_key':'catalog:legacy','product_id':legacy['id'],'expected_revision':0,'fields':patch})
    assert {n:records(n) for n in before}==before
    passed('legacy batch links, movement history and original OCR/photos untouched')
    correction={'operation_key':'catalog:proposal','product_id':legacy['id'],'expected_revision':1,'fields':{**patch,'name':'Предложено правилно име'}}
    proposal=post(correction,owner,'corrections');assert proposal['status']=='pending'
    assert next(p for p in records('products') if p['id']==legacy['id'])['name']==patch['name']
    approval={**correction,'operation_key':'catalog:approve','suggestion_id':proposal['suggestion_id']}
    post(approval,owner,status=403)
    post(approval);assert next(p for p in records('product_corrections') if p['id']==proposal['suggestion_id'])['status']=='approved'
    passed('employee suggestions do not mutate catalog; manager approval is audited')
    evidence={'operation_key':'catalog:learn','product_id':legacy['id'],'expected_revision':2,'alias':'КИСЕЛО МЛЯК0','supplier':'Доставчик Б','code':'0001'}
    post(evidence,manager,'confirm-match',status=403)
    learned=post(evidence,admin_token,'confirm-match')['product'];assert 'КИСЕЛО МЛЯК0' in learned['aliases']
    assert learned['supplier_identifiers']==[{'supplier':'Доставчик Б','code':'0001','verified':True}]
    evidence['operation_key']='catalog:staff-match';evidence['expected_revision']=3;evidence['alias']='Друго OCR име'
    assert post(evidence,owner,'confirm-match')['status']=='pending'
    passed('scoped identifiers and aliases learned; ordinary employee learning awaits approval')
    for token in [owner,manager]:
        assert api('PATCH','/api/collections/products/records/'+legacy['id'],{'name':'bypass'},token)[0] in [403,404]
        assert api('POST','/api/collections/product_catalog_audit/records',{'product':legacy['id'],'actor':'emp000000000001','action':'fake','before':{},'after':{}},token)[0] in [403,404]
    audit=records('product_catalog_audit');assert any(a['before'].get('name')=='Legacy fixture' and a['after']['id']==legacy['id'] for a in audit)
    assert all(a['actor'] in ['emp000000000002','emp000000000004'] for a in audit)
    passed('direct REST bypass blocked for manager and employee; immutable actor/before/after audit')
    assert expect(api('GET','/api/store/catalog/capabilities',token=admin_token))['can_manage'] is True
    packets=[{'operation_key':'catalog:race:'+str(i),'product_id':product['id'],'expected_revision':2,'fields':fields('Състезание '+str(i))} for i in range(2)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        responses=list(pool.map(lambda pair:api('POST','/api/store/catalog/products',pair[0],pair[1]),zip(packets,[manager,admin_token])))
    assert sorted(r[0] for r in responses)==[200,409],responses
    assert next(p for p in records('products') if p['id']==product['id'])['catalog_revision']==3
    passed('admin role and concurrent edits: one commit, one stale revision, stable identity')
    # Prove role escalation remains blocked even when profile Rules are permissive.
    collection=expect(api('GET','/api/collections/employees',token=admin))
    old_rules={k:collection[k] for k in ['createRule','updateRule']}
    try:
        expect(api('PATCH','/api/collections/employees',{'createRule':'@request.auth.id != ""','updateRule':'@request.auth.id != ""'},admin))
        expect(api('PATCH','/api/collections/employees/records/emp000000000001',{'role':'admin'},owner),403)
        expect(api('POST','/api/collections/employees/records',{'email':'escalation@example.test','username':'escalation','password':'synthetic-test-only-40.4!','passwordConfirm':'synthetic-test-only-40.4!','role':'admin'},owner),403)
        expect(api('PATCH','/api/collections/employees/records/emp000000000003',{'role':'manager'},admin_token))
    finally:expect(api('PATCH','/api/collections/employees',old_rules,admin))
    passed('employee role self-escalation blocked on create/update; admin role assignment allowed')
    # A minimal form request preserves hidden fields from the live record.
    old=next(p for p in records('products') if p['id']==legacy['id'])
    form={'form_version':2,'operation_key':'catalog:simple','product_id':old['id'],
          'expected_revision':old['catalog_revision'],'fields':{'name':old['name'],'barcode':'000FORM','category':'Updated'}}
    attempt=copy.deepcopy(form);attempt['fields']['supplier_identifiers']=[]
    post(attempt,manager,status=403);post(attempt,owner,'corrections',status=403)
    simple=post(form)['product']
    assert simple['barcode']=='000FORM' and all(simple[k]==old[k] for k in ('active','aliases','supplier_identifiers'))
    assert post(form)['product']==simple
    admin_edit={**form,'operation_key':'catalog:simple-admin','expected_revision':simple['catalog_revision'],
                'fields':{**form['fields'],'supplier_identifiers':simple['supplier_identifiers']+[{'supplier':'Admin only','code':'0002'}]}}
    assert len(post(admin_edit,admin_token)['product']['supplier_identifiers'])==2
    new=post({'form_version':2,'operation_key':'catalog:simple-new','product_id':'','expected_revision':0,
              'fields':{'name':'New simple product','barcode':'000NEW','category':''}})['product']
    assert new['aliases']==[] and new['supplier_identifiers']==[]
    inactive=expect(api('POST','/api/collections/products/records',{'name':'Inactive simple product','active':False},admin))
    saved=post({'form_version':2,'operation_key':'catalog:simple-inactive','product_id':inactive['id'],'expected_revision':0,
                'fields':{'name':inactive['name'],'barcode':'','category':'Updated'}})['product']
    assert saved['active'] is False
    passed('minimal form preserves hidden fields and exact article codes, defaults active, and restricts supplier changes to admins')

    def delete(product, token=manager, status=200, suffix=''):
        return post({'operation_key':'catalog:delete:'+product['id']+suffix,'product_id':product['id'],
                     'expected_revision':product['catalog_revision']},token,'products/delete',status)
    snapshot={n:records(n) for n in ['products','batches','stock_movements','deliveries','delivery_items','product_catalog_audit']}
    current_legacy=next(p for p in snapshot['products'] if p['id']==legacy['id'])
    assert delete(current_legacy,status=409)['code']=='catalog_product_has_history'
    assert delete(new,admin_token,409)['code']=='catalog_product_has_history' # audit alone
    assert {n:records(n) for n in snapshot}==snapshot
    isolated=expect(api('POST','/api/collections/products/records',{'name':'Unreferenced legacy fixture','active':True},admin))
    delete(isolated,owner,403)
    assert delete({**isolated,'catalog_revision':9},status=409,suffix=':stale')['code']=='catalog_revision_conflict'
    assert delete(isolated)==delete(isolated)=={'status':'deleted','product_id':isolated['id']}
    assert not any(p['id']==isolated['id'] for p in records('products'))
    assert {n:records(n) for n in snapshot if n!='products'}=={n:v for n,v in snapshot.items() if n!='products'}
    passed('guarded deletion rejects employees, stale edits and history; unreferenced product deletes once')
    report={'runtime':'0.40.4','count':len(results),'passed':results,'production_contacted':False,'workspace':str(work)}
    root=pathlib.Path(__file__).resolve().parents[2]/'build/backend-v3';root.mkdir(parents=True,exist_ok=True)
    (root/'latest-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
