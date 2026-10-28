# PocketBase V2 — предложение за одобрение, НЕ е приложено

> Актуализация 22.10.2026: това е историческото предложение. Вече има [изпълним пакет](../backend/README.md), [проверки на реален 0.40.4](pocketbase-v2-validation.md) и [конкретен systemd план за одобрение](pocketbase-v2-deployment.md). Production остава непроменен. Описанията по-долу за липсваща реализация отразяват състоянието при написване на предложението.

## Проверена основа

Версия v0.40.4 и схемите на deliveries, batches и stock_movements са предоставени
от собственика. Health endpoint отговаря с 200; metadata endpoints без токен
отговарят с 401. Няма привилегирован достъп, промени по сървъра или изтеглени
production данни. Няма backend migrations/hooks в Flutter хранилището.

Съществуващите връзки са правилни: batches.product → products;
batches.delivery → deliveries; stock_movements.batch → batches.
`maxSelect: 0` при RelationField в v0.40.4 означава единична връзка,
не многозначна. Не е необходима конверсия на съществуващите relation данни.
[Източник за конкретната версия](https://github.com/pocketbase/pocketbase/blob/v0.40.4/core/field_relation.go).

`batches.quantity` остава първоначално приетото количество. Не се изваждат
продажби или брак от него, за да се показва „текуща наличност“.
Съществуващият тип movement `sold` се запазва за историята, но приложението
не създава такива движения и не предполага интеграция с касовата програма.

## Точен проект на измененията

Съществуващите полета и данни се запазват. Имената по-долу са предложен
договор между следващия Flutter етап и PocketBase. Всяко relation е single,
maxSelect=1, cascadeDelete=false. Всички нови количества са finite number,
min=0, onlyInt=false; server validation проверява присъствие на стойността.
**Не се използва required=true за броене**, за да е възможна валидна нула.
Стойности за бройки трябва да са цели според unit; за kg/l са допустими дроби.

### deliveries — добавяне

| Поле | Тип / ограничения |
|---|---|
| status | select: legacy, draft, finalized, cancelled; single |
| revision | number: integer, min=0 |
| client_id | text, max=64; постоянният идентификатор на локалната чернова |
| document_date | date; дата на документа, отделна от received_at |
| ocr_draft | JSON, maxSize=2 MiB; raw текст, word boxes, версия на engine, несигурни полета, корекции; без base64 изображения |
| finalized_by | relation → employees |
| finalized_at | date, задавана от сървъра |

`document_photo` става maxSelect=50, mimeTypes=image/jpeg,image/png,image/webp,
maxSize=15 MiB на файл, protected=true. Предварителна проверка на реалните
съществуващи файлове; не се изтриват или прекодират. Редът на страниците се
пази в ocr_draft чрез стабилен page_id и името на PocketBase файла.
За повече от 50 страници се показва явна граница; не се отрязват тихо.

Индекс: `CREATE UNIQUE INDEX idx_deliveries_client ON deliveries(received_by, client_id) WHERE client_id != ''`.

### delivery_items — нова Base collection

| Поле | Тип / ограничения |
|---|---|
| delivery | required relation → deliveries |
| client_id | required text, max=64 |
| page_id, document_row | text, max=64; split партидите могат да сочат един document_row |
| position | integer number, min=0 |
| supplier_code | text, max=128; никога автоматично EAN |
| name_snapshot | text, max=1000 |
| product | optional relation → products до физическата проверка |
| requested_quantity | number, min=0; документно, не получено |
| received_quantity | number, min=0 |
| received_confirmed | bool; разграничава въведена нула от липсващо количество |
| unit | text, max=32 |
| expiry_date | date; за реално приети количества е задължителна при финализиране |
| lot_number | text, max=128 |
| difference_raw | text, max=128; не се интерпретира автоматично |
| original_ocr | JSON, maxSize=32 KiB |
| review_status | select: unchecked, checked |
| checked_by | relation → employees, задавана от сървъра |
| checked_at | date, задавана от сървъра |
| created, updated | AutoDate |

Индекс: `CREATE UNIQUE INDEX idx_items_client ON delivery_items(delivery, client_id)`.
Един item описва една физическа партида. Две партиди на един продукт = два item-а.
received_quantity=0 не създава batch или received movement.

### batches — добавяне

| Поле | Тип / ограничения |
|---|---|
| source_item | optional relation → delivery_items; празно за legacy записи |
| status | select: needs_review, active, closed |
| revision | integer number, min=0 |
| has_observed_count | bool |
| observed_quantity | number, min=0; последно физически установено количество, не live наличност |
| observed_at | date |
| observed_by | relation → employees |
| closed_at | date |
| closed_by | relation → employees |

Индекс: `CREATE UNIQUE INDEX idx_batch_source ON batches(source_item) WHERE source_item != ''`.
Не е уникална комбинацията product+lot+expiry: една и съща партида може да
бъде получена в няколко отделни доставки и историята им трябва да се запази.

### batch_checks — нова Base collection

batch: required relation → batches; quantity: number min=0 (нула е валидна);
employee: required relation → employees; operation: required relation →
inventory_operations; notes: text max=2000; created: AutoDate от сървъра.
Индекс: `CREATE UNIQUE INDEX idx_check_operation ON batch_checks(operation)`.
Записите са append-only. quantity=0 приключва batch-а в същата транзакция.

### stock_movements — добавяне, без промяна на старите стойности

operation: optional relation → inventory_operations (legacy може да е празно);
line_key: text max=160; reason: text max=2000.
Индекс: `CREATE UNIQUE INDEX idx_movement_line ON stock_movements(line_key) WHERE line_key != ''`.
При receipt line_key=`<operation_id>:<delivery_item_id>:received`; при waste
line_key=`<operation_id>:waste`. quantity е положителна за нов received/waste.
employee и created се задават от сървъра, не от заявката на телефона.

### inventory_operations — нова Base collection

employee: required relation → employees; key: required text max=128;
kind: select draft_save, finalize, check, waste, correction;
target: text max=128; payload_hash: required text, 64 hex chars;
response: JSON maxSize=1 MiB; created: AutoDate.
Индекс: `CREATE UNIQUE INDEX idx_operation_key ON inventory_operations(employee, key)`.
Този журнал пази успешния резултат на всяка операция в същата транзакция.

## API Rules — предложена промяна, изисква одобрение

products и employees не се променят. За deliveries, delivery_items, batches,
batch_checks и stock_movements: List/View=`@request.auth.id != ""`, както
при съществуващите складови колекции; Create/Update/Delete=`null` (locked).
inventory_operations: List/View=`employee = @request.auth.id`;
Create/Update/Delete=`null`. Снимките са protected и се получават с file token.

Записването се прави само през проверени custom endpoints с
`$apis.requireAuth('employees')`. Администраторът на магазина е employee
с role=admin; superuser credentials не се добавят в приложението.
Това затваря директния CRUD обход на транзакциите и audit логиката.
Корекции на историята се разрешават само на manager/admin чрез отделен
endpoint, с причина, нов audit запис и revision проверка; история не се трие.

## Атомарни endpoints и договор за повторенията

Всички mutations приемат `operation_key` (генериран веднъж и запазен локално
преди първата заявка), `expected_revision` и бизнес payload. Сървърът
изчислява SHA-256 върху каноничен payload, kind и target.

В `$app.runInTransaction(txApp => { ... })` се използва **само txApp**:

1. Проверява се journal по employee+key. Същият hash връща стария резултат;
   различен hash връща 409, без нови записи.
2. Проверяват се employee, права, target.status и expected_revision от базата.
3. Изпълнява се CAS update `WHERE id=:id AND revision=:expected` и увеличаване
   на revision. Нула засегнати редове = 409. Конфликт/SQLITE_BUSY изисква
   презареждане/повторение със същия ключ; не се генерира нов ключ автоматично.
4. Валидират се всички бизнес инварианти; създават се записи и audit journal.
5. Commit на цялата операция или rollback на всичко. Отговорът се праща след commit.

Проверено в [types на v0.40.4](https://github.com/pocketbase/pocketbase/blob/v0.40.4/plugins/jsvm/internal/types/generated/types.d.ts):
runInTransaction е наличен. Няма мрежови извиквания/OCR вътре в транзакцията.
File uploads се staging-ват към draft преди finalize; finalize променя само DB.

| Endpoint | Поведение |
|---|---|
| POST /api/inventory/drafts/save | owner или manager/admin; idempotent upsert по received_by+client_id; revision проверка; checked_by/at не се приемат от клиента |
| POST /api/inventory/items/{id}/review | валидира product и физически въведени received_quantity, unit, expiry, lot; записва checked_by/at; увеличава delivery revision |
| POST /api/inventory/deliveries/{id}/finalize | изисква draft, всички items checked и received_confirmed; не допуска повторен source_item; по един batch и received movement за всяка положителна позиция; finalize + journal заедно |
| POST /api/inventory/batches/{id}/check | изисква активна/needs_review партида и quantity>=0; append batch_check; актуализира observed snapshot; нула → closed, положително → active |
| POST /api/inventory/batches/{id}/waste | quantity>0, reason непразна, batch не е closed; append waste; optional physically_counted_remaining>=0; нула приключва само след изрично физическо потвърждение |
| POST /api/inventory/corrections | manager/admin, причина, revision, append-only корекция; единственият разрешен път за корекция на closed batch |

При waste не се изважда от batches.quantity. Ако няма ново физическо преброяване,
последният observed snapshot се обозначава като предходен, не като текущо количество.
Не се предполага, че `доставено - брак = продадено/останало`.

## Точен план за migrations след одобрение

1. `*_v2_inventory_schema.js`: preflight за v0.40.4 и collection IDs от export-а;
   добавяне на горните optional полета и нови колекции с locked writes; добавяне
   на индексите; без rename/drop и без изтриване на данни. Проверка за колизия
   на имената — abort при несъответствие, не замяна на чужда collection.
2. `*_v2_inventory_backfill.js`: старите deliveries → status=legacy;
   старите batches → status=needs_review, has_observed_count=false; revision=0.
   Никога не попълва observed_quantity от quantity и не финализира стари доставки.
3. `*_v2_inventory_access.js`: прилагат се горните rules и protected файлове
   заедно с deployment на endpoint-ите. Flutter V3 се пуска след тях.
4. Преди production: backup/snapshot от собственика, тест с копие на реалната
   база и тест на двата телефона. Down migration не трие нова история:
   rollback е връщане на приложението и възстановяване на snapshot при нужда.

Миграциите още не са генерирани/изпълнени: предложението трябва първо да бъде
одобрено. Не се поставят автоматично изпълними файлове в pb_migrations.

## Приемателни тестове за следващите етапи

- Два телефона finalize-ват една доставка: един commit, другият 409 или същият
  запазен idempotent резултат. Няма duplicate source_item/received movements.
- Повторена waste заявка след загубен HTTP response: един movement.
- Един key с различен payload: 409. Не се променя journal.
- Едновременни check/waste с една revision: само една операция успява.
- quantity=0 при check → closed + audit; waste<=0/NaN/Infinity се отхвърля.
- Waste на closed batch се отхвърля, включително при директен CRUD опит.
- Позиция requested=12, physically received=10 → batch.quantity=10.
- Два lot-а на един product → два batch-а. Непроверен ред блокира finalize.
- Прекъсване по средата на finalize не оставя частични batch-ове/движения.
- employee/created/checked_by от payload не могат да подменят автора.

## Expiry Dashboard след одобрение

Часова зона на магазина Europe/Sofia; сравняват се календарни дати, не
изминали часове. expiry_date се записва в PocketBase като UTC midnight на
избраната календарна дата и се чете като date-only, без timezone преместване.
Closed се изключва. Класификацията е в този ред, по една категория на batch:
expired (<днес), today, 1–7 дни, 8–30 дни, needs_review (липсва/невалиден срок
или непроверена legacy партида извън горните диапазони). Останалите са normal.
Физически проверки могат да се правят по всяко време, без задължителен график.
Отваряне/връщане към Dashboard и pull-to-refresh зареждат PocketBase наново.

Тези endpoints, многотелефонните гаранции и Dashboard не са реализирани или
тествани в етап 1; това е конкретният договор за следващата работа.


## Актуализация UX V3, т. 10 — незадължителна партида

Тази актуализация заменя всяко по-старо изискване за задължителен партиден номер. Празно, whitespace или точно `1` се нормализират до `N/A`, без отделна проверка или предупреждение. При бъдещо финализиране сървърът записва `lot_number: "N/A"`; валиден срок и физическа проверка остават задължителни за положително количество. Съществуващото text поле е достатъчно, без миграция.

Идентичността е PocketBase record ID. Не се обединяват редове по продукт и партида; различните групи със срокове създават отделни записи, включително когато всички са N/A. Idempotency използва delivery/line ID, а проследимостта пази document/page/sourceRowId и оригиналния OCR. Подробният актуален договор е в ux-v3.md, раздел Optional lot number.
