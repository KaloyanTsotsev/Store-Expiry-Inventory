# Каталог V3 и опционален OCR proxy

Допълнение към работещия PocketBase V2. Съществуващите V2 migrations/hooks не се заменят.

- `pb_migrations/1792742400_catalog_v3_schema.js`: additive products aliases/supplier_identifiers/catalog_revision + audit, corrections, operations.
- `activation_migrations/1792742401_catalog_v3_activate.js`: отделна activation; locked products Create/Update/Delete, само при `STORE_CATALOG_V3_ACTIVATE=I_HAVE_BACKUP_AND_TESTS`.
- `pb_hooks/catalog_v3.pb.js`, `pb_hooks/lib/catalog_v3.js`: employee-auth catalog API, admin/manager writes, pending staff proposals, role guard, transactions/revisions/idempotency и audit.
- `pb_hooks/ocr_v3.pb.js`: опционален authenticated proxy към loopback OCR sidecar; не записва продукти/доставки.
- `../ocr_service/`: независима Python/Pillow/Tesseract услуга, systemd unit, read-only compatibility probe и smoke инструмент.

## Нови маршрути

| Метод / маршрут | Действие |
| --- | --- |
| GET `/api/store/catalog/capabilities` | Готовност и can_manage за текущия служител |
| POST `/api/store/catalog/products` | Създава или редактира продукт, запазва ID и audit |
| POST `/api/store/catalog/corrections` | Записва pending предложение; не редактира продукт |
| POST `/api/store/catalog/confirm-match` | Manager/admin потвърждава алиас/доставчически код; employee предлага за одобрение |
| POST `/api/store/ocr/recognize` | Native OCR чрез отделната OnePlus услуга |

Catalog writes изискват `STORE_CATALOG_V3_ENABLED=approved`, готова схема/уникален journal index и locked директни Rules. Всеки write има operation_key; идентични повторения връщат същия отговор. Различен payload със същия ключ или стара revision се отказва. След timeout във Flutter формата се повтаря същата заявка; полетата се заключват до получаване на резултат. При затваряне на формата след неизвестен create резултат проверете каталога преди нов запис; durable catalog outbox между рестартирания не е реализиран. Сървърната проверка за име/идентификатори предотвратява идентично повторно създаване.

Save body: `operation_key`, `product_id` (празно за нов), `expected_revision`, `fields` (name, barcode, category, active, aliases, supplier_identifiers), optional `suggestion_id` за одобряване. Confirm-match body: operation_key/product_id/expected_revision/alias/supplier/code. Артикул без supplier не се приема. Кодове се сравняват като текст с водещи нули. GTIN се сравнява след checksum и padding до 14 цифри; валидна контролна цифра не е доказателство за автентичност.

Новият role guard блокира не-admin присвояване/редактиране на employees.role през REST, когато V3 е включен. Не изменя account Rules или реални роли. Superuser и admin запазват възможността за администриране; manager не може да назначава роли. Прегледайте и съществуващи custom auth endpoints на production, ако има такива.

Изпълнение: `python backend/tool/test_backend.py --catalog --flutter`. OCR вече използва съществуващия PaddleOCR API; вижте `docs/paddleocr-integration.md`. Старият Tesseract пакет е изведен от употреба. За OCR-only update: `python backend/tool/package_paddle_proxy.py`.

Пълен [отчет](../../docs/catalog-ocr-v3-report.md) и [точни deployment инструкции](../../docs/catalog-ocr-v3-deployment.md). Не копирайте `test`, `tool`, fixture бази или test fault hooks в live директориите.
