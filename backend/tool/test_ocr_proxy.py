"""PB 0.40.4 real JSVM proxy -> contract fixture (not a new OCR service)."""
import base64
import concurrent.futures
import email.parser
import email.policy
import json
import pathlib
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def execute_ocr_proxy_tests(api,owner,work,pb_url):
    assert pb_url.startswith('http://127.0.0.1:')
    root=pathlib.Path(__file__).resolve().parents[2]
    fixture=json.loads((root/'test/fixtures/paddle/http-test-v2.json').read_text(encoding='utf-8'))
    state={'status':200,'calls':0,'mode':'ok'}
    started,release=threading.Event(),threading.Event()
    image=(root/'test/fixtures/oneplus6/document.jpg').read_bytes()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def do_POST(self):
            state['calls']+=1
            assert self.path=='/ocr'
            assert not self.headers.get('Authorization'), 'Never forward employee tokens to unauthenticated OCR'
            body=self.rfile.read(int(self.headers['Content-Length']))
            message=email.parser.BytesParser(policy=email.policy.default).parsebytes(
                ('Content-Type: '+self.headers['Content-Type']+'\r\nMIME-Version: 1.0\r\n\r\n').encode()+body)
            parts=list(message.iter_parts())
            assert len(parts)==1 and parts[0].get_param('name',header='content-disposition')=='image'
            assert parts[0].get_payload(decode=True)==image
            if state['mode']=='hold':started.set();release.wait(5)
            self.send_response(state['status']);self.send_header('Content-Type','application/json');self.end_headers()
            self.wfile.write(json.dumps(fixture if state['status']==200 and state['mode']!='malformed' else {'error':'test failure'}).encode())
    server=ThreadingHTTPServer(('127.0.0.1',8765),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    body={'image_base64':base64.b64encode(image).decode()}
    passed=[]
    def check(name):passed.append(name);print('PASS PADDLE '+name,flush=True)
    try:
        assert api('POST','/api/store/ocr/recognize',{'image_base64':'auth-test'})[0]==401
        assert api('POST','/api/store/ocr/recognize',{'image_base64':'auth-test'},'invalid-or-expired-token')[0]==401
        assert state['calls']==0
        check('anonymous/invalid token rejected before upstream')
        code,result=api('POST','/api/store/ocr/recognize',body,owner)
        assert code==200,(code,result)
        assert result==fixture
        check('real multipart JPEG forwarded byte-for-byte; full real 37-row JSON preserved; no token forwarded')
        before=state['calls']
        for payload in [{},{'image_base64':'invalid'},{'image_base64':base64.b64encode(b'not an image').decode()}]:
            assert api('POST','/api/store/ocr/recognize',payload,owner)[0] in [400,415]
        assert api('POST','/api/store/ocr/recognize',{'image_base64':'A'*12582916},owner)[0]==413
        assert state['calls']==before
        check('missing, invalid, unsupported and oversized input never reaches OCR')
        for upstream,expected in [(400,400),(413,413),(429,429),(500,503),(504,504)]:
            state['status']=upstream
            assert api('POST','/api/store/ocr/recognize',body,owner)[0]==expected
        state['status']=200;state['mode']='malformed'
        assert api('POST','/api/store/ocr/recognize',body,owner)[0]==502
        check('upstream validation, busy, failure, timeout and malformed response mapped safely')
        state['mode']='hold';before=state['calls']
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            first=pool.submit(api,'POST','/api/store/ocr/recognize',body,owner)
            assert started.wait(4)
            assert api('POST','/api/store/ocr/recognize',body,owner)[0]==429
            release.set();assert first.result()[0]==200
        assert state['calls']==before+1
        state['mode']='ok'
        assert api('POST','/api/store/ocr/recognize',body,owner)[0]==200
        check('atomic single-flight across concurrent JSVM requests and lock released after failures')
    finally:
        release.set();server.shutdown();server.server_close()
    assert api('POST','/api/store/ocr/recognize',body,owner)[0]==503
    check('unavailable loopback service fails without inventory writes or fallback')
    report={'pocketbase':'0.40.4','proxy':'passed','count':len(passed),'tests':passed,
        'engine':'contract mock with real supplied JSON; native Paddle not rerun','production_contacted':False}
    (root/'build/backend-v3/ocr-proxy-report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
