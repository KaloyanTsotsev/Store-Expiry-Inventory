# StoreFlow — опростяване и обработване на партиди

## Потвърдени причини — 13.11.2026

Read-only SSH към OnePlus `192.168.100.46` потвърди:

- В `/home/user/pocketbase/pb_hooks` липсват `expiry_handling.pb.js` и `lib/handle_expiry.js`; маршрутът `/api/store/batches/{id}/handle` не е регистриран.
- Реалният `batches.status` допуска `needs_review`, `active`, `closed`. `revision`, `closed_at`, `closed_by` съществуват; `batches.updateRule` е `null` и остава защитен.
- Действащият `/finalize-by-code` блокира `received_quantity <= 0`, въпреки че вътрешната транзакция вече умее да пропуска нулеви редове.
- Пълното сравнение на действащия finalizer с подготвения след нормализиране на CRLF показва само една промяна: проверката вече изисква код за положителните редове, без да забранява нулевите. Стар SHA-256: `15ea3f4e06d13114aae0170af29576cb97d5eeb92708ba3699db912fed395862`.

„Неизпратена проверка…“ е следствие от липсващия endpoint, не само UI проблем. Допълнително клиентът чакаше capability, а клиентът и подготвеният стар hook разрешаваха само изтекли партиди. Премахваме тези ограничения. Не скриваме неуспеха и не симулираме успешен запис.

Не е спирана или променяна продукционната услуга, схема, правила, база или proxy. Не са правени записи върху реални продукти/доставки.

## Ново поведение

За всяка партида има „Премахни от списъка“, включително бъдеща или без дата. След потвърждение клиентът изпраща **POST `/api/store/batches/{id}/handle`**, employees authentication, тяло `{expected_revision: int, expiry_date: "YYYY-MM-DD"}`. Празна дата се допуска само когато и сървърният запис няма дата.

Транзакцията проверява служител с роля employee/manager/admin, защитената схема, датата-снимка и revision. Записва само `status=closed`, `revision+1`, `closed_at`, `closed_by`. Не променя продукт, количество, наблюдавани количества, други партиди или движения. Повторението пази първоначалния автор и час.

Клиентът чака валиден receipt за същия batch. Неуспешната операция остава на диска в employee outbox със `retry_required` и причината. Няма безкраен автоматичен цикъл. „Опитай синхронизация“ повтаря изрично; 401 изисква нов вход, 409 — опресняване, отмяна на старата заявка и потвърждение на актуалния запис. Локалната отмяна не отменя вече сървърно приключване. След изгубен отговор прочетен `closed` запис също приключва локалната заявка.

Активният екран опреснява през 30 секунди, при връщане към приложението и ръчно. Друг телефон премахва closed записите при това опресняване. Това не е push синхронизация без мрежа.

За неполучен ред изключете „Артикулът е получен“. Полученото става 0; OCR оригиналът и заявеното количество остават. Срок не се изисква за неполучен артикул. При повторно включване се изисква ново количество. Преди частично финализиране има преглед на получени/пропуснати позиции и потвърждение. Нулевите остават в delivery_items/evidence, но не създават продукт, batch или движение. Положителните използват съществуващата атомарна транзакция и идемпотентния ключ. Две независими чернови на един хартиен документ не са автоматично дедупликирани.

Премахнати са markdown екранът, политиката, acknowledgement/outbox/push услугите, Firebase зависимостите, Android notification channel/permission/icon и отделният backend модул. Други функции не използваха тези Firebase услуги. Списъците, цветовете, филтрите и нормалните предупреждения за срокове остават. Не изтриваме исторически PocketBase записи или локални SharedPreferences; няма обратна миграция.

## Файлове за тази задача

