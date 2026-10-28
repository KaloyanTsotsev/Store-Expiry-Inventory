import json
import subprocess
import tempfile
import threading
from pathlib import Path

from flask import Flask, jsonify, request

ROOT = Path("/home/user/ocr-paddle-test")
PYTHON = ROOT / "venv/bin/python"
ENGINE = ROOT / "ocr_engine.py"
OUTPUT = ROOT / "ocr-output.json"

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024

ocr_lock = threading.Lock()


@app.get("/health")
def health():
    return jsonify({
        "status": "ok",
        "service": "store-ocr",
        "engine": "PaddleOCR"
    })


@app.post("/ocr")
def recognize():
    # Само една OCR заявка едновременно.
    if not ocr_lock.acquire(blocking=False):
        return jsonify({"error": "OCR is busy"}), 429

    try:
        uploaded = request.files.get("image")

        if uploaded is None or not uploaded.filename:
            return jsonify({"error": "Missing image"}), 400

        with tempfile.TemporaryDirectory(prefix="store-ocr-") as temp:
            image_path = Path(temp) / "upload.jpg"
            result_path = Path(temp) / "result.json"
            uploaded.save(image_path)

            # Проверяваме дали файлът действително е изображение.
            import cv2

            if cv2.imread(str(image_path)) is None:
                return jsonify({"error": "Invalid image"}), 400

            completed = subprocess.run(
                [str(PYTHON), str(ENGINE), str(image_path), str(result_path)],
                capture_output=True,
                text=True,
                timeout=180,
                cwd=str(ROOT),
                env={
                    **__import__("os").environ,
                    "OMP_NUM_THREADS": "4",
                    "OPENBLAS_NUM_THREADS": "4",
                },
            )

            if completed.returncode != 0:
                app.logger.error("OCR failed: %s", completed.stderr[-2000:])
                return jsonify({"error": "OCR processing failed"}), 500

            result = json.loads(result_path.read_text(encoding="utf-8"))
            return jsonify(result)

    except subprocess.TimeoutExpired:
        return jsonify({"error": "OCR timeout"}), 504

    finally:
        ocr_lock.release()


if __name__ == "__main__":
    app.run(
        host="127.0.0.1",
        port=8765,
        debug=False,
        use_reloader=False,
        threaded=True,
    )
