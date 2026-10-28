> Historical Tesseract baseline — superseded on 25.10.2026 by [PaddleOCR integration](paddleocr-integration.md). Do not deploy the old sidecar, unit or packages.

# Каталог и AI/OCR V3 — отчет за реализацията

Последваща промяна след реалните OnePlus измервания: [PSM 3, ограничен повторен OCR и безопасно съпоставяне](ocr-psm3-validation.md). Числата по-долу описват предходния V3 baseline; актуалните проверки и отделният тестов пакет са в новия отчет.

Дата: 22.10.2026. Реални промени във Flutter и отделно подготвени server компоненти. **Production PocketBase и OnePlus не са променяни.**

## Фаза A — каталог, идентификатори и съпоставяне

Списъкът „Продукти“ се отваря към редактор/подробности за същия product.id. Има име, checksum-валиден EAN/GTIN, категория, активен статус, алиаси и доставчически кодове. Търсенето включва тези идентификатори. Не се изтриват продукти или свързани партиди. Преименуването променя само текущия каталог, не оригиналните OCR редове и снимки.

Manager/admin записват през новите защитени endpoints; останалите служители предлагат корекции. Виждат се pending предложения и управител може да ги зареди за преглед/одобрение. Историята показва actor, време и before/after. Role се проверява от базата на сървъра; допълнителен hook забранява self-escalation през стандартния employees REST API. Direct products write Rules се заключват в **отделна activation**, не при additive schema migration.

Приоритет: checksum-валиден GTIN → одобрен supplier+code → нормализирано име/алиас → приблизителен текст. Последното никога не избира автоматично. Дубликати на GTIN, противоречие barcode/code, двусмислени алиаси и неактивни идентификатори спират автоматичната връзка. Идентификаторът на доставчика остава текст с водещи нули и няма глобална уникалност без доставчик. Човешки избраният product ID има приоритет пред свободното OCR име.

След физическа проверка има „Запомни това съвпадение“. За manager/admin това добавя глобално одобрени алиаси/кодове с audit. За employee се записва **предложение**, което не се използва глобално до одобрение. Така примерът `КИС МЛ 3.6 400` започва да се съпоставя по алиас след одобряване, без разширени права за произволна редакция на каталога.

## Фаза B — Android OCR и OnePlus sidecar

Използван е съществуващият LocalOcrEngine. Android добавя percentile contrast normalization, EXIF/manual rotations, допълнителни ориентации при слаб OCR и deskew по откритите текстови редове. Обработката остава в единичния background executor. Оригиналната снимка не се презаписва. Езиците са bul+eng.

Съществуващият геометричен parser продължава да обслужва познатите документи. Добавен е parser по заглавия на колони за различни фактури/разписки, включително смесени български/английски заглавия, отделен barcode, количество и единица. Не се поправят произволно цифри, не се генерират срокове и не се извежда количество от „Разлика“. Непозната таблица води до ръчно въвеждане, а не до измислени позиции. При липса на валидна дата положително количество остава непотвърдено.

OnePlus sidecar е Python/Pillow/native Tesseract услуга, без LLM. Има shadow/background normalization, EXIF, bounded rotation search, deskew, TSV word geometry и elapsedMs. Една OCR задача, 2 OpenMP threads, deadlines и ограничения на image/body/pixels. Employee-auth loopback proxy е отделен hook. Временните снимки се почистват и не се логват текст/токени. Не са нужни облачен акаунт или AI API ключ.

Реалната OnePlus конфигурация е предоставена от собственика: aarch64, postmarketOS/Alpine, 5546 MB RAM/4102 available, Tesseract 5.5.2, bul+eng, NEON/OpenMP. Не е избран непроверен ARM/glibc LLM runtime. Новата Python/Pillow услуга още трябва да премине runtime probe и реален native документ на самия OnePlus.

## Фаза C — приемане на доставки

В менюто „Настройки за OCR“ има Android/OnePlus режим и завъртане 0/90/180/270. При недостъпен OnePlus работи Android fallback. Има прогрес, повторно разпознаване и време за обработка. „Въведи ръчно за тази страница“ позволява продължаване при OCR отказ със същата снимка и запазен наличен OCR текст.