- Flutter: `lib/main.dart`, `lib/screens/home_screen.dart`, `lib/screens/delivery_editor_screen.dart`, `lib/models/delivery_draft.dart`, `lib/widgets/bulk_review_row.dart`, `lib/widgets/expiry_dashboard.dart`, `lib/services/batch_check_repository.dart`, `lib/services/pocketbase_service.dart`, `lib/services/delivery_finalization_service.dart`.
- Android/зависимости: `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/kotlin/com/expiry_tracker/expiry_tracker/MainActivity.kt`, `pubspec.yaml`, `pubspec.lock`, `.gitignore`, `storeflow-api-routes.txt`.
- Backend: `backend/pb_hooks/expiry_handling.pb.js` (включен в пакета), `backend/pb_hooks/lib/handle_expiry.js`, `backend/pb_hooks/lib/delivery_finalization.js`, `backend/tool/test_backend.py`, `backend/README.md`, `backend/tool/package_workflow_simplification.py`, `backend/workflow_simplification/install-after-approval.sh`.
- Тестове: `test/workflow_simplification_test.dart`, `test/finalization_test.dart`, `test/ux_v3_widget_test.dart`, `integration_test/emulator_app_test.dart` (премахнат отмененият markdown сценарий).
- Премахнати източници: `lib/models/markdown_task.dart`, `lib/screens/markdown_screen.dart`, `lib/services/markdown_service.dart`, `lib/services/markdown_push_service.dart`, четирите `test/markdown_*_test.dart`, източниците в `backend/markdown`, `backend/tool/test_markdown.py`, `backend/tool/package_markdown.py`, `android/app/src/main/res/drawable/ic_stat_markdown.xml`, `docs/category-markdown-reminders.md`.

Предишният доклад от емулатор остава исторически документ за предишната версия.

## Проверки и повторение

```powershell
flutter analyze
flutter test --no-pub
& 'C:\Users\cocev\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' backend/tool/test_backend.py --catalog --without-product-fields
flutter build apk --debug --no-pub
```

Логове: `build/workflow-simplify-analyze.log`, `build/workflow-simplify-flutter.log`, `build/workflow-simplify-backend.log`, `build/workflow-simplify-build.log`.

Backend тестовете използват истински PocketBase 0.40.4 само на localhost, ново синтетично копие на схемата и липсващите по волята на собственика products полета. Покриват +30 дни, изтекла партида, липсваща дата, две партиди на един продукт, две удостоверени сесии, едновременни и повторени заявки, неизменни количества/история, частична доставка, replay и rollback. Това не е тест на два физически телефона или запис в продукцията.

Flutter тестовете проверяват липсващ маршрут, timeout, 401, 409 без фалшив успех/безкраен retry; дисково възстановяване на заявката; бъдеща и изтекла партида; опресняване; неполучен ред; преглед и отказ на частична доставка. Пълният suite покрива и OCR, кодове, дати, чернови, количества и финализиране.

Окончателен резултат: `flutter analyze` — No issues found; `flutter test --no-pub` — **150 passed, 4 skipped** (тестове, изискващи изрично подаден live URL); backend suite — exit 0, всички V2/Catalog/Paddle групи минаха; `flutter build apk --debug --no-pub` — успешен build. Сканиране на активните Flutter/Android/backend източници, тестовете и списъка с маршрути не открива останали markdown/25%/50% функционални препратки. Не е тествано на физически телефон; продукцията е инспектирана само за четене.

Ръчно приемане СЛЕД внедряване: два служебни телефона на един тестов backend; приключете една тестова партида, опреснете другия телефон, проверете че съседната партида остава и няма ново движение. При частична тестова доставка сравнете receipt/delivery_items/batches/movements, после повторете същата заявка. Използвайте тестови данни, без редактиране на реални магазинни записи за целите на теста.

## Пакет и Caddy allowlist

`build/backend-repair/releases/storeflow-workflow-simplification.tar.gz` и едноименният `.sha256`. Съдържа само три runtime JS файла, installer, инструкции и SHA256SUMS. Няма миграции, база, credentials или Catalog/OCR/service промени.

За бъдещата Caddy allowlist е необходим само новият метод/маршрут:

