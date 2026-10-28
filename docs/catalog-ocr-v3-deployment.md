> Historical Tesseract baseline — superseded on 25.10.2026 by [PaddleOCR integration](paddleocr-integration.md). Do not deploy the old sidecar, unit or packages.

# Каталог и OCR V3 — безопасно внедряване

Статус: **подготвено за преглед, не е внедрено**. Няма изпълнявани команди към production PocketBase или OnePlus. Тестовите промени са само в изолирани локални бази. На Galaxy A50 е използвано отделно `.ocrtest` приложение.

## Потвърдена платформа и избран подход

Собственикът предостави реалните проверки на OnePlus 6: aarch64, postmarketOS v26.06/Alpine, RAM 5546 MB, available 4102 MB, swap 8319 MB, `/usr/bin/tesseract` 5.5.2, Leptonica 1.87.0, bul/eng, NEON/OpenMP. Използваме **native Tesseract**, без glibc LLM runtime, GPU или облачен AI. За структуриране има консервативен локален parser; приблизителното съпоставяне е само предложение. Няма платен AI API или API ключ. Снимките не се изпращат към трети страни.

Android остава основният режим с Tesseract4Android 4.9.0 и включените bul+eng модели. Сървърният OCR е опционален режим в менюто „Настройки за OCR“ и автоматично се връща към Android при отказ. При двоен отказ има ръчно въвеждане за същата снимка. Няма автоматично потвърждаване на количества/срокове.

Sidecar-ът слуша само `127.0.0.1:8091`, валидира employee токена чрез PocketBase auth-refresh и допуска **една** OCR задача. Най-много 4 HTTP handlers; останалите получават 429. `OMP_THREAD_LIMIT=2`, timeout до 100 секунди, до 15 MiB файл и 24 MP декодирано изображение, обработка до 3200 px. Systemd задава MemoryMax 1400M. Заявките са JSON/base64; няма shell изпълнение на подадени имена. Временните снимки са в частен temp каталог и се почистват. Услугата няма достъп до PocketBase DB.

Проверки, които още трябва да се направят **на OnePlus преди activation**: Python/Pillow, ограниченията на cgroup и реалният native CLI pipeline върху предоставен документ. Protocol тестовете на Windows използват изрично тестов OCR engine; те не доказват точността на OnePlus OCR.

## 1. Локално повторение на тестовете

В корена на проекта, Python 3 с Pillow 10.4–12.x, Flutter и точно PocketBase 0.40.4:

```powershell
flutter analyze --no-pub
flutter test --no-pub
python backend/ocr_service/test_service.py
python backend/tool/test_backend.py --catalog --flutter
flutter build apk --debug --no-pub
```

Binary по подразбиране: `build/backend-v2/runtime/bin/pocketbase.exe`; при друг път използвайте `--binary PATH`. Harness-ът слуша само на случаен localhost порт; OCR proxy тестът временно използва loopback 8091. Ако портът вече се използва, спрете теста и установете причината; не спирайте чужд процес. Synthetic superuser/employee credentials не са production credentials. Никога не копирайте fixture migrations или test fault hooks в production.

## 2. Read-only preflight на OnePlus

```sh
uname -m
cat /etc/os-release
free -m
/home/user/pocketbase/pocketbase --version
systemctl show pocketbase.service -p User -p WorkingDirectory -p ExecStart -p MainPID -p DropInPaths
/usr/bin/tesseract --version
/usr/bin/tesseract --list-langs
python3 --version
python3 -c 'import PIL; from PIL import ImageMath; print(PIL.__version__, hasattr(ImageMath, "lambda_eval"))'
```

Потвърдените PocketBase пътища остават: binary `/home/user/pocketbase/pocketbase`, WorkingDirectory `/home/user/pocketbase`, данни `/home/user/pocketbase/pb_data`, service `/etc/systemd/system/pocketbase.service`, user `user`, HTTP `0.0.0.0:8090`. Не сменяйте ExecStart/binary/данни. Изтеглете актуални JSON exports на products и employees за преглед: роли admin/manager, auth rules, права за четене и ограничения върху role. Истински пълен employees export не е предоставен; локалният fixture е синтетичен.