Екранът за позиция показва barcode/unit, причината за предложеното съвпадение, ръчно избран продукт и първоначалните OCR стойности. Изборът търси в активните продукти и показва предложенията първи. Автоматично попълнено, несигурно и ръчно коригирано са разграничени. Всички приети количества и положителни срокове все така изискват физическо потвърждение. N/A остава незадължителна партида без допълнителна lot проверка.

## Фаза D — изпълнени проверки

| Проверка | Резултат |
| --- | --- |
| `flutter analyze --no-pub` | No issues found |
| `flutter test --no-pub` | **68 успешни**, 2 live SDK теста пропуснати само в този общ run |
| Реален PB 0.40.4 V2 | **13/13**: atomic finalization, replay, invalid input, real SQLite rollback, concurrent phones, photo staging, legacy history |
| Реален PB 0.40.4 каталог | **9/9**: create/edit/propose/approve, GTIN/code conflicts, stable IDs, audit, direct REST bypass, admin/employee roles, concurrent revisions, role escalation |
| Реални Dart/PocketBase SDK тестове през harness | **2/2**: V2 stage/photo/finalize и V3 catalog learning → V2 finalization |
| OCR sidecar unit/protocol/preprocessing | **6/6**: auth, busy slot, failure recovery, lighting/skew/EXIF, mixed TSV, CLI arguments/timeouts/temp cleanup |
| Реален JSVM proxy към loopback sidecar | **Успешен**: bearer forwarding, employee auth-refresh и invalid body; OCR engine е изрично тестов |
| Debug APK | Успешен build на основното приложение |
| Визуално | Каталогът е прегледан в двете теми; widgets при 320px/200% текст без overflow |

Копията на **всичките 6 оригинални V2 JS migrations/hooks** бяха сравнени byte-for-byte с предишния прегледан release и са идентични. Не са редактирани V2 schema миграции, handlers или pure finalization/store файлове. Harness-ът е разширен с опционален `--catalog`; старите 13 сценария остават.

### Реален Android тест с предоставените снимки

Samsung Galaxy A50, SM-A505FN, изолирано `.ocrtest` приложение:

| Снимка | Време | OCR думи | Структурирани редове | Календарно валидни срокове |
| --- | --- | --- | --- | --- |
| pq3yI77f1.jpg | 38.207 s | 399 | 37 | 22 |
| yXHe3CpH1.jpg | 17.885 s | 426 | 37 | 18 |

Нативният OCR сценарий за двете снимки мина. Това не е доказателство, че всяка разпозната дата/дума е вярна — полетата остават непроверени. Целият device UI suite **не е успешен**: при следващите UI сценарии екранът отново беше заключен (потвърден keyguard), а три проверки не намериха/не достигнаха контролите. Те не се броят за преминали и трябва да се повторят при постоянно отключен телефон. Общите Flutter widget/SDK тестове са успешни независимо от този хардуерен проблем.

Пълният OCR резултат е само локален артефакт `build/ocr_benchmark/device_report.json`; съдържа оригинален текст и не влиза в release пакета. Компактните отчети са под `build/backend-v3/`. Визуалните PNG са в `build/ui-preview/catalog-*.png` с изрично тестови fixtures, които не се зареждат от приложението.

## Променени и добавени файлове

