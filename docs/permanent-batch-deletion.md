# StoreFlow — окончателно изтриване на конкретна партида

Този пакет заменя поведението „status=closed“ само за действието „Премахни от списъка“. Не внедрявайте стария пакет workflow-simplification за тази задача. Продукционният OnePlus е проверен само за четене; нищо не е инсталирано, услугата не е спирана и реалната база не е променяна.

## Реална схема и поведение на PocketBase

Read-only SQLite metadata и hooks проверки на OnePlus, 13.11.2026, потвърдиха:

| Връзка/обект | Резултат |
|---|---|
| Всички входящи relation полета към batches | Само `stock_movements.batch` |
| stock_movements.batch | maxSelect=1, minSelect=0, required=false, cascadeDelete=false |
| delivery_items | Няма relation към batches; обратната връзка е batches.source_item → delivery_items |
| Продукт и доставка | batches.product/delivery са изходящи връзки; не се изтриват заедно с batch |
| API Rules | batches.deleteRule=null, stock_movements.updateRule=null — запазваме защитата |
| Custom delete hooks | Не са открити регистрирани onRecordDelete hooks в продукционния pb_hooks |
| Маршрут | POST /api/store/batches/{id}/handle вече е регистриран и остава същият |

[Изходният код на PocketBase 0.40.4](https://github.com/pocketbase/pocketbase/blob/v0.40.4/core/record_model.go#L1487) показва: нормалното `app.delete(record)` обработва входящите relation полета транзакционно. Незадължителната връзка се изчиства, задължителната може да блокира изтриването, а cascadeDelete може да изтрие зависимия запис. Поведението е проверено и с действителния executable 0.40.4 на локална синтетична база.

Следователно само изтриване без историческа снимка би запазило старото движение, но би загубило връзката му към продукта/датата при legacy записи без source item. Решението използва съществуващото `stock_movements.notes`, без нова схема.

## Атомарна операция и история

Backend използва `runInTransaction` и PocketBase Record API, без директен SQL:

1. Проверява employees автентикация и роля employee/manager/admin, batch ID и изричното намерение за изтриване.
2. Ако записът съществува, проверява `expected_revision` и снимката на `expiry_date`. Няма ограничение за оставащи дни, включително празен срок.
3. Сканира всички входящи relation полета в текущата схема. При свързан запис с cascadeDelete, required/minSelect или неподдържана зависимост отказва с 409, без запис. Не изключва проверки и не заобикаля релации със SQL. Нови зависимости изискват отделен преглед.
4. Добавя към оригиналните notes на съществуващите движения JSON снимка: batch ID, продукт/име/код, delivery/source item, количество, срок, lot, revision/status, автор/дати и наблюдавани количества. Запазва и автора/момента на изтриване. Не променя type, quantity, employee, operation, line_key или reason на движението и не създава ново движение.
5. Изпълнява `app.delete(batch)`. PocketBase изчиства само незадължителните `stock_movements.batch` връзки. Движенията остават със същите ID; променят се notes, batch и служебното updated време. Продуктът, други партиди, deliveries, delivery_items и inventory_operations не се променят.
6. Връща успех само след commit. При грешка се връщат и batch, и notes/връзките. Повторение след загубен отговор не добавя снимката втори път.

Историческите JSON receipts на финализирането запазват стария batch ID като исторически идентификатор. Повторно финализиране връща същия receipt и **не пресъздава изтритата партида**. Файлове, собственост на самия batch, подлежат на стандартното файлово почистване от PocketBase; снимката в notes пази имената, не копие на файловете. Документите в delivery_pages не се изтриват. Пълният backup включва файловете в pb_data.

## HTTP договор и идемпотентност

```http
POST /api/store/batches/{batchId}/handle
Authorization: <employees token>
Content-Type: application/json

{"action":"delete_batch","expected_revision":4,"expiry_date":"2026-12-13"}
```

```json
{"batch_id":"<same batchId>","status":"deleted","deleted":true}
```

Ако записът вече липсва, удостовереният служител получава същия резултат за потвърдено отсъствие. **След физическо изтриване няма revision за сравнение** и не твърдим кой/кога е изтрил липсващия запис. Валидна повторена заявка тогава не може да има revision conflict; не променя друг запис. Не преизползвайте изтрити batch ID за различни обекти. Няма нова tombstone колекция или скрит архивен batch.

При съществуващ запис revision/date конфликтът е 409. Несъвместимите зависимости са 409 `incompatible_batch_dependency`/`unsupported_batch_dependency`. Неочаквана грешка е 409 `batch_deletion_not_confirmed`; няма потвърден успех. Липсващ/невалиден служебен токен се спира от auth middleware.

`GET /api/store/capabilities` получава `batch_deletion: true`. Това е проверка за конкретното необратимо действие, не нова версия на финализирането. Новият клиент не изпраща delete заявка към стар close-only backend. Старите клиенти без `action: delete_batch` се отказват безопасно от новия backend и не изтриват нищо. Старите локални `kind=handled` заявки не се превръщат автоматично в delete.

## Flutter

- Текстът на бутона остава „Премахни от списъка“. Потвърждението вече казва „изтрита окончателно“ и че действието не може да се отмени от приложението.
- Новата локална операция е `kind=delete_batch`; служителят трябва изрично да потвърди, за да замени стара close-only заявка.
- При успех се изискват същият batch ID, status=deleted и deleted=true. Отговор closed или чужд ID е грешка.
- При загуба на връзка се пазят intent и revision/date snapshot, със статус retry_required, без безкраен автоматичен цикъл. Повторният опит е ръчен.
- Дори batch да е изчезнал след изгубен отговор, заявката остава достъпна през „Подробности за синхронизацията“ → „Повтори“/„Отмени локалната заявка“. Само липсата му в списъка не се приема за успешен POST.
- Списъкът се опреснява след успех, при връщане към приложението, ръчно и през 30 секунди на активния екран. Другото устройство вижда изтриването при следващото успешно четене; няма обещание за офлайн push синхронизация.
- Съществуващото скриване на исторически closed записи остава за обратна съвместимост. То не е доказателство за успешно delete действие.

## Файлове

- Backend runtime: `backend/pb_hooks/lib/handle_expiry.js`; `backend/pb_hooks/lib/handlers.js` — промяна само в capability декларацията, потвърдена с diff към продукционното копие. `expiry_handling.pb.js` и всички OCR/finalization hooks/логика остават непроменени.
- Flutter: `lib/services/batch_check_repository.dart`, `lib/services/pocketbase_service.dart`, `lib/widgets/expiry_dashboard.dart`.
- Тестове: `backend/tool/test_backend.py`, `backend/tool/test_batch_deletion.py`, `test/batch_deletion_http_test.dart`, `test/workflow_simplification_test.dart`, `test/ux_v3_widget_test.dart`, `integration_test/emulator_safety_test.dart`.
- Пакет: `backend/tool/package_batch_deletion.py`, `backend/batch_deletion/install-after-approval.sh`, настоящият документ.

## Проверки

```powershell
flutter analyze
flutter test --no-pub
& 'C:\Users\cocev\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' backend/tool/test_backend.py --catalog --without-product-fields
flutter build apk --debug --no-pub
```

Логове: `build/batch-delete-analyze.log`, `build/batch-delete-flutter.log`, `build/batch-delete-backend.log`, `build/batch-delete-apk.log`, `build/batch-delete-focused.log`.

Окончателен резултат: **155 Flutter теста успешни, 4 live теста пропуснати** без зададен изолиран URL; **36 backend PASS групи** с PocketBase 0.40.4 и exit 0; `flutter analyze` — No issues found; debug APK build — успешен. Пакетът е проверен по вътрешните SHA256SUMS; installer е проверен с `bash -n`, без изпълнение.

Backend проверява реално отсъствие от batches след изтриване, бъдеща/изтекла партида, съседна партида на същия продукт, свързани доставки и движения, неизменни количества/типове/автори, две удостоверени сесии, повторение/едновременни заявки, revision/date конфликти преди изтриването, липса на revision след него, legacy история и атомарен rollback след запазване на notes. Чрез PocketBase API създава само в изолираната база тестови required/cascade/непознати зависимости и доказва безопасен отказ. Пълният suite покрива и OCR/частични доставки/идемпотентно финализиране.

Flutter HTTP тестовете доказват реалния request/receipt договор, отказ от closed/чужд receipt и липса на POST към close-only backend. Widget тестовете покриват offline/401/409/timeout, повторен опит след изчезнал batch, изрично потвърждение и опресняване. APK се компилира със запазен application ID. ADB не откри достъпен емулатор/физически телефон; актуализираният Android integration сценарий не е изпълняван на устройство в тази задача. Продукцията е инспектирана само за четене.

## Отделен пакет и точен deployment план

Пакет: `build/backend-repair/releases/storeflow-permanent-batch-deletion.tar.gz` плюс `.sha256`. Съдържа **само два runtime JS файла**, SHA256SUMS, installer и този документ. Няма миграции, база, credentials, service/Caddy конфигурация или финализиращ модул. Проверката `bash -n` е само синтактична; installer не е изпълняван на продукцията.

Съществуващият POST `/api/store/batches/{id}/handle` остава в Caddy allowlist. Запазете също вече използвания GET `/api/store/capabilities`. Не са нужни нов порт, Funnel или публичен PocketBase достъп.

**Изпълнявайте следните команди само след одобрение на плана.** Служителите трябва да спрат записите за краткия maintenance прозорец; проверете мястото за пълен архив.

Windows, от корена на проекта:

```powershell
$releaseFile = 'build/backend-repair/releases/storeflow-permanent-batch-deletion.tar.gz'
Get-FileHash -Algorithm SHA256 $releaseFile
Get-Content "$releaseFile.sha256"
ssh user@192.168.100.46 'mkdir -p /home/user/releases/storeflow-batch-delete-20261113'
scp $releaseFile "$releaseFile.sha256" user@192.168.100.46:/home/user/releases/storeflow-batch-delete-20261113/
```

OnePlus:

```sh
cd /home/user/releases/storeflow-batch-delete-20261113
sha256sum -c storeflow-permanent-batch-deletion.tar.gz.sha256
tar -tzf storeflow-permanent-batch-deletion.tar.gz
tar -xzf storeflow-permanent-batch-deletion.tar.gz
sha256sum -c SHA256SUMS
df -h /home/user/pocketbase /home/user
du -sh /home/user/pocketbase/pb_data
cat install-after-approval.sh
# Само след одобрение:
sudo sh ./install-after-approval.sh
sudo systemctl status pocketbase.service --no-pager
sudo journalctl -u pocketbase.service -n 80 --no-pager
```

Installer проверява точните SHA-256 на трите действащи handle/handlers/route файла от read-only инспекцията. При различно копие спира преди услугата и изисква нов diff. След това спира `/etc/systemd/system/pocketbase.service`, архивира `/home/user/pocketbase/pb_data` и pb_hooks консистентно, проверява архива и записва негов SHA в `/home/user/storeflow-backups/<UTC timestamp>/`. Запазва старите два JS файла и service файла. Заменя само двата модула, стартира услугата и проверява неавтентикиран POST → 401. При инсталационна грешка връща старите модули и стартира услугата.

401 е smoke проверка на маршрута/auth, не тест за изтриване на реални данни. Преди production пакетът е проверен върху localhost копие на схемата. За допълнителен приемателен тест използвайте отделна изолирана база, а не реална магазинна партида. След backend пакета обновете клиентите със същия подпис/application ID чрез `adb -s DEVICE_SERIAL install -r build/app/outputs/flutter-apk/app-debug.apk`. Не деинсталирайте и не изчиствайте данните.

### Rollback на кода

```sh
backup=/home/user/storeflow-backups/REPLACE_WITH_PRINTED_TIMESTAMP
sudo test -f "$backup/handle_expiry.js"
sudo test -f "$backup/handlers.js"
sudo sha256sum -c "$backup/backup.sha256"
sudo systemctl stop pocketbase.service
sudo cp -p "$backup/handle_expiry.js" /home/user/pocketbase/pb_hooks/lib/handle_expiry.js
sudo cp -p "$backup/handlers.js" /home/user/pocketbase/pb_hooks/lib/handlers.js
sudo systemctl start pocketbase.service
sudo journalctl -u pocketbase.service -n 80 --no-pager
```

Код rollback връща бъдещото close-only поведение; **не възстановява физически изтрити партиди**. Новият клиент отказва delete, когато capability вече липсва. За връщане на клиентската версия използвайте запазения предишен APK със същия подпис.

Пълният архив пази състоянието преди deployment, но възстановяването му върху по-нов pb_data би загубило последващи реални доставки. Не се прави автоматичен data rollback. При нужда архивът първо се отваря в отделна изолирана среда, сравняват се новите записи и се подготвя отделно одобрен план за възстановяване. Notes снимката не е заместител на пълния backup.
