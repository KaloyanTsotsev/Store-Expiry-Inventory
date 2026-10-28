# PocketBase V2 — изпълнима локално проверена реализация

Версия: **PocketBase 0.40.4**. Не е инсталирана на `192.168.1.200`.
За точния systemd план, backup и rollback вижте [инструкциите](../docs/pocketbase-v2-deployment.md).

## Файлове за внедряване

| Файл | Предназначение |
| --- | --- |
| `pb_migrations/1792627200_inventory_v2_schema.js` | Добавя V2 полета, таблици и уникални индекси; запазва старите записи и правила |
| `activation_migrations/1792627201_inventory_v2_activate.js` | Отделна фаза: забранява директни Create/Update/Delete на deliveries, batches, stock_movements |
| `pb_hooks/delivery_finalize.pb.js` | Регистрира защитените маршрути |
| `pb_hooks/lib/handlers.js` | Staging, снимки, capabilities, status и транзакционни handlers |
| `pb_hooks/lib/delivery_finalization.js` | Валидация, продуктово съпоставяне, N/A, идемпотентност, финализиране |
| `pb_hooks/lib/pocketbase_store.js` | Реални PocketBase операции само през transaction app |
| `tool/test_backend.py` | Изолиран реален HTTP/SQLite тест с фиктивни данни |
| `test/fixtures/v1_schema.json` | Схема, реконструирана от предоставените exports, със синтетична employees колекция |
| `tool/fetch_runtime.ps1` | Официален runtime 0.40.4 с проверка SHA256 |
| `tool/package_release.py` | Production-only tar.gz + SHA256 manifest, без тестови hooks/данни |

**Не копирайте `test`, `tool`, `backend_review` или генерираните тестови migrations на сървъра.**
Защитният тестов hook, който предизвиква rollback, се генерира единствено в `build/backend-v2/runs/`.

## Повторение на локалните тестове на Windows

От корена на Flutter проекта, с Python 3 и Flutter в PATH:

```powershell
powershell -File backend/tool/fetch_runtime.ps1
python backend/tool/test_backend.py --binary build/backend-v2/downloads/windows_amd64/bin/pocketbase.exe --flutter
flutter analyze
flutter test --no-pub
flutter build apk --debug --no-pub
```

Harness-ът изисква точно 0.40.4, създава нова база под `build/backend-v2/runs/`, слуша само на случаен `127.0.0.1` порт и спира процеса при завършване. Не използва реален superuser, токен или производствени данни. `--bootstrap-only` създава само V1 fixture + additive V2 схема без activation. `--flutter` изпълнява и реалния Dart PocketBase SDK тест, докато локалният сървър работи. Обичайното `flutter test` пропуска този тест, защото му трябва изолираният сървър.

Последен машинен отчет: `build/backend-v2/latest-report.json`; обобщение: [проверки](../docs/pocketbase-v2-validation.md).

## Протокол

Всички маршрути изискват валиден токен от **employees**, а не superuser. По подразбиране връщат 503, докато няма `STORE_FINALIZE_V2_ENABLED=approved`, нужната схема, уникални индекси и заключени директни записи.

| Метод / маршрут | Резултат |
| --- | --- |
| GET `/api/store/capabilities` | protocol 2, staging/photos/atomic_finalization |
| POST `/api/store/drafts/stage` | Сървърна чернова + проверени позиции + оригинален OCR; без продукти/наличности |
| POST `/api/store/deliveries/{id}/pages/{page}/photo` | Защитена снимка на предварително staged страница; увеличава revision |
| GET `/api/store/deliveries/{id}/status` | Състояние, revision и качени страници |
| POST `/api/store/deliveries/{id}/finalize` | Една DB транзакция за липсващи продукти, партиди, входящи движения и finalized |

Staging приема `operation_key`, `client_id`, `expected_revision`, metadata, `pages` и `lines`. Finalize приема `operation_key`, `expected_revision` и точните проверени `lines`. Авторът на физическата проверка се взема от автентикирания служител при staging, не от подаден employee ID. Собственикът качва черновата/снимките; собственик, manager или admin може да финализира. Finalize сравнява заявката с реално записаните сървърни позиции.

Същият actor + operation_key + същото съдържание връща запазения отговор. Променено съдържание със същия ключ, стара revision и второ финализиране с друг ключ връщат конфликт. SQL compare-and-swap, транзакцията и уникалните индекси защитават и при два телефона. След timeout се повтаря същата замразена заявка, без нов ключ или нова доставка.

Празна партида и `1` стават `N/A`. За всеки положително приет ред се създава отделен batch с PocketBase ID и source_item. Продукт+N/A не е идентичност. Две дати означават две партиди. Нулево получено количество не създава продукт/партида/движение. Положително количество изисква валидна дата и физическа проверка.

OCR снимките са отделно staged **преди** атомарното финализиране; DB финализацията не извършва файлови или мрежови операции. `delivery_items.original_ocr`, page_id/document_row и `delivery_pages.raw_ocr` запазват произхода. SHA на снимката е клиентски маркер за повторение, не сървърна криптографска атестация на съдържанието.

Съществуващ активен продукт се избира по ID или еднозначно нормализирано име. При двусмислие има конфликт, без произволно съпоставяне. Нов продукт няма измислен EAN от доставчически артикул. Каталогът се чете в транзакцията; при много голям каталог е нужна отделна оптимизация.

## Flutter

Клиентът проверява capabilities при отваряне на редактора. След последното потвърждение записва устойчив staging payload, синхронизира проверените редове, качва липсващите снимки и записва устойчив finalization payload, преди да го изпрати. Само валиден сървърен finalized отговор променя локалния статус и връща към Dashboard. При неизвестен резултат черновата и точният payload остават за повторение. Pending payload е заключен за редактиране/изтриване, за да не се загуби възможността за безопасно повторение.

Старите записи със status празно не се пренаписват и не се финализират автоматично. V2 endpoint-ите обслужват новите staged V2 чернови. Предложените по-рано продажби, корекции и физически проверки не са нови endpoints в този пакет; активацията заключва стария директен inventory CRUD и трябва да се съгласува с тези работни процеси преди внедряване.