```caddyfile
@batchHandle {
    method POST
    path_regexp batchHandle ^/api/store/batches/[a-z0-9]{15}/handle$
}
```

Включете matcher-а в съществуващия разрешен proxy handler към `127.0.0.1:8090`, със същите ограничения и Authorization header. Не добавяйте широк wildcard. Конкретният ред на Caddy handlers трябва да бъде прегледан в реалната конфигурация. Installer-ът не променя proxy-то. Не активирайте Funnel и не отваряйте 8090. Съществуващите stage/finalize-by-code маршрути остават необходими.

## Внедряване — САМО след одобрение

Командите по-долу НЕ са изпълнявани. Изберете кратък прозорец без служители, записващи доставки, и достатъчно място за пълен pb_data архив.

На Windows от корена на проекта:

```powershell
$releaseFile = 'build/backend-repair/releases/storeflow-workflow-simplification.tar.gz'
Get-FileHash -Algorithm SHA256 $releaseFile
Get-Content "$releaseFile.sha256"
ssh user@192.168.100.46 'mkdir -p /home/user/releases/storeflow-workflow-20261113'
scp $releaseFile "$releaseFile.sha256" user@192.168.100.46:/home/user/releases/storeflow-workflow-20261113/
```

На OnePlus:

```sh
cd /home/user/releases/storeflow-workflow-20261113
sha256sum -c storeflow-workflow-simplification.tar.gz.sha256
tar -tzf storeflow-workflow-simplification.tar.gz
tar -xzf storeflow-workflow-simplification.tar.gz
sha256sum -c SHA256SUMS
df -h /home/user/pocketbase /home/user
du -sh /home/user/pocketbase/pb_data
cat install-after-approval.sh
# Едва след одобрение на конкретния план:
sudo sh ./install-after-approval.sh
sudo systemctl status pocketbase.service --no-pager
sudo journalctl -u pocketbase.service -n 80 --no-pager
```

Installer-ът спира при различен SHA на finalizer или съществуващ handle hook — тогава първо е нужен нов diff. След проверките спира услугата, архивира консистентно `pb_data` и `pb_hooks` в `/home/user/storeflow-backups/<UTC timestamp>/`, проверява архива, пази стария finalizer и service файла, заменя трите JS файла, стартира услугата и проверява че новият неавтентикиран маршрут връща 401. При грешка по време на инсталацията връща старите hooks и стартира услугата. Няма migrations, API Rules или HTTP записи на доставки/партиди.

401 доказва регистрация/авторизация, не удостоверен запис. Следва ръчното приемане по-горе преди масово обновяване на клиентите. Caddy allowlist се променя отделно след преглед.

### Rollback

Използвайте точната директория от installer-а:

```sh
backup=/home/user/storeflow-backups/REPLACE_WITH_ACTUAL_TIMESTAMP
sudo test -f "$backup/delivery_finalization.js"
sudo sha256sum -c "$backup/backup.sha256"
sudo systemctl stop pocketbase.service
sudo cp -p "$backup/delivery_finalization.js" /home/user/pocketbase/pb_hooks/lib/delivery_finalization.js
sudo rm -f /home/user/pocketbase/pb_hooks/expiry_handling.pb.js /home/user/pocketbase/pb_hooks/lib/handle_expiry.js
sudo systemctl start pocketbase.service
sudo journalctl -u pocketbase.service -n 80 --no-pager
```

Няма schema промяна: rollback връща само hooks. Не възстановявайте стар pb_data върху по-нови реални доставки. Вече приключените batches пазят историята си. При нужда върнете предишния APK със същия application ID и подпис.

За Android след backend приемане: `adb devices`, после `adb -s DEVICE_SERIAL install -r build/app/outputs/flutter-apk/app-debug.apk`. Използвайте реалния serial; не деинсталирайте и не изчиствайте данните. Не е правена инсталация на физически телефон в тази задача.
