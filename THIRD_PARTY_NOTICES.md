# OCR components

- Tesseract4Android 4.9.0: https://github.com/adaptech-cz/Tesseract4Android,
  Apache-2.0. Its native dependencies include Tesseract 5.5.1, Leptonica,
  libjpeg and libpng; their upstream notices remain applicable.
- Bulgarian and English models: https://github.com/tesseract-ocr/tessdata_fast,
  Apache-2.0. A copy of the license is bundled in Android assets/tessdata/LICENSE.
- bul.traineddata SHA-256:
  aebc9b0fcc8cfaf8a9f38a02bb7b85052bd850744696a2c11cf0081820e5b21e
- eng.traineddata SHA-256:
  7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2
- Tesseract.js 6.0.1 (Apache-2.0) is a development benchmark only; it is not
  included in the mobile app. npm package-lock pins the benchmark dependency.
- image_picker, path_provider and shared_preferences are Flutter plugins
  published by flutter.dev. Their licenses are included by Flutter tooling.

Photographs are user-supplied private test inputs. They are not app assets or
committed fixtures. Local raw OCR reports and screenshots are under ignored build/.
The committed document_reference.json contains only manually transcribed visible
product table cells, without the customer/supplier header.
