> Historical Tesseract baseline — superseded on 25.10.2026 by [PaddleOCR integration](paddleocr-integration.md). Do not deploy the old sidecar, unit or packages.

# OCR профил PSM 3 — 22.10.2026

## Основание и поведение

Собственикът измери native Tesseract 5.5.2, bul+eng на OnePlus 6: PSM 6 — 24.20 s с липсващи редове; PSM 3 — 11.46 s с почти всички редове. Това са предоставени измервания, не резултати от новия pipeline. Предишният проект използваше PSM 4.

Началният профил вече е PSM 3 и в Python sidecar, и в Android. EXIF, осветеност/контраст, ограничен размер, ориентация и deskew се запазват. Python използва TSV confidence и геометрични центрове за редове между различни Tesseract blocks. При средна увереност под 75 или код, започващ с 300/500, прави PSM 7 върху до четири най-несигурни реда с разпознат 7–12 цифрен код в лявата четвърт. Това е евристика за тази разписка, не универсална детекция на всички документи. Непознатите формати остават за ръчно въвеждане. Колоните се структурират от съществуващите Flutter геометрични parsers.

Повторенията са последователни, до 5 s на ред, общо до 20 s в общия 100 s deadline. Основният OCR резултат остава наличен при неуспешно опционално повторение. Една задача и OMP_THREAD_LIMIT=2 остават. Прочитите са отделни `refinements`, с TSV confidence и координати в обработената снимка. Flutter ги съхранява в локалната чернова и ги показва под страницата за сравнение по снимката; **не ги слива автоматично с първия прочит**. Първоначалните text/words/original на редовете и оригиналната снимка остават. Refinements не променят V2 wire contract.

При точно одобрено supplier+code съвпадение името в черновата става каталожното име; original['name'] остава OCR текстът. Ръчният избор от каталога също попълва каталожното име. Каталожният запис не се преименува. Несъвпадащ артикулен код не се подменя чрез еднакво име; името става предложение за ръчен избор. Кодове 300/500 никога не се преобразуват автоматично в 900. Непознат продукт не включва автоматично „нов продукт“ — това е изрично действие на служителя. Не се променят migrations, API Rules, hooks или логиката на V2 финализирането.

`1` не е дата; `1`/празна партида става N/A без отделно lot предупреждение. Всяко положително прието количество изисква валидна дата, избран/изрично предложен продукт и физическа проверка. OCR и каталогът не маркират реда като проверен.

## Локална проверка

- `flutter analyze`: без проблеми.
- `flutter test --no-pub`: 71 успешни, 2 live SDK теста се изпълняват отделно.
- `backend/tool/test_backend.py --catalog --flutter`: 13 V2 + 9 catalog сценария, 2 реални SDK теста, JSVM proxy — успешни в отделна локална база с тестови данни.
- `backend/ocr_service/test_service.py`: 8 успешни. Native CLI е изрично заместен в автоматичните тестове; проверени са аргументи, TSV, ограничени повторения, координати, отказ, оригинални данни, auth и конкурентност.
- Debug APK се компилира. Новият PSM 3 профил не е повторно измерен на Galaxy A50 или OnePlus в тази промяна.

## Отделен реален тест на OnePlus, без PocketBase

Пакетът `store-ocr-psm3-test.tar.gz` съдържа само OCR инструменти, тестове и този документ. Не включва PocketBase hooks/migrations, база или снимки. Не заменяйте работещите файлове. След ръчно копиране на архива в `/home/user/` изпълнете като `user`:

```sh
mkdir /home/user/store-ocr-psm3-test
tar -xzf /home/user/store-ocr-psm3-test.tar.gz -C /home/user/store-ocr-psm3-test
cd /home/user/store-ocr-psm3-test
sha256sum -c SHA256SUMS
python3 runtime_check.py --require-oneplus
python3 test_service.py
python3 benchmark.py --image /absolute/path/to/document.jpg --output /home/user/ocr-psm3-result-01.json
```

Използвайте същата снимка като предишните тестове и не стартирайте паралелни benchmark процеси. Папката трябва да е нова; съществуващ JSON не се презаписва. Командите не спират услуги и benchmark не свързва PocketBase. `test_service.py` ползва само временни loopback сървъри. При липсващ Pillow не инсталирайте или сменяйте системни пакети автоматично — първо прегледайте наличните зависимости.

Сравнете ръчно: открити продуктови редове спрямо документа, точни кодове, имена, количества, разделяне дата/партида, грешни валидни дати, първи срещу повторен прочит и общо време. Брой думи или висок confidence не доказват точност. JSON съдържа частен OCR текст; съхранявайте го с ограничен достъп. След този тест може да се одобри отделно замяна само на OCR sidecar кода и рестарт на OCR услугата; production PocketBase не е променян от тази задача.

## Променени файлове

- `backend/ocr_service/pipeline.py`, `test_service.py`, нов `benchmark.py`.
- `android/app/src/main/kotlin/com/expiry_tracker/expiry_tracker/MainActivity.kt`.
- `lib/models/delivery_draft.dart`, `lib/services/product_matcher.dart`.
- `lib/screens/delivery_editor_screen.dart`, `lib/screens/delivery_item_screen.dart`.
- `test/catalog_v3_test.dart`, `test/ux_v3_test.dart`.
- Този документ и препратката в `docs/catalog-ocr-v3-report.md`.

Режимите PSM 3/7 и нуждата от сегментация на таблици са описани в [официалната Tesseract документация](https://tesseract-ocr.github.io/tessdoc/ImproveQuality.html). Подобрението на точността на конкретния нов pipeline предстои да се измери, а не се предполага.