Проверете за конфликти с новите имена/полета: aliases, supplier_identifiers, catalog_revision; колекции product_catalog_audit, product_corrections, catalog_operations; файлове catalog_v3.pb.js, ocr_v3.pb.js и lib/catalog_v3.js. Миграцията отказва при колизия. Няма backfill на реалните продукти и няма автоматично обединяване/изтриване на дубликати.

## 3. Backup и rehearsal — преди промяна

Следвайте [пълния проверен backup/restore план](pocketbase-v2-deployment.md), раздели 2–3, със **свеж** архив на цялата `/home/user/pocketbase` и unit/drop-ins. Не копирайте само data.db при работещ процес. Преди всяко спиране/промяна се изисква одобрен прозорец; този документ не изпълнява командите.

Върху възстановено изолирано копие проверете SQLite integrity, актуалната схема и наличните hooks, след което приложете V3. Спрете външните side effects на съществуващите hooks в rehearsal. Слушайте само на loopback. **Не импортирайте synthetic fixture върху копие на реалната база.** Сравнете старите продукти/партиди/движения/OCR снимки и timestamps; additive миграцията не трябва да ги променя.

Проверете мениджърска редакция със същия product ID, employee предложение без промяна на продукта, одобрение и before/after audit; директните REST записи трябва да са locked. Повторете V2 staging/photo/finalize/status/replay/race сценарии. Изпробвайте barcode/code конфликти, custom aliases и липсващ срок. Production activation следва едва след успешен rehearsal.

## 4. Подготовка на файловете

`python backend/tool/package_catalog_v3.py` създава tar.gz и SHA256 manifest под `build/backend-v3/releases`. Съдържа само новите V3 migrations/hooks, OCR service и документацията. **Няма копия на старите V2 hooks/migrations**, база или реални документи.

Прехвърлете пакета ръчно в `/home/user`, сверете съседната `.sha256`, извлечете в нов каталог `/home/user/store-v3-release`, сверете вътрешния manifest. Например като `user`, с действителното име:

```sh
cd /home/user
sha256sum -c store-v3-REPLACE.tar.gz.sha256
test ! -e /home/user/store-v3-release
mkdir -m 0700 /home/user/store-v3-release
tar -xzf /home/user/store-v3-REPLACE.tar.gz -C /home/user/store-v3-release
cd /home/user/store-v3-release
sha256sum -c SHA256SUMS
```

## 5. Каталог — additive схема, после отделна activation

След одобрение на прозореца: затворете старите клиенти, спрете `pocketbase.service`, направете/проверете актуалния пълен backup от раздел 3. Оставете услугата спряна. Следва root shell, **само след това одобрение**:

```sh
set -eu
test "$(systemctl show pocketbase.service -p MainPID --value)" = 0
test "$(systemctl show pocketbase.service -p ActiveState --value)" = inactive
for name in catalog_v3.pb.js ocr_v3.pb.js; do
  test ! -e "/home/user/pocketbase/pb_hooks/$name"
done
test ! -e /home/user/pocketbase/pb_hooks/lib/catalog_v3.js
test ! -e /home/user/pocketbase/pb_migrations/1792742400_catalog_v3_schema.js
test ! -e /home/user/pocketbase/pb_migrations/1792742401_catalog_v3_activate.js
install -d -o user /home/user/pocketbase/pb_hooks/lib /home/user/pocketbase/pb_migrations
install -o user -m 0644 /home/user/store-v3-release/catalog_v3/pb_hooks/catalog_v3.pb.js /home/user/pocketbase/pb_hooks/catalog_v3.pb.js
install -o user -m 0644 /home/user/store-v3-release/catalog_v3/pb_hooks/ocr_v3.pb.js /home/user/pocketbase/pb_hooks/ocr_v3.pb.js
install -o user -m 0644 /home/user/store-v3-release/catalog_v3/pb_hooks/lib/catalog_v3.js /home/user/pocketbase/pb_hooks/lib/catalog_v3.js
install -o user -m 0644 /home/user/store-v3-release/catalog_v3/pb_migrations/1792742400_catalog_v3_schema.js /home/user/pocketbase/pb_migrations/1792742400_catalog_v3_schema.js
```

