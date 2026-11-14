"""Real PocketBase API assertions; called only inside the localhost fixture harness."""
import concurrent.futures
import copy
import datetime


def execute_batch_deletion_tests(api, admin, owner, manager, stage, finalize, finalize_request, stage_body, table, passed, product_id):
    def ok(result, expected=200):
        assert result[0] == expected, result
        return result[1]

    def make(client, day):
        body = stage_body(client, qty=(2, 3))
        for i, line in enumerate(body['lines']):
            line.update(product_id=product_id, proposed_new=False, expiry_date=str(day+datetime.timedelta(days=i)))
        staged = stage(body)
        receipt = ok(finalize(staged, finalize_request(staged, body)))
        ids = [r['batch_id'] for r in receipt['lines']]
        batches = [next(b for b in table('batches') if b['id'] == id) for id in ids]
        return body, staged, receipt, batches

    for label, day in [('expired', datetime.date(2020, 1, 1)), ('future', datetime.date.today()+datetime.timedelta(days=30))]:
        body, staged, final_receipt, (target, sibling) = make('delete'+label, day)
        path = '/api/store/batches/'+target['id']+'/handle'
        packet = {'action': 'delete_batch', 'expected_revision': target['revision'], 'expiry_date': target['expiry_date'][:10]}
        originals = {n: copy.deepcopy(table(n)) for n in ('products', 'deliveries', 'delivery_items', 'stock_movements', 'inventory_operations')}
        ok(api('POST', path, packet), 401)
        ok(api('POST', path, {k: v for k, v in packet.items() if k != 'action'}, owner), 409)
        ok(api('POST', path, {**packet, 'action': 'handled'}, owner), 409)
        ok(api('POST', path, {**packet, 'expected_revision': 99}, owner), 409)
        ok(api('POST', path, {**packet, 'expiry_date': '2021-01-01'}, owner), 409)
        assert all(table(n) == rows for n, rows in originals.items())
        first = ok(api('POST', path, packet, owner))
        assert first == {'batch_id': target['id'], 'status': 'deleted', 'deleted': True}
        # No record/revision remains; another authenticated session confirms absence.
        ok(api('GET', '/api/collections/batches/records/'+target['id'], token=manager), 404)
        assert ok(api('POST', path, packet, manager)) == first
        assert ok(api('POST', path, {**packet, 'expected_revision': 99, 'expiry_date': '2021-01-01'}, owner)) == first
        assert not any(b['id'] == target['id'] for b in table('batches'))
        assert next(b for b in table('batches') if b['id'] == sibling['id']) == sibling
        for name in ('products', 'deliveries', 'delivery_items', 'inventory_operations'):
            assert table(name) == originals[name], name
        movements = table('stock_movements')
        assert len(movements) == len(originals['stock_movements'])
        for before in originals['stock_movements']:
            after = next(m for m in movements if m['id'] == before['id'])
            if before['batch'] != target['id']:
                assert after == before
            else:
                assert after['batch'] == ''  # normal PB optional-relation cleanup
                assert target['id'] in after['notes'] and product_id in after['notes']
                assert after['notes'].startswith(before['notes'])
                for field in before:
                    if field not in ('batch', 'notes', 'updated'):
                        assert after[field] == before[field], field
        stable = copy.deepcopy(movements)
        assert ok(api('POST', path, packet, owner)) == first
        assert table('stock_movements') == stable  # snapshot not appended twice
        # A replayed delivery receipt must not recreate the deleted batch.
        assert ok(finalize(staged, finalize_request(staged, body))) == final_receipt
        assert not any(b['id'] == target['id'] for b in table('batches'))
        passed(label+' permanent batch deletion: product/sibling/delivery/history retained, two sessions, repeat and finalize replay')

    _, _, _, (target, _) = make('deleteConcurrent', datetime.date.today()+datetime.timedelta(days=30))
    path = '/api/store/batches/'+target['id']+'/handle'
    packet = {'action': 'delete_batch', 'expected_revision': target['revision'], 'expiry_date': target['expiry_date'][:10]}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        replies = list(pool.map(lambda token: api('POST', path, packet, token), [owner, manager]))
    assert all(r[0] in (200, 409) for r in replies), replies
    assert ok(api('POST', path, packet, owner))['deleted'] is True
    assert not any(b['id'] == target['id'] for b in table('batches'))
    passed('concurrent permanent deletion and safe retry without remaining revision')

    # A legacy movement has no delivery-item/operation link: the existing notes
    # snapshot is essential to preserve its product/expiry context after unlink.
    legacy = ok(api('POST', '/api/collections/batches/records', {'product': product_id,
        'quantity': 7.5, 'lot_number': 'LEGACY', 'expiry_date': '2030-01-01', 'revision': 0}, admin))
    movement = ok(api('POST', '/api/collections/stock_movements/records', {'batch': legacy['id'],
        'type': 'received', 'quantity': 7.5, 'employee': 'emp000000000001', 'notes': 'Original legacy note'}, admin))
    ok(api('POST', '/api/store/batches/'+legacy['id']+'/handle',
        {'action': 'delete_batch', 'expected_revision': 0, 'expiry_date': '2030-01-01'}, owner))
    after = ok(api('GET', '/api/collections/stock_movements/records/'+movement['id'], token=manager))
    assert after['batch'] == '' and after['quantity'] == 7.5
    assert after['notes'].startswith('Original legacy note\n[StoreFlow batch deletion] ')
    assert product_id in after['notes'] and legacy['id'] in after['notes'] and '2030-01-01' in after['notes']
    passed('legacy movement without source-item link retains original notes and deleted-batch/product/expiry snapshot')

    # Schema perturbations are performed via authenticated PB API on synthetic data ONLY.
    _, _, _, (target, _) = make('deleteDependencies', datetime.date(2020, 1, 1))
    path = '/api/store/batches/'+target['id']+'/handle'
    packet = {'action': 'delete_batch', 'expected_revision': target['revision'], 'expiry_date': target['expiry_date'][:10]}
    for index, options in enumerate([{'cascadeDelete': True}, {'required': True}, {}]):
        schema = ok(api('POST', '/api/collections', {'name': 'test_batch_ref_'+str(index), 'type': 'base',
            'fields': [{'name': 'batch', 'type': 'relation', 'collectionId': 'pbc_1631394489', 'maxSelect': 1, **options}]}, admin))
        ref = ok(api('POST', '/api/collections/'+schema['id']+'/records', {'batch': target['id']}, admin))
        before = {n: copy.deepcopy(table(n)) for n in ('batches', 'stock_movements', 'products')}
        result = ok(api('POST', path, packet, owner), 409)
        assert result['code'] in ('incompatible_batch_dependency', 'unsupported_batch_dependency')
        assert all(table(n) == rows for n, rows in before.items())
        ok(api('GET', '/api/collections/'+schema['id']+'/records/'+ref['id'], token=admin))
        ok(api('DELETE', '/api/collections/'+schema['id'], token=admin), 204)
    # Fault hook fires after movement snapshots are saved but before deletion.
    ok(api('PATCH', '/api/collections/batches/records/'+target['id'], {'lot_number': 'TEST_DELETE_ROLLBACK'}, admin))
    before = {n: copy.deepcopy(table(n)) for n in ('batches', 'stock_movements', 'products')}
    result = ok(api('POST', path, packet, owner), 409)
    assert result['code'] == 'batch_deletion_not_confirmed'
    assert all(table(n) == rows for n, rows in before.items())
    passed('required/cascade/unknown dependencies refuse deletion; late failure rolls back batch and history snapshots')
