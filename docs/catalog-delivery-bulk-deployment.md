# StoreFlow: общо потвърждение на OCR продукти — пакет за одобрение

## Реализирано и граници

`employee`, `manager` и `admin` могат да създават потвърдените нови OCR артикули **при общото приключване на доставка**, без управителско одобрение и без отделни продуктови диалози. Общото каталожно редактиране/преименуване остава с досегашните manager/admin права. Служителският маршрут не позволява произволно редактиране на чужди каталожни продукти.

Нов маршрут: `POST /api/store/catalog/deliveries/{id}/finalize`, с employee authentication. Тялото е точният V2 finalization request плюс `catalog_confirmed: true`. Capability: `delivery_catalog_finalize: true`, отделна от `can_manage`. Активира се само с `STORE_CATALOG_DELIVERY_FINALIZE_ENABLED=approved`, работещ Catalog V3, V2 и разпозната служителска роля.

Flutter запазва OCR имената/кодовете, автоматично предлага полученото количество, съпоставя само по доставчик + код и допуска новите позиции до физическа проверка при тази capability. „Маркирай всички“ запазва изричното физическо потвърждение и проверките за количества/годност. Непотвърдените количества не се финализират. Новите продукти се създават едва след „Потвърди и приключи“. При липсваща capability се запазва съвместимият досегашен fallback; няма симулиран успех или заобикаляне на employee правата.

Няма промяна в съществуващите V2 hooks или V2 миграции: всички шест файла са сравнени byte-for-byte с прегледания `store-v2-rbibvuwd.tar.gz`. Новият Catalog V3 endpoint:

1. Проверява ролята, каталожните Rules, собствеността/управителския достъп, статуса и ревизията.
2. Изисква изричното общо потвърждение и сравнява точно заявените редове със staged редовете.
3. В един `runInTransaction(txApp)` разрешава supplier + code. Не използва name/GTIN за автоматично свързване. Непотвърдена, неактивна или многозначна асоциация се отказва.
4. Създава липсващите продукти с **празен barcode**, потвърдена supplier-code асоциация и audit с реалния служител. Няма миграция на съществуващи продуктови баркодове.
5. Подава разрешените ID към **непроменената** `delivery_finalization.finalize` със store, обвързан със същия txApp. V2 проверява снимките, physical evidence, CAS, идемпотентността и създава отделна партида/движение за всеки положително приет ред.
6. Записва резултата в Catalog operation journal в същата транзакция. При грешка се връщат назад продукти, асоциации, audit, staged ID, партиди, движения и двата operation журнала.

Нулево получени позиции не създават каталог или наличност. N/A е допустима партида; положителното количество изисква валиден срок. Две партиди/годности остават два реда. Повторното финализиране със същата заявка връща същата разписка. Променен payload или друг delivery ID със същия ключ се отказва. Две различни потвърдени доставки могат да използват една идентичност, но имат отделни количества и движения. **Две независими чернови на една хартиена разписка не се разпознават като един документ автоматично.** Не създавайте втора чернова при изгубен отговор.

При конфликтен supplier-code или еднакво име на друг каталожен продукт няма отгатване/автоматично обединяване; транзакцията се отказва. За неизвестен резултат се повтаря точната запазена заявка, без нов ключ. Старите pending индивидуални каталожни заявки трябва да се изяснят чрез обновяване на каталога, преди групово приключване.

## Променени файлове

Flutter:
- `lib/models/delivery_draft.dart`: persisted eligibility за общото създаване и физически проверки без предварителен product ID.
- `lib/services/product_catalog_service.dart`: отделна действителна bulk capability за всички служители.
- `lib/services/delivery_row_status.dart`: нов продукт, който предстои да се създаде при общото потвърждение.
- `lib/screens/delivery_editor_screen.dart`: capability, групов преглед/потвърждение и трайно запазен маршрут на заявката.
- `lib/screens/delivery_item_screen.dart`: преглед и проверка без индивидуален запис при активния bulk поток.
- `lib/services/delivery_finalization_service.dart`: избор на новия защитен route по трайно запазения request.

Backend и проверки:
- `backend/catalog_v3/pb_hooks/catalog_v3.pb.js`
- `backend/catalog_v3/pb_hooks/lib/catalog_v3.js`
- `backend/tool/test_delivery_catalog.py`, `backend/tool/test_backend.py`
- `test/storeflow_workflow_test.dart`, `test/backend_v2_http_test.dart`
- `backend/tool/package_delivery_catalog.py`

Съществуващите Catalog V3 schema/activation миграции са включени за първо внедряване. Не е добавена нова миграция за bulk операцията.

## Проверки

