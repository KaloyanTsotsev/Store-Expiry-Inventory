# PocketBase V2 — конкретен план за одобрение, backup и внедряване

**Статус: подготвен и локално проверен; не е изпълнен на сървъра.**
Нито една команда по-долу не е изпращана към `192.168.1.200`. Спиране на услугата, backup от production, промени в правилата и внедряване чакат одобрение на този план и прозорец за поддръжка.

## Потвърдена конфигурация от собственика

| Параметър | Стойност |
| --- | --- |
| Устройство / ОС | OnePlus 6 / postmarketOS, Alpine-based |
| Service manager | **systemd** |
| Unit | `pocketbase.service` |
| Unit файл | `/etc/systemd/system/pocketbase.service` |
| User / WorkingDirectory | `user` / `/home/user/pocketbase` |
| Binary | `/home/user/pocketbase/pocketbase` |
| ExecStart | `/home/user/pocketbase/pocketbase serve --http=0.0.0.0:8090` |
| Данни | `/home/user/pocketbase/pb_data` |
| Наблюдавани права | `drwxr-sr-x user root` |

PID 1455 е минало наблюдение. Командите проверяват текущия MainPID. Не се сменя binary, версия, порт, ExecStart, User или WorkingDirectory. Linux ARM64 build не е нужен за production, ако текущият binary действително е 0.40.4. Проверените локални интеграционни тестове използват Windows AMD64 build на същата версия; native ARM64 smoke/rehearsal остава преди cutover.

## 1. Read-only preflight преди прозореца

На телефона операторът изпълнява:

```sh
systemctl show pocketbase.service -p ActiveState -p MainPID -p User -p WorkingDirectory -p ExecStart -p FragmentPath -p DropInPaths
/home/user/pocketbase/pocketbase --version
uname -m
ls -ld /home/user/pocketbase/pb_data
df -h /home/user/pocketbase /var/backups
du -sh /home/user/pocketbase/pb_data
find /home/user/pocketbase/pb_hooks /home/user/pocketbase/pb_migrations -type f 2>/dev/null
```

Изисквания: точно 0.40.4, достатъчно място за backup + rehearsal + rollback snapshot, съвпадащи действителни пътища. Проверете локално съществуващите hooks, pending migrations, service drop-ins, евентуален settings encryption key и външно S3 storage. Секретните EnvironmentFile/ключове се запазват в отделно защитено копие; не се публикуват и не се извеждат в отчет. Външните S3 файлове изискват собствен backup — архивът pb_data не ги съдържа.

Изтеглете JSON exports на актуалните пет колекции за сравнение с очакваните IDs/полета; не променяйте API Rules през Dashboard. Тестовият fixture е реконструкция на дадените exports, не актуален snapshot на този сървър. При разлика първо адаптирайте/повторете тестовете върху копие. Спрете плана при неизвестни migrations, конфликти на имена или hooks, които променят записите.

## 2. Backup — само след одобрен прозорец

Командите са за **root shell** на телефона; операторът влиза през наличния sudo/doas механизъм. Те спират услугата и **не трябва да се изпълняват преди одобрение**. Затворете старите клиенти за периода на поддръжката.

```sh
set -eu
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP=/var/backups/pocketbase/pre-v2-$STAMP
umask 077
mkdir -p /var/backups/pocketbase
mkdir "$BACKUP"
chmod 700 "$BACKUP"
systemctl show pocketbase.service -p User -p WorkingDirectory -p ExecStart -p FragmentPath -p DropInPaths > "$BACKUP/service-properties.txt"
cp -p /etc/systemd/system/pocketbase.service "$BACKUP/pocketbase.service"
if [ -d /etc/systemd/system/pocketbase.service.d ]; then
  cp -a /etc/systemd/system/pocketbase.service.d "$BACKUP/pocketbase.service.d"
fi
systemctl stop pocketbase.service
test "$(systemctl show pocketbase.service -p MainPID --value)" = 0
test "$(systemctl show pocketbase.service -p ActiveState --value)" = inactive
test -d /home/user/pocketbase/pb_data
test -x /home/user/pocketbase/pocketbase
tar -czpf "$BACKUP/pocketbase-tree.tar.gz" -C /home/user pocketbase
tar -tzf "$BACKUP/pocketbase-tree.tar.gz" > "$BACKUP/archive-files.txt"
cd "$BACKUP"
sha256sum pocketbase-tree.tar.gz pocketbase.service > SHA256SUMS
sha256sum -c SHA256SUMS
printf '%s\n' "$BACKUP"
```

