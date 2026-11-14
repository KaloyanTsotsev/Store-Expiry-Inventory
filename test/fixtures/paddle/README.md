# Real PaddleOCR response and existing API source

Provided by the owner on 25 October 2026. http-test-v2.json and ocr_api.py are exact byte copies; manifest.json records SHA256 and sizes. The Python source is evidence only and is never executed/deployed by the tests. Real JSON has 37 products and 23 valid dates/lot numbers; this is a single-document fixture, not a universal parser guarantee. Neither file is an APK asset or part of the proxy release.

`document.jpg` is the redacted original photograph supplied by the owner, copied without image transformations. The real-SDK delivery test uploads it with the recorded JSON, explicitly supplies synthetic dates for the 14 missing dates, and checks all 37 persisted batches. No missing date is inferred automatically.
