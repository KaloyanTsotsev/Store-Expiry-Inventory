# StoreFlow — баркодове към снимката

Реализирано на 26.10.2026. Production PocketBase/OnePlus, hooks, API Rules, миграции и съществуващи продукти не са променяни.

## Поведение

- `DraftPage.barcodes` пази стойност, изрично подаден тип и оригиналния metadata запис. Връзката е чрез ID на страницата, не чрез продуктов ред.
- Paddle адаптерът приема изрични **top-level** `barcodes` / `document_barcodes` списъци и единичен `barcode`. Елемент е string или обект с `value`/`text`/`data` (string), `type`/`format` (незадължителен string). Не извлича числа от свободния текст и не отгатва тип по дължина или checksum. Числова стойност не се преобразува в код, защото водещи нули може вече да са изгубени; оригиналният отговор се запазва.
- Няма добавен barcode decoder към OnePlus. Реалният предоставен Paddle fixture няма barcode metadata. Ако услугата не връща такова поле, списъкът е празен; всички нейни оригинални данни остават запазени. Промяна на OCR service договора изисква отделен преглед и разрешение.
- Повторно разпознаване заменя evidence на същата страница. Еднакви стойност + тип се показват веднъж; пълният оригинален отговор пази и повторенията. Различни страници запазват отделни списъци.
- Редовете продължават да използват supplier + article_code. Дори barcode в upstream продуктов JSON остава само в оригиналния OCR JSON и не попълва DraftItem.barcode.
- Създаването на продукт от доставка изпраща `fields.barcode: ""`, включително при стар локален DraftItem.barcode. Полето за „баркод от документа“ е премахнато от редактора. Съществуващи каталожни GTIN не се изтриват и не се презаписват.
- Истински продуктов GTIN се въвежда изрично в продуктовия каталожен редактор с неговите проверки и права.
- Стара недовършена каталожна заявка с непразен barcode се блокира, вместо да се преизпрати или да се промени payload под същия idempotency key. Обновяване на каталога може да разреши вече успешно записана асоциация; останалите случаи изискват управителска проверка. Не се правят автоматични поправки на стари данни.

## Съвместимост с V2

Съществуващото `delivery_pages.raw_ocr` е достатъчно. При баркодове `raw_ocr.text` съдържа JSON envelope:

```json
{
  "storeflow_page_evidence_version": 1,
  "page_id": "local-page-id",
  "original_ocr_text": "exact original serialized OCR response",
  "barcodes": [{"value": "000123", "type": "CODE_128", "original": {}}]
}
```

При липса на баркодове се запазва досегашният `text`. Локалната чернова сериализира списъка отделно. Пълният оригинален OCR отговор остава непроменен в `page.text` и в `original_ocr_text`. Atomic finalization и защитеният Paddle proxy са запазени. Няма нужда от backend deployment за тази промяна.

Catalog V3 е отделна предпоставка за създаване на продукти/асоциации. Последната read-only проверка върна 404 за capabilities; тази промяна не внедрява V3 и не добавя employee create права. Съществуващият UI показва липсващата capability и управителския процес; не заобикаля правата.

## Променени файлове

- `lib/models/delivery_draft.dart` — page barcode модел, сериализация, V2 evidence envelope.
- `lib/services/paddle_document_adapter.dart` — изолирано page metadata извличане и повторен импорт.
- `lib/screens/delivery_editor_screen.dart` — evidence към страницата и видим преглед на кодовете.
- `lib/screens/delivery_item_screen.dart` — премахнато въвеждане/валидация на документен баркод като GTIN.
- `lib/services/delivery_catalog_service.dart` — празен GTIN при създаване от доставка; защита на стари pending заявки.
- `lib/services/delivery_finalization_service.dart` — изпращане на page evidence чрез съществуващото raw_ocr.text.
- `test/page_barcode_test.dart` — седем теста: 37 продукта/един код, две снимки, няколко кода, повторен импорт, supplier identity без GTIN, нов продукт без GTIN/запазен съществуващ GTIN, стара pending заявка.
- `test/backend_v2_http_test.dart` — реална проверка на записаното evidence в локален PB.

## Проверки и APK

- `flutter analyze --no-pub`: без проблеми.
- `flutter test --no-pub`: 117 успешни; 2 live SDK теста пропуснати тук и изпълнени отделно.
- `python backend/tool/test_backend.py --catalog --flutter`: 14 V2, 10 Catalog, 6 Paddle proxy групи и 2 реални Flutter SDK теста — успешни. Изолирана localhost база с безопасни fixture данни и PocketBase 0.40.4.
- `flutter build apk --debug --no-pub`: успешен.
- APK: `C:\Users\cocev\AndroidStudioProjects\expiry_tracker\build\app\outputs\flutter-apk\app-debug.apk`
- Генериран: **26.10.2026 00:54:00 +02:00**, Europe/Sofia.
- SHA256: `D73E02FE8DD0D5474F2B6290D3799E62116397C03B99EE8457F040FD874E59F4`.
- Android label StoreFlow; application ID остава `com.expiry_tracker.expiry_tracker`.
- ADB показва само `127.0.0.1:5037 offline`; новият APK не е тестван на Galaxy A50 и не е инсталиран автоматично.

За обновяване: свържете/отключете A50, разрешете USB debugging, проверете `adb devices -l` и изберете реалния му serial. Не използвайте uninstall или clear data. При `INSTALL_FAILED_UPDATE_INCOMPATIBLE` спрете и проверете подписа, без да деинсталирате.

```powershell
& "C:\Users\cocev\AppData\Local\Android\sdk\platform-tools\adb.exe" devices -l
& "C:\Users\cocev\AppData\Local\Android\sdk\platform-tools\adb.exe" -s "SERIAL_ОТ_СПИСЪКА" install -r "C:\Users\cocev\AndroidStudioProjects\expiry_tracker\build\app\outputs\flutter-apk\app-debug.apk"
```