Архивът включва **цялата** директория: pb_data, възможните WAL/SHM, локалните снимки, binary, старите hooks и migrations. Не се копира само data.db при работещ PocketBase. Няма `chown -R user:user`: запазват се действителните права, група root и setgid. Архивът може да съдържа лични данни и auth secrets — достъп само за отговорния оператор. Направете второ проверено копие на архивите и конфигурацията извън телефона.

Ако това е отделен прозорец само за backup, след успешна проверка стартирайте **непроменения** стар код и потвърдете здравето:

```sh
systemctl start pocketbase.service
systemctl is-active pocketbase.service
curl --fail http://127.0.0.1:8090/api/health
```

Пътят `$BACKUP` трябва да се запише. Променливите от този shell не се предполагат налични в друга сесия. При неуспешен backup не продължавайте с миграции; възстановете старата услуга след диагностика. Ако е активен друг отделен PocketBase процес върху същите данни, спрете плана и го установете — inactive unit сам по себе си не доказва липса на друг процес.

## 3. Restore rehearsal и тестов план преди production cutover

Възстановете архива в **нов изолиран каталог**, не върху `/home/user/pocketbase`, и проверете SHA256 и `PRAGMA integrity_check` на копията на data.db/auxiliary.db с SQLite. Резултатът трябва да е `ok`. Например на отделна Linux машина с sqlite3:

```sh
mkdir -m 700 /srv/pb-v2-rehearsal
tar -xzpf /path/to/verified/pocketbase-tree.tar.gz -C /srv/pb-v2-rehearsal
sqlite3 /srv/pb-v2-rehearsal/pocketbase/pb_data/data.db 'PRAGMA integrity_check;'
if [ -f /srv/pb-v2-rehearsal/pocketbase/pb_data/auxiliary.db ]; then
  sqlite3 /srv/pb-v2-rehearsal/pocketbase/pb_data/auxiliary.db 'PRAGMA integrity_check;'
fi
```

Не изпълнявайте synthetic fixture importer върху това копие. Не публикувайте копието в LAN. Спрете външни email/S3/webhooks/scheduled hooks в rehearsal средата, преди да стартирате копирания сървър; проверете съществуващите hooks за такива странични действия. За същия OnePlus binary rehearsal е нужна ARM64 Linux среда. При друг host се използва неговият официален binary **0.40.4** с проверена checksum.

Прилагат се долните фази 4–5 **само върху rehearsal копието**, с изрично заменени абсолютни пътища и `serve --http=127.0.0.1:18090`. Проверете:

1. Преди/след additive migration: старите колони, стойности, created/updated, брой записи и API Rules са непроменени.
2. След activation: direct inventory Create/Update/Delete са locked; старите read rules остават; capabilities е 200 само след schema/rules gate и env активация.
3. Успешен нов synthetic документ: две положителни позиции с N/A и различни дати → два отделни batch ID и два received movement, една finalized доставка.
4. Повторение със същия ключ → същият резултат/ID; друг ключ за finalized доставка и два едновременни клиента → без дублиране.
5. Отрицателно/липсващо количество, невалидна/липсваща положителна годност, непроверен ред → отказ без inventory writes.
6. Тестовият **отделен synthetic harness** доказва rollback след реално създадени междинни записи. Не слагайте fault hook в rehearsal с реално копирани данни или в production.
7. Фото staging, повторно качване и изгубен отговор: повторение със същия payload; оригиналният OCR и връзката към документа остават.
8. Flutter срещу изолираната среда: последно потвърждение → staging → снимки → finalized → Dashboard; при грешка проверките/черновата остават.

Реално изпълнените локални сценарии и границите на проверката са описани в [validation отчета](pocketbase-v2-validation.md).

## 4. Подготовка на release и additive migration

Подгответе файловете локално от `backend/`; production пакетът съдържа само pb_hooks, pb_migrations, отделната activation_migrations и документацията, без test/tool/build. Сверете SHA256 manifest след прехвърляне. Качете за преглед в нов каталог **извън live hook/migration директориите**, например `/home/user/pb-v2-release`. Не разархивирайте директно върху работещия сървър.

Генериране на възпроизводим пакет от проекта: `python backend/tool/package_release.py`. Скриптът изисква успешен отчет от реалните backend/Flutter SDK тестове и извежда точния `.tar.gz` и SHA256. Съседният `.sha256` проверява архива; вътрешният `SHA256SUMS` проверява отделните файлове. След ръчно прехвърляне в staging директория, като `user`, с действителното име на архива:

