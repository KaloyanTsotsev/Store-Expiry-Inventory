"""Confirmed production-schema regressions, run only by the localhost harness."""
import copy


def execute_confirmed_tests(api, admin, owner):
    def ok(reply, status=200):
        assert reply[0] == status, reply
        return reply[1]

    def rows(name):
        return ok(api('GET', '/api/collections/'+name+'/records?perPage=500', token=admin))['items']

    def counts():
        return {name: len(rows(name)) for name in ('products', 'batches', 'stock_movements', 'inventory_operations', 'catalog_operations')}

    schema = ok(api('GET', '/api/collections/products', token=admin))
    has_active = any(f['name'] == 'active' for f in schema['fields'])
    values = {'name': 'Existing confirmed product', 'barcode': '000-CONFIRMED/01'}
    if has_active:
        values['active'] = False  # Historical flag must not prevent reuse.
    product = ok(api('POST', '/api/collections/products/records', values, admin))

    def draft(key, code, product_id=''):
        body = {'client_id': key, 'operation_key': 'stage:'+key, 'expected_revision': 0,
                'pages': [{'id': 'p', 'recognized': True}],
                'lines': [{'line_id': 'row', 'source_row_id': 'original', 'page_id': 'p',
                           'name': 'Employee confirmed name', 'supplier_code': code,
                           'product_id': product_id, 'proposed_new': not product_id,
                           'requested_quantity': 4, 'received_quantity': 4,
                           'expiry_date': '2026-12-05', 'lot_number': 'N/A', 'checked': True}]}
        staged = ok(api('POST', '/api/store/drafts/stage', body, owner))
        request = {'operation_key': 'finalize:'+staged['delivery_id'],
                   'expected_revision': staged['revision'], 'lines': copy.deepcopy(body['lines'])}
        return staged, request

    for route, suffix in [('finalize', 'compatNormal'), ('finalize-article', 'compatArticle')]:
        staged, packet = draft(suffix, product['barcode'])
        endpoint = '/api/store/catalog/deliveries/'+staged['delivery_id']+'/'+route
        before = counts()
        changed = copy.deepcopy(packet)
        changed['lines'][0]['product_id'] = product['id']
        # Resolution is server-side; changing the employee's staged packet fails.
        ok(api('POST', endpoint, changed, owner), 409)
        assert counts() == before
        receipt = ok(api('POST', endpoint, packet, owner))
        assert receipt['lines'][0]['product_id'] == product['id']
        assert counts()['products'] == before['products']
        assert counts()['batches'] == before['batches']+1
        after = counts()
        assert ok(api('POST', endpoint, packet, owner)) == receipt
        assert counts() == after
        assert ok(api('GET', '/api/collections/products/records/'+product['id'], token=admin)) == product
    print('PASS CONFIRMED both Catalog routes: no supplier/approval flags, exact code, unchanged staged comparison, historical active=false reused, exact replay', flush=True)

    staged, packet = draft('compatNewNoSupplier', '0001234567890')
    receipt = ok(api('POST', '/api/store/catalog/deliveries/'+staged['delivery_id']+'/finalize', packet, owner))
    created = next(p for p in rows('products') if p['id'] == receipt['lines'][0]['product_id'])
    assert created['barcode'] == '0001234567890'
    assert not created.get('supplier_identifiers')
    assert any(a['product'] == created['id'] for a in rows('product_catalog_audit'))
    print('PASS CONFIRMED employee creates internal code without GTIN checksum, supplier association or manager approval; audit and stock committed together', flush=True)

    duplicate = ok(api('POST', '/api/collections/products/records', {'name': 'Conflicting confirmed product', 'barcode': product['barcode']}, admin))
    staged, packet = draft('compatDuplicateCode', product['barcode'])
    before = counts()
    reply = ok(api('POST', '/api/store/catalog/deliveries/'+staged['delivery_id']+'/finalize', packet, owner), 409)
    assert reply['code'] == 'conflicting_article_barcode'
    assert counts() == before
    assert duplicate['id'] != product['id']
    print('PASS CONFIRMED duplicate exact codes reject atomically without guessing by name or supplier', flush=True)

    manager = ok(api('POST', '/api/collections/employees/auth-with-password',
                     {'identity': 'manager', 'password': 'synthetic-test-only-40.4!'}))['token']
    minimal = {'operation_key': 'catalog:minimalCompatibility', 'product_id': '', 'expected_revision': 0,
               'fields': {'name': 'Minimal confirmed catalog', 'barcode': '000-CATALOG/01', 'category': ''}}
    result = ok(api('POST', '/api/store/catalog/products', minimal, manager))
    assert result['product']['barcode'] == '000-CATALOG/01'
    print('PASS CONFIRMED ordinary catalog creation needs no active/aliases/supplier_identifiers fields', flush=True)

    for scope in ['v2', 'catalog']:
        for kind in ['fields', 'rules', 'index']:
            diagnostic = ok(api('GET', '/api/store-test/capability/'+scope+'/'+kind, token=owner))
            assert diagnostic['result']['status'] == 503, diagnostic
            assert diagnostic['logged'], diagnostic
            public = str(diagnostic['result']['body'])
            assert 'batches' not in public and 'products' not in public and 'expiry_date' not in public, diagnostic
            assert any('batches' in entry or 'catalog_' in entry for entry in diagnostic['logged']), diagnostic
    print('PASS CONFIRMED missing field, unsafe rules and missing index fail capability checks with private diagnostic logs and sanitized public 503 responses; actual schema/rules untouched', flush=True)

    for endpoint in ['/api/store/capabilities', '/api/store/catalog/capabilities']:
        ok(api('GET', endpoint, token=owner))
    staged, _ = draft('compatDiscard', '000-DISCARD')
    before = counts()
    result = ok(api('POST', '/api/store/drafts/discard', {'client_id': 'compatDiscard'}, owner))
    assert result['status'] == 'discarded', result
    assert counts()['products'] == before['products']
    assert counts()['batches'] == before['batches']
    print('PASS CONFIRMED capabilities succeed with actual schema; unfinished draft discard route exists and preserves products/stock', flush=True)