Прегледайте всички migration файлове и приложената история (read-only `sqlite3 /home/user/pocketbase/pb_data/data.db 'SELECT file,applied FROM _migrations ORDER BY file;'`). `migrate up` изпълнява и други чакащи migrations; при непознати файлове спрете плана.

Като **user**, не root:

```sh
cd /home/user/pocketbase
STORE_CATALOG_V3_ENABLED=disabled ./pocketbase migrate up --dir=/home/user/pocketbase/pb_data --migrationsDir=/home/user/pocketbase/pb_migrations --hooksDir=/home/user/pocketbase/pb_hooks
```

Първата миграция само добавя схема/индекс; старите Rules остават. Проверете данните срещу backup-а. След успешно тествани endpoints и одобрена промяна на правата, като root копирайте **отделната** activation:

```sh
install -o user -m 0644 /home/user/store-v3-release/catalog_v3/activation_migrations/1792742401_catalog_v3_activate.js /home/user/pocketbase/pb_migrations/1792742401_catalog_v3_activate.js
```

Като user:

```sh
cd /home/user/pocketbase
STORE_CATALOG_V3_ACTIVATE=I_HAVE_BACKUP_AND_TESTS ./pocketbase migrate up --dir=/home/user/pocketbase/pb_data --migrationsDir=/home/user/pocketbase/pb_migrations --hooksDir=/home/user/pocketbase/pb_hooks
```

Това заключва само директните products Create/Update/Delete. Редакциите минават през V3 endpoints. Вътрешното V2 финализиране продължава да създава липсващи продукти в своята транзакция. Existing V2 API Rules/файлове не се редактират. При включен V3 hook присвояване/промяна на employees.role през REST изисква admin/superuser, дори ако profile Rules са по-широки. Обичайните профилни редакции без промяна на role запазват старите си Rules.

Като root добавете **нов**, неприпокриващ се drop-in:

```sh
test ! -e /etc/systemd/system/pocketbase.service.d/91-store-catalog-v3.conf
install -d -m 0755 /etc/systemd/system/pocketbase.service.d
( set -C; printf '[Service]\nEnvironment=STORE_CATALOG_V3_ENABLED=approved\n' > /etc/systemd/system/pocketbase.service.d/91-store-catalog-v3.conf )
systemctl daemon-reload
systemctl start pocketbase.service
systemctl is-active pocketbase.service
curl --fail http://127.0.0.1:8090/api/health
```

Запазете съществуващия `STORE_FINALIZE_V2_ENABLED=approved` drop-in. Не добавяйте тестови env flags. Проверете manager/admin и employee през новия APK. Старият директен createProduct клиент ще бъде отказван; новият използва защитения catalog API. Без V3 наличен каталогът остава четим, а V2 delivery flow работи; редакции/учене изискват V3.

## 6. OCR sidecar — отделен компонент и отделна активация

Преди инсталация проверете Python/Pillow от раздел 2. Ако липсват, подгответе и одобрете `apk add python3 py3-pillow` от **вече конфигурираните** postmarketOS/Alpine repositories. Не сменяйте repositories/branch и не надграждайте работещия PocketBase/Tesseract произволно. Нужен е Pillow >=10.4,<13 с lambda_eval; requirements.txt описва диапазона. Не инсталирайте glibc wheels върху musl.

След одобрение, като root, без презаписване:

```sh
test ! -e /home/user/store-ocr
test ! -e /etc/systemd/system/store-ocr.service
install -d -o user -m 0750 /home/user/store-ocr
for name in server.py pipeline.py runtime_check.py smoke.py test_service.py requirements.txt; do
  install -o user -m 0644 "/home/user/store-v3-release/ocr_service/$name" "/home/user/store-ocr/$name"
done
install -m 0644 /home/user/store-v3-release/ocr_service/store-ocr.service /etc/systemd/system/store-ocr.service
```

