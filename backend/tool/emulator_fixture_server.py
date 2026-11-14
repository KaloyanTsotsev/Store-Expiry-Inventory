"""Recorded Paddle contract replay for isolated emulator testing, never production."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def hold_runtime(root, work, url):
    response = (root/'test/fixtures/paddle/http-test-v2.json').read_bytes()
    image = (root/'test/fixtures/paddle/document.jpg').read_bytes()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            data = image if self.path == '/document.jpg' else b'{"engine":"recorded Paddle replay"}'
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg' if self.path == '/document.jpg' else 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response)))
            self.end_headers()
            self.wfile.write(response)
    server = ThreadingHTTPServer(('127.0.0.1', 8765), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    state = {'url': url, 'work': str(work), 'stop_file': str(work/'STOP_EMULATOR_TEST'),
             'provider': 'recorded real Paddle response, not live inference', 'production_contacted': False}
    (root/'build/emulator-test-runtime.json').write_text(json.dumps(state), encoding='utf-8')
    print('EMULATOR TEST BACKEND READY:', url, flush=True)
    try:
        deadline = time.monotonic()+7200
        while not (work/'STOP_EMULATOR_TEST').exists() and time.monotonic() < deadline:
            time.sleep(1)
    finally:
        server.shutdown()
        server.server_close()