```sh
cd /home/user
sha256sum -c store-v2-REPLACE_WITH_ACTUAL_NAME.tar.gz.sha256
test ! -e /home/user/pb-v2-release
mkdir -m 0700 /home/user/pb-v2-release
tar -xzf /home/user/store-v2-REPLACE_WITH_ACTUAL_NAME.tar.gz -C /home/user/pb-v2-release
cd /home/user/pb-v2-release
sha256sum -c SHA256SUMS
```

SHA256 защитава от повреда при прехвърляне; довереният източник е локално прегледаният пакет, не самостоятелно непроверен manifest. Това подготвя staging файлове и не активира hooks/migrations.

Изисквайте ново одобрение за cutover прозореца след rehearsal. Повторете backup от стъпка 2 непосредствено преди внедряване, защото старият сървър може да е приел нови записи междувременно. Този път оставете услугата спряна.

Следва root shell, при спрян PocketBase и проверено текущо backup копие. Няма презаписване на съществуващи файлове:

```sh
set -eu
test "$(systemctl show pocketbase.service -p MainPID --value)" = 0
test "$(systemctl show pocketbase.service -p ActiveState --value)" = inactive
test ! -e /home/user/pocketbase/pb_hooks/delivery_finalize.pb.js
test ! -e /home/user/pocketbase/pb_hooks/lib/handlers.js
test ! -e /home/user/pocketbase/pb_hooks/lib/delivery_finalization.js
test ! -e /home/user/pocketbase/pb_hooks/lib/pocketbase_store.js
test ! -e /home/user/pocketbase/pb_migrations/1792627200_inventory_v2_schema.js
test ! -e /home/user/pocketbase/pb_migrations/1792627201_inventory_v2_activate.js
install -d -o user /home/user/pocketbase/pb_hooks/lib /home/user/pocketbase/pb_migrations
install -o user -m 0644 /home/user/pb-v2-release/pb_hooks/delivery_finalize.pb.js /home/user/pocketbase/pb_hooks/delivery_finalize.pb.js
install -o user -m 0644 /home/user/pb-v2-release/pb_hooks/lib/handlers.js /home/user/pocketbase/pb_hooks/lib/handlers.js
install -o user -m 0644 /home/user/pb-v2-release/pb_hooks/lib/delivery_finalization.js /home/user/pocketbase/pb_hooks/lib/delivery_finalization.js
install -o user -m 0644 /home/user/pb-v2-release/pb_hooks/lib/pocketbase_store.js /home/user/pocketbase/pb_hooks/lib/pocketbase_store.js
install -o user -m 0644 /home/user/pb-v2-release/pb_migrations/1792627200_inventory_v2_schema.js /home/user/pocketbase/pb_migrations/1792627200_inventory_v2_schema.js
```

Прегледайте предварително **всички** pending migrations: `migrate up` изпълнява и други чакащи файлове, ако има такива. Не изтривайте историята на migrations. Следните команди се изпълняват в shell **като user** (напр. `su - user`, след което този блок):

```sh
cd /home/user/pocketbase
STORE_FINALIZE_V2_ENABLED=disabled ./pocketbase migrate up --dir=/home/user/pocketbase/pb_data --migrationsDir=/home/user/pocketbase/pb_migrations --hooksDir=/home/user/pocketbase/pb_hooks
```

Първата миграция добавя схема и индекси. Не прави backfill, не променя старите lot_number стойности и не променя API Rules на старите колекции. При несъответствие/грешка спрете; не стартирайте автоматично услугата и не продължавайте с activation. Сравнете read-only snapshot-а със старите записи и правила. Старите status полета остават празни; legacy записи не се обявяват за проверени.

## 5. Отделно одобрена activation и пускане

Тази фаза заключва Create/Update/Delete на **deliveries, batches и stock_movements**. Старите клиенти с директен inventory CRUD ще бъдат отказвани. Пакетът реализира финализиране на доставки; бъдещи sold/waste/adjustment/физически проверки през endpoint-и не са включени. Операторът трябва да приеме този обхват преди activation. Products API Rules не се променят.

В root shell, докато услугата е спряна:

```sh
test "$(systemctl show pocketbase.service -p MainPID --value)" = 0
test ! -e /home/user/pocketbase/pb_migrations/1792627201_inventory_v2_activate.js
install -o user -m 0644 /home/user/pb-v2-release/activation_migrations/1792627201_inventory_v2_activate.js /home/user/pocketbase/pb_migrations/1792627201_inventory_v2_activate.js
```

Като `user`:

```sh
cd /home/user/pocketbase
STORE_V2_ACTIVATE=I_HAVE_BACKUP_AND_TESTS ./pocketbase migrate up --dir=/home/user/pocketbase/pb_data --migrationsDir=/home/user/pocketbase/pb_migrations --hooksDir=/home/user/pocketbase/pb_hooks
```

Само след успешна проверка на резултата, в root shell добавете нов drop-in. Ако файлът вече съществува, спрете за преглед — не го презаписвайте:

```sh
test ! -e /etc/systemd/system/pocketbase.service.d/90-store-v2.conf
install -d -m 0755 /etc/systemd/system/pocketbase.service.d
( set -C; printf '[Service]\nEnvironment=STORE_FINALIZE_V2_ENABLED=approved\n' > /etc/systemd/system/pocketbase.service.d/90-store-v2.conf )
chmod 0644 /etc/systemd/system/pocketbase.service.d/90-store-v2.conf
systemctl daemon-reload
systemctl start pocketbase.service
systemctl is-active pocketbase.service
curl --fail http://127.0.0.1:8090/api/health
journalctl -u pocketbase.service -n 60 --no-pager
```

Не се добавят test env flags. `STORE_V2_ACTIVATE` е еднократно само за migration, не service Environment. Не публикувайте journal output, ако съдържа секрети от други hooks.

В новото Flutter приложение влезте като служител и отворете редактора отново: capabilities трябва да активира бутона. Прегледът и последното потвърждение остават задължителни. Проверка с реална доставка е нормална бизнес операция **само след изричното решение на собственика**; пакетът не създава или трие тестови записи в production. След финализиране трябва да се виждат отделни batch ID, точните количества/годности, връзките към delivery_items/pages и една операция. Не повтаряйте документа като нова доставка при timeout — използвайте запазената заявка.

## 6. Rollback без загуба на нова история

`migrate down` умишлено отказва: автоматично премахване на V2 история не е безопасно.

**Ако има реални V2 записи след пускането:** не възстановявайте стария backup автоматично. Спрете услугата в одобрен аварийния прозорец, архивирайте цялото текущо състояние и журналите, запазете подадените клиентски ключове и receipt-и. Нужен е forward fix или отделно одобрено съгласуване на всички следbackup записи. Прост restore би загубил доставки.

**Само ако няма никакви нови бизнес записи след backup-а**, възстановете проверения предcutover архив. В нов root shell задайте изрично действителния backup път (примерът се заменя), потвърдете checksum и не изтривайте неуспешната база:

```sh
set -eu
BACKUP=/var/backups/pocketbase/pre-v2-REPLACE_WITH_ACTUAL_TIMESTAMP
test -f "$BACKUP/pocketbase-tree.tar.gz"
cd "$BACKUP"
sha256sum -c SHA256SUMS
systemctl stop pocketbase.service
test "$(systemctl show pocketbase.service -p MainPID --value)" = 0
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
test ! -e "/home/user/pocketbase.failed-$STAMP"
mv /home/user/pocketbase "/home/user/pocketbase.failed-$STAMP"
tar -xzpf "$BACKUP/pocketbase-tree.tar.gz" -C /home/user
cp -p "$BACKUP/pocketbase.service" /etc/systemd/system/pocketbase.service
if [ -d /etc/systemd/system/pocketbase.service.d ]; then
  mv /etc/systemd/system/pocketbase.service.d "/etc/systemd/system/pocketbase.service.d.failed-$STAMP"
fi
if [ -d "$BACKUP/pocketbase.service.d" ]; then
  cp -a "$BACKUP/pocketbase.service.d" /etc/systemd/system/pocketbase.service.d
fi
systemctl daemon-reload
```

Проверете ownership/permissions, SQLite integrity и необходимия encryption key преди `systemctl start pocketbase.service`. После health и старите записи/бройки. Не премахвайте карантинното V2 дърво: то е необходимо за диагностика и евентуално възстановяване на потвърдени операции. Клиентска чернова с pending server ID след rollback не бива да се пресъздава като нов документ, преди съгласуване с journal/receipt.

## Основание за командите

PocketBase препоръчва пълно копие на pb_data при спрян процес за транзакционна безопасност: [Going to production](https://pocketbase.io/docs/going-to-production/). Миграциите са официалният JS механизъм: [JS migrations](https://pocketbase.io/docs/js-migrations/). Drop-in + daemon-reload се основават на [systemctl документацията](https://www.freedesktop.org/software/systemd/man/256/systemctl.html). Текущият сайт може да описва по-нова версия; изпълнимите migrations/hooks в пакета са проверени отделно на реален **0.40.4** runtime.