Като user:

```sh
python3 /home/user/store-ocr/runtime_check.py --require-oneplus
python3 /home/user/store-ocr/test_service.py
```

Runtime probe е read-only, не инсталира пакети. HTTP тестовете използват отделни loopback портове и fake auth/engine, не production база. После, като root:

```sh
systemctl daemon-reload
systemctl start store-ocr.service
systemctl is-active store-ocr.service
systemctl show store-ocr.service -p MemoryMax -p TasksMax
journalctl -u store-ocr.service -n 40 --no-pager
```

Проверете, че слуша само на 127.0.0.1:8091 и cgroup лимитите действат. Не отваряйте нов LAN порт. Едва след успешен standalone старт и одобрение на кратко рестартиране на PocketBase, добавете нов drop-in:

```sh
test ! -e /etc/systemd/system/pocketbase.service.d/92-store-ocr.conf
( set -C; printf '[Service]\nEnvironment=STORE_OCR_URL=http://127.0.0.1:8091/recognize\n' > /etc/systemd/system/pocketbase.service.d/92-store-ocr.conf )
systemctl daemon-reload
systemctl restart pocketbase.service
systemctl is-active pocketbase.service
curl --fail http://127.0.0.1:8090/api/health
```

За автоматичен старт на OCR при boot използвайте `systemctl enable store-ocr.service` **само след успешен приемателен тест**. Работещият PocketBase service/ExecStart остават същите.

## 7. Реален документ на OnePlus — следващ приемателен тест

Като user посочете истинския път на предоставена снимка и **нов** output файл в защитен каталог. Командата изисква въведени интерактивно employee потребител/парола, не API ключ. Не ги слагайте в командния ред или отчет. Скриптът извиква само login + OCR; не създава delivery/product/batch.

```sh
umask 077
mkdir -p /home/user/ocr-results
chmod 700 /home/user/ocr-results
python3 /home/user/store-ocr/smoke.py --image /ABSOLUTE/PATH/document.jpg --output /home/user/ocr-results/first-real-document.json
```

Output е mode 0600 и съдържа оригиналния OCR текст/геометрия; не го публикувайте без редакция. Проверете визуално всяко име, баркод, код, количество и дата срещу снимката. Измерете elapsedMs, реална RAM и втори паралелен request → 429. Изпробвайте тъмна снимка/завъртане, timeout и недостъпен sidecar. В Android изберете OnePlus режима, потвърдете локалния fallback и ръчното продължаване. Реална доставка се финализира само след обичайното бизнес потвърждение; OCR smoke сам не записва наличности.

## 8. Rollback и защита на историята

При проблем само с OCR спрете `store-ocr.service` и в одобрен прозорец преместете **само** новия `92-store-ocr.conf` извън drop-in директорията, daemon-reload и рестартирайте PocketBase. Android OCR и ръчно въвеждане продължават. Не засягайте V2 drop-in.

За временно спиране на catalog writes задайте V3 env на disabled в собствения му drop-in и рестартирайте в одобрен прозорец; запазете директните products Rules locked. Не ги отваряйте като обходен път.

Миграциите умишлено отказват destructive down. Ако има реални следbackup редакции/доставки, не връщайте стария pb_data автоматично: запазете текущ пълен snapshot, operation journal и audit, после forward fix/одобрено съгласуване. Пълен restore е допустим само ако няма нови бизнес записи, по [V2 rollback плана](pocketbase-v2-deployment.md), с карантина вместо изтриване.

## Източници

Native aarch64 Tesseract/bul/eng пакети: [Alpine](https://pkgs.alpinelinux.org/package/v3.20/community/aarch64/tesseract-ocr). Техническите мерки за контраст/завъртане/наклон следват [официалните Tesseract насоки](https://github.com/tesseract-ocr/tessdoc/blob/main/ImproveQuality.md). Python image обработката използва [Pillow ImageMath](https://pillow.readthedocs.io/en/stable/reference/ImageMath.html). Съвместимостта на самия OnePlus Tesseract е потвърдена от собственика; новата sidecar услуга още не е стартирана там.