В безопасен localhost PocketBase **0.40.4**, със synthetic schema/users/data:
- 14 V2 интеграционни групи;
- 10 досегашни Catalog групи (employee direct arbitrary product create остава забранен);
- 7 нови групи за atomic delivery/catalog: 37 нови артикула, трите роли, потвърждение, replay/променен payload/друг target, отделни доставки и партиди, реален rollback след движение, невалидни/конфликтни редове и едновременни заявки;
- 6 Paddle proxy групи;
- 3 реални Flutter SDK теста, включително новия route и повторение.

`flutter analyze --no-pub` е чист; `flutter test --no-pub`: 119 успешни, 3 live SDK проверки се изпълняват отделно чрез локалния harness. Widget тестът проверява 37 нови реда за employee с **нула индивидуални каталожни записи**, физическо маркиране и едно общо потвърждение. Debug APK се изгражда успешно.

Production не е използван за тестове и не е променян.

## Съдържание на пакета

`storeflow-catalog-bulk-v3.tar.gz` съдържа само двата Catalog hooks, съществуващата additive schema миграция, отделната activation миграция, тези инструкции, read-only preflight, тестов отчет, manifest/SHA256. Няма база, снимки, токени, пароли, fixture seed, тестови fault hooks, V2 hooks, Paddle proxy, OCR услуга или модели. `V2-RUNTIME-SHA256SUMS` фиксира очакваните четири V2 runtime зависимости. Различен production V2 hash означава **спиране за преглед**, не автоматично презаписване.

## План за безопасно внедряване — само след изрично одобрение

Тези команди са **инструкции, не са изпълнени**. Сървърът е systemd: `pocketbase.service`; executable `/home/user/pocketbase/pocketbase`; data `/home/user/pocketbase/pb_data`; service user `user`. PaddleOCR на `127.0.0.1:8765` и `store-ocr.service` не се променят и не се спират.

### A. Read-only preflight, без спиране

Копирайте архива до `/home/user`, проверете придружаващия SHA256 и го разопаковайте в нова директория `/home/user/storeflow-catalog-release`. Не го разопаковайте директно върху работещия PocketBase.

```sh
cd /home/user
sha256sum -c storeflow-catalog-bulk-v3.tar.gz.sha256
mkdir /home/user/storeflow-catalog-release
tar -xzf storeflow-catalog-bulk-v3.tar.gz -C /home/user/storeflow-catalog-release
cd /home/user/storeflow-catalog-release
sha256sum -c SHA256SUMS
sh preflight.sh /home/user/pocketbase
systemctl status pocketbase.service --no-pager
systemctl cat pocketbase.service
```

Проверете executable версия 0.40.4, V2 hashes, свободно място за поне две копия на работната папка, съществуващите service environment настройки и миграции. Ако Catalog hooks вече съществуват и са различни, спрете за сравнение. Preflight не записва и не спира услуги. Проверка за реален потребителски login/capabilities трябва да се прави с неговата сесия, без споделяне на токена.

### B. Одобрен прозорец, консистентен offline backup

Спрете новото приемане в приложението. Едва след одобрение изпълнете:

```sh
umask 077
backup="/home/user/storeflow-backups/pre-catalog-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"
sudo systemctl cat pocketbase.service > "$backup/service-effective.txt"
sudo cp -a /etc/systemd/system/pocketbase.service "$backup/pocketbase.service"
if [ -d /etc/systemd/system/pocketbase.service.d ]; then
  sudo cp -a /etc/systemd/system/pocketbase.service.d "$backup/service-dropins"
fi
sudo systemctl stop pocketbase.service
sudo systemctl is-active pocketbase.service
# Очаква се inactive; ако продължава да работи, не продължавайте.
sudo tar -C /home/user/pocketbase -czpf "$backup/pocketbase-full.tgz" .
sudo tar -tzf "$backup/pocketbase-full.tgz" >/dev/null
sudo sha256sum "$backup/pocketbase-full.tgz" | sudo tee "$backup/pocketbase-full.tgz.sha256"
printf '%s\n' "$backup"
```

Backup е извън working directory и включва целия pb_data (включително storage/WAL, ако съществуват), executable, hooks и миграции. Копирайте/проверете архива и на друго устройство. Не използвайте копиране само на `data.db` при работеща услуга. Не продължавайте при неуспешен backup/checksum.

### C. Първо тест върху отделно копие на реалната схема

Препоръчително е преди production activation да възстановите backup в **отделна** директория на изолиран тестов хост, никога в production pb_data. Използвайте различен localhost port, `--automigrate=false`, отделни hooks/migrations и безопасни тестови потребители/документи. Изпълнете schema, после activation само върху това копие. Не публикувайте копието и не използвайте реални доставки за тестови финализации. Кодът тук е проверен с synthetic fixture schema; проверката върху копие на реалната база е отделна стъпка на rollout.

### D. Инсталиране след успешен preflight/backup/clone review

Докато PocketBase е спрян, инсталирайте **само** Catalog файловете; не копирайте/заменяйте V2 или OCR hooks:

```sh
release=/home/user/storeflow-catalog-release
sudo install -o user -g root -m 0644 "$release/pb_hooks/catalog_v3.pb.js" /home/user/pocketbase/pb_hooks/catalog_v3.pb.js
sudo install -o user -g root -m 0644 "$release/pb_hooks/lib/catalog_v3.js" /home/user/pocketbase/pb_hooks/lib/catalog_v3.js
sudo -u user /home/user/pocketbase/pocketbase migrate up --dir=/home/user/pocketbase/pb_data --hooksDir=/home/user/pocketbase/pb_hooks --migrationsDir="$release/pb_migrations"
# Само след успех и преглед на additive schema:
sudo -u user env STORE_CATALOG_V3_ACTIVATE=I_HAVE_BACKUP_AND_TESTS /home/user/pocketbase/pocketbase migrate up --dir=/home/user/pocketbase/pb_data --hooksDir=/home/user/pocketbase/pb_hooks --migrationsDir="$release/activation_migrations"
```

Additive schema запазва съществуващите записи/Rules. Activation заключва директните `products` create/update/delete Rules и използва проверените endpoints; това е **предложена промяна за одобрение**, не вече изпълнено действие. Не отваряйте директен REST create за employee.

Създайте нов drop-in `/etc/systemd/system/pocketbase.service.d/storeflow-catalog.conf` с точно:

```ini
[Service]
Environment=STORE_CATALOG_V3_ENABLED=approved
Environment=STORE_CATALOG_DELIVERY_FINALIZE_ENABLED=approved
ExecStart=
ExecStart=/home/user/pocketbase/pocketbase serve --http=0.0.0.0:8090 --automigrate=false
```

Запазете съществуващите V2/Paddle environment настройки, User=user и WorkingDirectory=/home/user/pocketbase. Не заменяйте други drop-ins. Ако вече има файл със същото име, направете преглед вместо overwrite. Уверете се, че V2 остава включен (`STORE_FINALIZE_V2_ENABLED=approved`).

```sh
sudo systemctl daemon-reload
sudo systemctl start pocketbase.service
sudo systemctl status pocketbase.service --no-pager
sudo journalctl -u pocketbase.service -n 80 --no-pager
```

### E. Проверка след стартиране и APK

Преди разрешаване на реални доставки: проверете с employee/manager/admin сесии `GET /api/store/catalog/capabilities`: catalog=true, delivery_catalog_finalize=true; can_manage=false за employee и true за manager/admin. Проверете V2 capabilities и запазения Paddle route. Не използвайте production finalize като health check. Извършете сценария с тестова доставка първо на изолираното копие.

Обновете StoreFlow чрез `adb -s SERIAL install -r .../app-debug.apk`, без uninstall/clear data. Application ID и подписът остават досегашните. Проверете разпознаването на снимката, редакцията на количества/срокове, „Нов продукт“, липсата на индивидуални диалози и общото обобщение. На production финализирайте само действително получена и проверена доставка.

### F. Rollback

Преди реални нови записи: спрете PocketBase и запазете и неуспешното състояние за диагностика. Възстановете **целия** backup на working directory в отделна директория, проверете checksum и собственост user, след това с одобрен rollback превключете обратно към него и към запазените service/drop-ins. Премахнете само новия storeflow-catalog.conf след запазването му за диагностика. Не връщайте старите hooks върху мигриралата база и не отваряйте Rules на ръка.

Ако вече има реални нови финализации, не възстановявайте стар backup механично: това би загубило последващите записи. Спрете приемането и направете отделен план за запазване/възстановяване на новите данни. Никоя rollback команда не е изпълнена автоматично.

## APK от тази реализация

`C:\Users\cocev\AndroidStudioProjects\expiry_tracker\build\app\outputs\flutter-apk\app-debug.apk`

Генериран: **26.10.2026 01:11:46 +02:00**, Europe/Sofia. SHA256: `F9954C13CC0D14C93989349BA20C6FC8676C4F036C93B18260347925449CA82F`.

Android label StoreFlow, application ID `com.expiry_tracker.expiry_tracker`, досегашен debug подпис SHA256 `a82a9837aecece20b88c973c82a4014fdd3362d9aeab5ed453a135e2ae26c13a` — проверени чрез aapt/apksigner. Не е правена автоматична инсталация на Galaxy A50.

```powershell
& "C:\Users\cocev\AppData\Local\Android\sdk\platform-tools\adb.exe" devices -l
& "C:\Users\cocev\AppData\Local\Android\sdk\platform-tools\adb.exe" -s "SERIAL_ОТ_СПИСЪКА" install -r "C:\Users\cocev\AndroidStudioProjects\expiry_tracker\build\app\outputs\flutter-apk\app-debug.apk"
```
