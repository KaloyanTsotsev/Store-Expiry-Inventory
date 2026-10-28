"""Exact-version localhost integration tests; never connects to production."""
import base64, argparse, concurrent.futures, copy, hashlib, json, os, pathlib, shutil, socket, sqlite3, subprocess, tempfile, time, urllib.request, urllib.error
ROOT=pathlib.Path(__file__).resolve().parents[2]
BACKEND=ROOT/'backend'
PASSWORD='synthetic-test-only-40.4!'
IDS={'owner':'emp000000000001','manager':'emp000000000002','other':'emp000000000003'}
def run_command(binary,args,env):
    result=subprocess.run([str(binary),*map(str,args)],env=env,capture_output=True,text=True,creationflags=0x08000000 if os.name=='nt' else 0)
    if result.returncode: raise RuntimeError(result.stdout+'\n'+result.stderr)
    return result.stdout

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',default=str(ROOT/'build/backend-v2/runtime/bin/pocketbase.exe'));parser.add_argument('--bootstrap-only',action='store_true');parser.add_argument('--flutter',action='store_true');parser.add_argument('--catalog',action='store_true');args=parser.parse_args()
    binary=pathlib.Path(args.binary).resolve()
    version=run_command(binary,['--version'],os.environ.copy()).strip()
    assert version.endswith('version 0.40.4'),version
    base=ROOT/'build/backend-v2/runs';base.mkdir(parents=True,exist_ok=True)
    work=pathlib.Path(tempfile.mkdtemp(prefix='v2-',dir=base));data=work/'pb_data';migrations=work/'pb_migrations';migrations.mkdir()
    schema=json.loads((BACKEND/'test/fixtures/v1_schema.json').read_text(encoding='utf-8-sig'))
    seed='''migrate(app=>{if($os.getenv('STORE_V2_TEST_SEED')!=='LOCAL_FIXTURES_ONLY')throw new Error('Test fixtures only');
app.importCollections(SCHEMA,false);
function put(name,values){const r=new Record(app.findCollectionByNameOrId(name));r.load(values);app.save(r);}
put('_superusers',{email:'backend-test@example.test',password:PASS});
put('employees',{id:'emp000000000001',email:'owner@example.test',username:'owner',name:'Synthetic owner',role:'employee',password:PASS});
put('employees',{id:'emp000000000002',email:'manager@example.test',username:'manager',name:'Synthetic manager',role:'manager',password:PASS});
put('employees',{id:'emp000000000003',email:'other@example.test',username:'other',name:'Synthetic other',role:'employee',password:PASS});
put('products',{id:'prd000000000001',name:'Legacy fixture',active:true});
put('deliveries',{id:'dlv000000000001',supplier:'Synthetic legacy',received_by:'emp000000000001'});
put('batches',{id:'bat000000000001',product:'prd000000000001',delivery:'dlv000000000001',created_by:'emp000000000001',quantity:9,lot_number:'OLD',expiry_date:'2026-11-08 00:00:00.000Z'});
put('stock_movements',{id:'mov000000000001',batch:'bat000000000001',type:'received',quantity:9,employee:'emp000000000001'});
});'''.replace('SCHEMA',json.dumps(schema,ensure_ascii=False)).replace('PASS',json.dumps(PASSWORD))
    (migrations/'1700000000_test_fixture.js').write_text(seed,encoding='utf-8')
    env=os.environ.copy();env.update(STORE_V2_TEST_SEED='LOCAL_FIXTURES_ONLY',STORE_V2_ACTIVATE='I_HAVE_BACKUP_AND_TESTS',STORE_FINALIZE_V2_ENABLED='approved')
    hooks=work/'pb_hooks';shutil.copytree(BACKEND/'pb_hooks',hooks)
    if args.catalog:
        for source in (BACKEND/'catalog_v3/pb_hooks').rglob('*.js'):
            target=hooks/source.relative_to(BACKEND/'catalog_v3/pb_hooks');target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
        env['STORE_CATALOG_DELIVERY_FINALIZE_ENABLED']='approved';env['STORE_CATALOG_V3_ENABLED']='approved';env['STORE_CATALOG_V3_ACTIVATE']='I_HAVE_BACKUP_AND_TESTS';env['STORE_OCR_URL']='http://127.0.0.1:8765/ocr';env['STORE_OCR_PROVIDER']='paddle-v5'
    (hooks/'test_fault.pb.js').write_text("onRecordCreateExecute(e=>{if($os.getenv('STORE_V2_TEST_FAULTS')==='LOCAL_ONLY' && e.record.getFloat('quantity')===13)throw new Error('TEST_ONLY_ROLLBACK');return e.next();},'stock_movements');",encoding='utf-8')
    env['STORE_V2_TEST_FAULTS']='LOCAL_ONLY'
    flags=['--dir='+str(data),'--migrationsDir='+str(migrations),'--hooksDir='+str(hooks),'--automigrate=false']
    print('Runtime:',version,'\nIsolated workspace:',work,flush=True)
    print(run_command(binary,['migrate','up',*flags],env),flush=True)
    def snapshots():
        with sqlite3.connect(data/'data.db') as db:
            records={name:db.execute('select * from '+name).fetchall() for name in ['products','deliveries','batches','stock_movements']}
            rules=db.execute("select name,createRule,updateRule,deleteRule from _collections where name in ('deliveries','batches','stock_movements') order by name").fetchall()
            columns={name:[r[1] for r in db.execute('pragma table_info('+name+')')] for name in records}
        return records,rules,columns
    before,rules,columns=snapshots()
    for source in (BACKEND/'pb_migrations').glob('*.js'):shutil.copy2(source,migrations/source.name)
    print(run_command(binary,['migrate','up',*flags],env),flush=True)
    if args.catalog:
        for source in (BACKEND/'catalog_v3/pb_migrations').glob('*.js'):shutil.copy2(source,migrations/source.name)
        print(run_command(binary,['migrate','up',*flags],env),flush=True)
    after,after_rules,_=snapshots();assert after_rules==rules,'Additive migration changed existing rules'
    with sqlite3.connect(data/'data.db') as db:
        for name in before:
            selected=db.execute('select '+','.join('"'+c+'"' for c in columns[name])+' from '+name).fetchall()
            assert selected==before[name],('Legacy values modified',name)
    print('PASS additive schema preserves all original legacy values and API Rules',flush=True)
    if args.bootstrap_only:return
    # Activation is applied only to this disposable synthetic database, AFTER
    # creating endpoint files. Production activation remains a separate step.
    for source in (BACKEND/'activation_migrations').glob('*.js'):shutil.copy2(source,migrations/source.name)
    print(run_command(binary,['migrate','up',*flags],env),flush=True)
    if args.catalog:
        for source in (BACKEND/'catalog_v3/activation_migrations').glob('*.js'):shutil.copy2(source,migrations/source.name)
        print(run_command(binary,['migrate','up',*flags],env),flush=True)
    with socket.socket() as listener:listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
    url='http://127.0.0.1:'+str(port)
    logfile=open(work/'server.log','w',encoding='utf-8')
    process=subprocess.Popen([str(binary),'serve','--http=127.0.0.1:'+str(port),*flags],env=env,stdout=logfile,stderr=subprocess.STDOUT,creationflags=0x08000000 if os.name=='nt' else 0)
    def api(method,path,body=None,token=None,files=None):
        assert url.startswith('http://127.0.0.1:')
        headers={'Content-Type':'application/json'}
        if token:headers['Authorization']=token
        payload=None if body is None else json.dumps(body).encode()
        if files:
            boundary='test-boundary-v2-40-4';headers['Content-Type']='multipart/form-data; boundary='+boundary
            chunks=[]
            for key,value in (body or {}).items():chunks.append(('--'+boundary+'\r\nContent-Disposition: form-data; name="'+key+'"\r\n\r\n'+str(value)+'\r\n').encode())
            for key,filename,data_bytes in files:
                chunks.append(('--'+boundary+'\r\nContent-Disposition: form-data; name="'+key+'"; filename="'+filename+'"\r\nContent-Type: image/png\r\n\r\n').encode()+data_bytes+b'\r\n')
            chunks.append(('--'+boundary+'--\r\n').encode());payload=b''.join(chunks)
        request=urllib.request.Request(url+path,data=payload,headers=headers,method=method)
        try:
            with urllib.request.urlopen(request,timeout=30) as response:return response.status,json.load(response)
        except urllib.error.HTTPError as error:
            return error.code,json.loads(error.read().decode() or '{}')
    try:
        for _ in range(150):
            if process.poll() is not None:raise RuntimeError((work/'server.log').read_text())
            try:
                if api('GET','/api/health')[0]==200:break
            except OSError:pass
            time.sleep(.1)
        else:raise RuntimeError('Local server did not start')
        status,auth=api('POST','/api/collections/_superusers/auth-with-password',{'identity':'backend-test@example.test','password':PASSWORD});assert status==200,(status,auth);admin=auth['token']
        status,auth=api('POST','/api/collections/employees/auth-with-password',{'identity':'owner','password':PASSWORD});assert status==200,(status,auth);owner=auth['token']
        execute_tests(api,admin,owner,work)
        if args.catalog:
            from test_catalog import execute_catalog_tests
            execute_catalog_tests(api,admin,owner,work)
            from test_delivery_catalog import execute_delivery_catalog_tests
            execute_delivery_catalog_tests(api,admin,owner,work)
            from test_ocr_proxy import execute_ocr_proxy_tests
            execute_ocr_proxy_tests(api,owner,work,url)
        if args.flutter:
            flutter=shutil.which('flutter')
            if not flutter:raise RuntimeError('Flutter SDK not found')
            completed=subprocess.run([flutter,'test','--no-pub','test/backend_v2_http_test.dart',*(['test/catalog_v3_http_test.dart'] if args.catalog else []),'--dart-define=PB_V2_TEST_URL='+url],cwd=ROOT,env=env,capture_output=True,text=True,shell=os.name=='nt')
            print(completed.stdout,flush=True)
            if completed.returncode:raise RuntimeError(completed.stderr+'\nFlutter SDK live-backend test failed')
            report=json.loads((ROOT/'build/backend-v2/latest-report.json').read_text());report['flutter_live_sdk']='passed'
            (ROOT/'build/backend-v2/latest-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            if args.catalog:
                report_path=ROOT/'build/backend-v3/latest-report.json';catalog_report=json.loads(report_path.read_text(encoding='utf-8'));catalog_report['flutter_live_sdk']='passed';report_path.write_text(json.dumps(catalog_report,ensure_ascii=False,indent=2),encoding='utf-8')
    finally:
        process.terminate()
        try:process.wait(timeout=10)
        except subprocess.TimeoutExpired:process.kill();process.wait()
        logfile.close()

def execute_tests(api,admin,owner,work):
    results=[]
    def passed(name):results.append(name);print('PASS',name,flush=True)
    def expect(status,response,expected):assert status==expected,(status,response,expected)
    def login(identity):
        code,response=api('POST','/api/collections/employees/auth-with-password',{'identity':identity,'password':PASSWORD});expect(code,response,200);return response['token']
    manager,other=login('manager'),login('other')
    def table(name):
        code,result=api('GET','/api/collections/'+name+'/records?perPage=500',token=admin);expect(code,result,200);return result['items']
    def counts():return {name:len(table(name)) for name in ['products','deliveries','delivery_items','batches','stock_movements','inventory_operations']}
    def stage_body(client,qty=(6,6),photo=False):
        return {'operation_key':'stage:'+client,'client_id':client,'expected_revision':0,'supplier':'Synthetic supplier','document_number':'TEST-'+client,
          'pages':[{'id':'page1','recognized':True,'has_photo':photo,'image_hash':'','text':'Synthetic original OCR','words':[]}],
          'lines':[{'line_id':'line'+str(i),'source_row_id':'source1','page_id':'page1','name':'Synthetic yoghurt '+client,'supplier_code':'90001',
            'product_id':'','proposed_new':True,'requested_quantity':12,'received_quantity':quantity,'expiry_date':['2026-11-08','2026-11-15'][i%2],
            'lot_number':'1' if i==0 else '', 'checked':True,'original_ocr':{'lot':'1' if i==0 else ''}} for i,quantity in enumerate(qty)]}
    def stage(body):
        code,response=api('POST','/api/store/drafts/stage',body,owner);expect(code,response,200);return response
    def finalize_request(stage_result,body,key=None):return {'operation_key':key or 'finalize:'+stage_result['delivery_id'],'expected_revision':stage_result['revision'],'lines':body['lines']}
    def finalize(d,body,token=owner):return api('POST','/api/store/deliveries/'+d['delivery_id']+'/finalize',body,token)
    code,response=api('GET','/api/store/capabilities',token=owner);expect(code,response,200);assert response['atomic_finalization'] is True
    passed('exact-version capabilities and employee auth')
    code,response=api('GET','/api/store/capabilities');expect(code,response,401);passed('anonymous requests rejected')
    initial=counts();b=stage_body('success');d=stage(b);again=stage(b);assert again==d,(d,again)
    packet=finalize_request(d,b);code,response=finalize(d,packet);expect(code,response,200)
    batches=[r for r in table('batches') if r.get('delivery')==d['delivery_id']]
    assert len(batches)==2 and {r['expiry_date'][:10] for r in batches}=={'2026-11-08','2026-11-15'}
    assert all(r['lot_number']=='N/A' and r['quantity']==6 for r in batches)
    assert len({r['id'] for r in batches})==2 and len({r['product'] for r in batches})==1
    assert counts()['products']==initial['products']+1 and counts()['stock_movements']==initial['stock_movements']+2
    passed('real atomic finalization creates one product, two distinct N/A batches and two received movements')
    saved=counts();code,repeated=finalize(d,packet);expect(code,repeated,200);assert repeated==response and counts()==saved
    passed('repeated stage and repeated finalization are idempotent')
    changed=copy.deepcopy(packet);changed['lines'][0]['received_quantity']=5
    code,response=finalize(d,changed);expect(code,response,409);assert counts()==saved
    passed('same key with changed payload rejected')
    code,response=finalize(d,finalize_request(d,b,'different-key'));expect(code,response,409);assert counts()==saved
    passed('second finalization key cannot duplicate a finalized delivery')
    for field,value in [('received_quantity',-1),('received_quantity','NaN'),('received_quantity',None),('expiry_date','2026-02-31'),('checked',False)]:
        b=stage_body('invalid'+str(len(results)));b['lines'][0][field]=value
        before=counts();code,response=api('POST','/api/store/drafts/stage',b,owner);expect(code,response,400);assert counts()==before
    passed('negative, NaN, missing quantity, invalid date and unchecked rows rejected without writes')
    b=stage_body('rollback',qty=(6,13));d=stage(b);before=counts()
    code,response=finalize(d,finalize_request(d,b));expect(code,response,409);assert counts()==before
    current=next(r for r in table('deliveries') if r['id']==d['delivery_id']);assert current['status']=='draft' and current['revision']==d['revision']
    passed('REAL SQLite rollback after first product/batch/receipt leaves no partial records or revision change')
    b=stage_body('race');d=stage(b);packet=finalize_request(d,b);before=counts()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        responses=list(pool.map(lambda token:finalize(d,packet,token),[owner,manager]))
    assert sorted(r[0] for r in responses)==[200,409],responses
    assert counts()['batches']==before['batches']+2 and counts()['stock_movements']==before['stock_movements']+2
    passed('two concurrent authenticated HTTP clients: one commit, one conflict, no duplicates')
    b=stage_body('foreign');d=stage(b);before=counts();code,response=finalize(d,finalize_request(d,b),other);expect(code,response,403);assert counts()==before
    code,response=api('PATCH','/api/collections/batches/records/bat000000000001',{'quantity':1},owner);assert code in (403,404),(code,response)
    passed('foreign employee and direct inventory CRUD cannot bypass protected endpoints')
    b=stage_body('zero',qty=(0,));b['lines'][0]['expiry_date']='';d=stage(b);before=counts()
    code,response=finalize(d,finalize_request(d,b));expect(code,response,200)
    after=counts();assert after['products']==before['products'] and after['batches']==before['batches'] and after['stock_movements']==before['stock_movements']
    passed('zero received quantity creates no product, batch or movement')
    image=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6T8AAAAASUVORK5CYII=')
    b=stage_body('photo',photo=True);b['pages'][0]['image_hash']=hashlib.sha256(image).hexdigest();d=stage(b)
    code,response=finalize(d,finalize_request(d,b));expect(code,response,409)
    path='/api/store/deliveries/'+d['delivery_id']+'/pages/page1/photo'
    photo_body={'expected_revision':d['revision'],'image_hash':b['pages'][0]['image_hash']}
    code,response=api('POST',path,photo_body,other,files=[('photo','test.png',image)]);expect(code,response,403)
    code,response=api('POST',path,photo_body,owner,files=[('photo','test.png',image)]);expect(code,response,200)
    photo_revision=response['revision'];assert photo_revision==d['revision']+1
    code,replay=api('POST',path,photo_body,owner,files=[('photo','test.png',image)]);expect(code,replay,200);assert replay['revision']==photo_revision
    code,current=api('GET','/api/store/deliveries/'+d['delivery_id']+'/status',token=owner);expect(code,current,200)
    assert current['pages'][0]['uploaded_hash']==b['pages'][0]['image_hash']
    d['revision']=photo_revision;code,response=finalize(d,finalize_request(d,b));expect(code,response,200)
    code,response=api('POST',path,photo_body,owner,files=[('photo','test.png',image)]);expect(code,response,409)
    passed('protected page staging, missing-photo rejection, idempotent upload and finalized photo lock')
    # Product identity is shared, receipt quantities/expiry/lot are per delivery.
    product_id=batches[0]['product']
    prior_batches=copy.deepcopy(table('batches'))
    prior_movements=copy.deepcopy(table('stock_movements'))
    products_before=counts()['products'];created_ids=[]
    for index,(quantity,expiry,lot) in enumerate([(12,'2026-11-08','L1'),(8,'2026-11-15','L2'),(6,'2026-11-22','L3')]):
        body=stage_body('sequential'+str(index),qty=(quantity,))
        body['lines'][0].update(product_id=product_id,proposed_new=False,expiry_date=expiry,lot_number=lot)
        before=counts();delivery=stage(body)
        assert stage(body)==delivery
        assert counts()['batches']==before['batches'] and counts()['stock_movements']==before['stock_movements']
        packet=finalize_request(delivery,body)
        code,receipt=finalize(delivery,packet);expect(code,receipt,200)
        after=counts();assert after['products']==products_before
        assert after['batches']==before['batches']+1 and after['stock_movements']==before['stock_movements']+1
        code,replay=finalize(delivery,packet);expect(code,replay,200);assert replay==receipt and counts()==after
        code,result=finalize(delivery,finalize_request(delivery,body,'another:'+str(index)));expect(code,result,409)
        current=[r for r in table('batches') if r.get('delivery')==delivery['delivery_id']]
        assert len(current)==1 and current[0]['product']==product_id and current[0]['quantity']==quantity
        assert current[0]['expiry_date'][:10]==expiry and current[0]['lot_number']==lot
        created_ids.append(current[0]['id'])
    assert len(set(created_ids))==3
    assert all(next(r for r in table('batches') if r['id']==old['id'])==old for old in prior_batches)
    assert all(next(r for r in table('stock_movements') if r['id']==old['id'])==old for old in prior_movements)
    passed('three sequential receipts reuse one product ID; independent 12/8/6 batches, dates/lots, no writes on stage, replay cannot double stock')
    # Legacy sentinel data is never backfilled or rewritten by the new workflow.
    old=next(r for r in table('batches') if r['id']=='bat000000000001');assert old['quantity']==9 and old['lot_number']=='OLD' and old['status']==''
    passed('legacy fixture records unchanged after all V2 operations')
    report={'runtime':'0.40.4','passed':results,'count':len(results),'workspace':str(work),'production_contacted':False}
    (work/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    (ROOT/'build/backend-v2/latest-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print('RESULT:',len(results),'integration scenarios passed',flush=True)

if __name__=='__main__':main()