| Файлове | Отговорност |
| --- | --- |
| `lib/screens/products_screen.dart` | Търсене в алиаси/кодове, отваряне на съществуващ продукт и роли за добавяне |
| `lib/screens/product_form_screen.dart` | Редакции/предложения, доставчически кодове, aliases, дубликати, history и retry |
| `lib/services/product_catalog_service.dart` | Typed catalog API client, capabilities, pending corrections, audit и обучение |
| `lib/services/gtin.dart` | GTIN-8/12/13/14 check digit и canonical identity |
| `lib/services/product_matcher.dart` | Приоритетни идентификатори, конфликти, алиаси и fuzzy suggestions |
| `lib/models/delivery_draft.dart` | Barcode, provenance/match reason, explicit selection; backward-compatible JSON |
| `lib/services/structured_document_parser.dart` | Консервативно структуриране по реални колони |
| `lib/services/ocr_service.dart` | Запазва unit/difference в оригиналния OCR; manual rotation параметър |
| `lib/services/ocr_pipeline.dart` | Опционален authenticated server OCR и Android fallback |
| `lib/screens/delivery_editor_screen.dart` | Избор на OCR режим, parser, ръчно продължаване, време и supplier context |
| `lib/screens/delivery_item_screen.dart` | Barcode/unit, предложения, запазен каталог ID, original OCR и remember-match |
| `android/app/src/main/kotlin/com/expiry_tracker/expiry_tracker/MainActivity.kt` | Native контраст, ориентация, deskew и измерване на време |
| `backend/catalog_v3/pb_migrations/1792742400_catalog_v3_schema.js` | Additive V3 schema |
| `backend/catalog_v3/activation_migrations/1792742401_catalog_v3_activate.js` | Отделно одобрявана catalog write activation |
| `backend/catalog_v3/pb_hooks/catalog_v3.pb.js`, `lib/catalog_v3.js` | Защитени каталог операции и role guard |
| `backend/catalog_v3/pb_hooks/ocr_v3.pb.js` | Отделен OCR proxy |
| `backend/ocr_service/pipeline.py`, `server.py` | Native Tesseract/Pillow и bounded HTTP sidecar |
| `backend/ocr_service/runtime_check.py`, `smoke.py` | Read-only compatibility probe и реален документ без inventory writes |
| `backend/ocr_service/store-ocr.service`, `requirements.txt` | Подготвена systemd конфигурация и зависимост |
| `backend/ocr_service/test_service.py` | Шест protocol/preprocessing теста с изрично fake CLI |
| `backend/tool/test_backend.py` | Изолиран V2 harness, допълнен с V3 опция |
| `backend/tool/test_catalog.py`, `test_ocr_proxy.py` | Реални PB 0.40.4 каталог/proxy сценарии |
| `backend/tool/package_catalog_v3.py` | Production-only V3 пакет и SHA256 manifest |
| `test/catalog_v3_test.dart`, `catalog_v3_http_test.dart` | Нови unit/widget и реален SDK тест |
| `test/ocr_parser_test.dart`, `ux_v3_test.dart`, `widget_test.dart` | Обновени очаквания за наблюдавана unit, explicit selection и injectable catalog client |
| `backend/catalog_v3/README.md`, `docs/catalog-ocr-v3-deployment.md`, този отчет | Протокол, ограничения и точни стъпки |

## Нови миграции

1. `1792742400_catalog_v3_schema.js`: products.aliases JSON, supplier_identifiers JSON, catalog_revision; нови product_catalog_audit, product_corrections и catalog_operations с employee+key уникалност. Старите product/batch/delivery/movement данни се запазват. Няма unique barcode backfill върху евентуално конфликтни legacy данни.
2. `1792742401_catalog_v3_activate.js`: заключва products create/update/delete. Прилага се отделно с изрично acknowledgement, след tests/backup. Няма schema промяна за lot_number.

## Ограничения и приемателни условия

- Parser-ът е детерминиран и работи с разпознати колони/геометрия. Няма LLM разбиране на произволни документи; за неясни/счупени таблици се ползва ръчна проверка. Deskew е ограничен, не е пълна корекция на перспектива или размазване.
- Глобално learning от обикновен служител чака manager/admin одобрение. Човешка проверка на доставка не дава произволни каталог права.
- V2 договорът за финализиране е запазен: нов продукт там се създава с име и празен barcode/category. Barcode/unit OCR доказателствата остават в original_ocr и черновата; не се добавят независими REST записи след finalize. Ако новият продукт трябва да има потвърден баркод в каталога още при приемането, manager го създава/редактира през каталога и той се избира в черновата. Това избягва скрита промяна на атомарния V2 flow.
- При неизвестен резултат catalog формата повтаря същата заявка, докато е отворена. Няма durable catalog edit outbox между рестартирания; след затваряне проверете каталога преди ново create. Delivery outbox/replay остава съществуващият устойчив V2 механизъм.
- Проверените backend бази са реконструирани inventory exports + synthetic employees; реалните auth Rules/custom hooks трябва да се прегледат върху backup rehearsal.
- Следва native OnePlus тест на истински документ и повторение на device UI suite при отключен A50. Новите server компоненти още не са инсталирани.

Точните backup, staging, migration, activation, OCR service, smoke и rollback команди са в [deployment плана](catalog-ocr-v3-deployment.md). Production промени се правят само след изрично одобрение.
