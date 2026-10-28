> Последваща корекция: [предложени Получени количества и supplier-code работен процес](delivery-identity-workflow.md). Описанието за празно Получено количество по-долу е предходният baseline. Proxy deployment договорът остава непроменен.

# PaddleOCR — реализация и план за внедряване, 25.10.2026

## Архитектура и договор

Един активен OCR път: Flutter → `POST /api/store/ocr/recognize` в PocketBase 0.40.4 → съществуващия `http://127.0.0.1:8765/ocr` → Flutter. Не е създаван друг PaddleOCR сървър. `ocr_api.py`, подаден от собственика, е запазен само като fixture за преглед; не се инсталира и не се променя. Временните директории и subprocess timeout 180 s остават отговорност на съществуващата Flask услуга. Не се отваря порт 8765 и не се променя `store-ocr.service`.

Flutter изпраща JSON `image_base64` със съществуващия employee token към PocketBase. Proxy преобразува декодираните bytes в multipart поле `image`. Не препраща токена към неавтентикирания loopback OCR. Проверява employee auth и актуална роля от базата: employee, manager или admin. Отказва други роли. Няма нови тайни във Flutter, schema migrations или промени на API Rules.

Сървърът се активира само с `STORE_OCR_PROVIDER=paddle-v5` и точно `STORE_OCR_URL=http://127.0.0.1:8765/ocr`. Произволни URL от клиент не се приемат. JPEG/PNG magic bytes, строг base64 и лимит **9 MiB за изображението** оставят място за multipart overhead под съществуващите 10 MiB на Flask. HTTP JSON body limit е 12 MiB + 4096 bytes. Пълното декодиране остава отговорност на Flask/OpenCV, което връща 400 за невалидно изображение.

Go Store.SetFunc mutex осигурява един активен proxy request между отделни JSVM инстанции; следващият получава 429. Съществуващият Flask lock пази една реална OCR задача, включително ако клиентът прекъсне. Proxy timeout 195 s, Flutter timeout 205 s; Flask OCR subprocess е 180 s. При мрежов отказ или proxy timeout клиентът получава неуспех, без автоматичен retry или втори engine. Upstream 400/413/429/504 се запазват, 500 се превежда към 503. Отговор с неочакван engine/status/products се отказва с 502. След прочит се отказва JSON над 1 MiB; `$http.send` не stream-ва/ограничава предварително response body, затова loopback service е доверена граница. Токени и снимки не се логват от proxy кода.

Реалният `http-test-v2.json` има status/engine/processing_seconds/products/raw_text. Адаптерът използва structured products директно, без ново геометрично разпознаване. Не предполага 37 позиции; приема и празен резултат, но той не разрешава финализиране. Максимумът е 500 позиции, съобразен със съществуващия V2.

Каталожното съпоставяне и редакторът са запазени: стабилен record ID, одобрен supplier+code, audit/revision/role/конфликт проверки. Разпознатото име се заменя само в работната чернова при надеждно съпоставяне или човешки избор. Каталожен продукт не се преименува от OCR. original пази пълния JSON на реда, raw_fields и raw_expiry_batch; page.text пази целия отговор и се stage-ва с оригиналната снимка през V2. Няма измислени coordinates/confidence, понеже реалният JSON не ги предоставя.

`requested_quantity` попълва само „Заявено“. **„Прието“ остава празно**, а difference остава само оригинална стойност от документа в разширения преглед. Невалидна/липсваща дата остава празна; null не се възстановява по предположение от raw текста. ISO дата се преобразува в ДД.ММ.ГГГГ само след календарна проверка. Отделните expiry_date/batch_number от услугата разделят и слети прочити като `14.11.2026L141126T01`; първоначалният текст остава. Празна/null/`1` партида е N/A в работния модел и V2 записа; null остава в original JSON. Положителното получено количество изисква физически проверен продукт и валиден потвърден срок. OCR не създава inventory записи.

## Одит и отстранени компоненти

- Android MainActivity вече е стандартна FlutterActivity. Премахнати са MethodChannel OCR, TessBaseAPI, background executor и native preprocessing.
- Премахната е Gradle зависимостта tesseract4android, APK assets bul/eng traineddata и техният OCR license файл. Други Android/Flutter зависимости, снимане, ръчен преглед, навигация и barcode полета са запазени.
- Премахнати са LocalOcrEngine, FallbackOcrEngine и менюто за избор Android/OnePlus/PSM/rotation. Единственото стандартно разпознаване е ServerOcrEngine; ръчното въвеждане остава след отказ.
- Старите geometry parsers и TSV decoder са преместени от lib към `test/support` само за сравнителните Tesseract fixtures. Не се зареждат от приложението.
- Отстранени са старите Python Tesseract sidecar sources, unit, benchmark, runtime probe и test_service от `backend/ocr_service`. На OnePlus системният Tesseract не е пипан.
- Старият package_catalog_v3.py отказва да създава Tesseract пакет и насочва към новия OCR-only packager. Старите deployment документи са маркирани като исторически, за да не заменят работещия Paddle unit.
- След изричното одобрение на собственика са изтрити и двете стари локални папки: `tool/ocr_benchmark` с Tesseract npm зависимости/модели и `backend/ocr_service` с остатъчния Python cache. Предходният отказ на автоматичния преглед е разрешен с това конкретно одобрение. Реалните сравнителни файлове в `test/fixtures/oneplus6` са запазени. Няма активен стар development OCR engine.


## Проверки

`test/paddle_ocr_test.dart` проверява реалните 37 позиции/23 дати/23 партиди, merged evidence, липсващи полета, каталог, физическо потвърждение и editor widget. `test/paddle_http_test.dart` изпраща реален localhost HTTP през Flutter SDK: auth, пълен JSON, HTTP грешки, timeout и oversized. HTTP тестовете са в отделен файл от widget тестовете, за да не използват Flutter HTTP 400 override.

`backend/tool/test_backend.py --catalog --flutter` тества PB **0.40.4**, локална копирана схема и синтетични данни. `test_ocr_proxy.py` е само contract mock за съществуващия API, не OCR реализация: проверява multipart bytes, липса на изтекъл token към upstream, anonymous/invalid auth, размер/формат, 429/504/500/400, malformed JSON, едновременни клиенти и недостъпна услуга. Преминават старите 13 V2 и 9 catalog сценария и 2 SDK сценария. Не се прави заявка към production. Native Paddle скорост/точност не са измервани повторно тук; 29.4 s и 37/37 са предоставени резултати върху един тип документ.

### Окончателни резултати

| Проверка | Резултат |
| --- | --- |
| flutter analyze --no-pub | чист |
| flutter test --no-pub | 88 успешни; 2 live SDK сценария изпълнени отделно |
| Реален PB 0.40.4 V2 | 13 успешни |
| Реален PB 0.40.4 catalog | 9 успешни |
| Реални Flutter SDK сценарии | 2 успешни |
| Реален JSVM → multipart contract mock | 6 групи успешни |
| Debug APK | компилиран; ZIP проверката не открива Tesseract/Leptonica/traineddata entries |
| Оригинални V2 JS файлове | 6/6 byte-identical спрямо предходния прегледан release |

Компактният локален отчет е `build/backend-v3/paddle-validation.json`. Измерването на реалния OnePlus през новия proxy предстои след одобрено внедряване.

### Файлове в текущата промяна

- `lib/services/paddle_document_adapter.dart`, `ocr_pipeline.dart`, `ocr_service.dart` — структурираният адаптер, единственият OCR transport и запазената проверка за повторна снимка.
- `lib/screens/delivery_editor_screen.dart`, `delivery_item_screen.dart` — Paddle резултати, raw evidence, физическо количество и manual recovery.
- `android/app/build.gradle.kts`, `android/app/src/main/kotlin/com/expiry_tracker/expiry_tracker/MainActivity.kt` — премахнат native OCR; изтрити tessdata assets.
- `backend/catalog_v3/pb_hooks/ocr_v3.pb.js`, `lib/paddle_proxy.js` — новият защитен OCR proxy, без inventory writes.
- `test/paddle_ocr_test.dart`, `paddle_http_test.dart`, `fixtures/paddle/*` — реален JSON/API договор, widget/HTTP проверки; реалният Python файл не се изпълнява.
- `test/support/*`, актуализираните исторически parser тестове — сравнителни данни извън runtime.
- `backend/tool/test_ocr_proxy.py`, `test_backend.py`, `package_paddle_proxy.py` — изолирани проверки и OCR-only пакет; старият package_catalog_v3 отказва Tesseract deploy.
- `integration_test/ocr_device_test.dart` — native OCR сценарият е премахнат; UI сценариите използват изрично injected structured fixture и не правят production OCR заявки.
- Този документ, отбелязаните исторически deployment документи и catalog README.


## Само след изрично одобрение: внедряване

Следващите команди са план за оператора; **не са изпълнени**. PocketBase може да изисква кратък престой за reload на hooks. Не изпълнявайте старите V3/Tesseract migrations/units. Новият пакет съдържа само два OCR JS файла, този документ и SHA256 manifest.

1. Прегледайте SHA256 на `store-paddle-proxy.tar.gz`, копирайте архива ръчно на OnePlus в `/home/user/`, извлечете в нова staging папка и проверете manifest. Не извличайте направо върху работещата папка.

```sh
mkdir /home/user/store-paddle-proxy-release
tar -xzf /home/user/store-paddle-proxy.tar.gz -C /home/user/store-paddle-proxy-release
cd /home/user/store-paddle-proxy-release
sha256sum -c SHA256SUMS
curl --fail --max-time 5 http://127.0.0.1:8765/health
sudo systemctl is-active store-ocr.service
```

2. Одобрете maintenance прозорец, спрете само PocketBase и направете последователно offline копие на целия му каталог и unit конфигурацията. OCR услугата остава работеща. Проверете свободното пространство предварително (`df -h /home/user`).

```sh
backup_dir="/home/user/store-backups/paddle-$(date -u +%Y%m%dT%H%M%SZ)"
sudo mkdir -p "$backup_dir"
sudo systemctl stop pocketbase.service
sudo cp -a /home/user/pocketbase "$backup_dir/pocketbase"
sudo cp -a /etc/systemd/system/pocketbase.service "$backup_dir/pocketbase.service"
if [ -d /etc/systemd/system/pocketbase.service.d ]; then
  sudo cp -a /etc/systemd/system/pocketbase.service.d "$backup_dir/pocketbase.service.d"
fi
sudo test -s "$backup_dir/pocketbase/pb_data/data.db"
sudo sha256sum /home/user/pocketbase/pb_data/data.db "$backup_dir/pocketbase/pb_data/data.db"
```

Ако копирането/проверката откаже, не инсталирайте нищо: стартирайте същата PocketBase услуга и разследвайте отказа. Backup-ът съдържа реална база и трябва да остане с ограничен достъп (`sudo chmod 700 "$backup_dir"`). Не споделяйте съдържанието.

3. При успешен backup инсталирайте **само** двата JS файла. `ocr_v3.pb.js` заменя предишния OCR route; ако има друг hook със същия маршрут, преместете конкретния стар OCR route извън pb_hooks след преглед, без да изключвате V2 finalization hooks. Запазете негово копие в backup. Не трябва да има два route handlers за един път.

```sh
sudo mkdir -p /home/user/pocketbase/pb_hooks/lib
sudo cp /home/user/store-paddle-proxy-release/pb_hooks/ocr_v3.pb.js /home/user/pocketbase/pb_hooks/ocr_v3.pb.js
sudo cp /home/user/store-paddle-proxy-release/pb_hooks/lib/paddle_proxy.js /home/user/pocketbase/pb_hooks/lib/paddle_proxy.js
sudo chown user /home/user/pocketbase/pb_hooks/ocr_v3.pb.js /home/user/pocketbase/pb_hooks/lib/paddle_proxy.js
sudo chmod 644 /home/user/pocketbase/pb_hooks/ocr_v3.pb.js /home/user/pocketbase/pb_hooks/lib/paddle_proxy.js
sudo mkdir -p /etc/systemd/system/pocketbase.service.d
sudo tee /etc/systemd/system/pocketbase.service.d/95-store-paddle.conf >/dev/null <<'EOF'
[Service]
Environment=STORE_OCR_PROVIDER=paddle-v5
Environment=STORE_OCR_URL=http://127.0.0.1:8765/ocr
EOF
sudo systemctl daemon-reload
sudo systemctl start pocketbase.service
sudo systemctl is-active pocketbase.service
```

Executable `/home/user/pocketbase/pocketbase`, WorkingDirectory `/home/user/pocketbase`, user `user`, pb_data и порт 8090 остават същите. Не добавяйте --automigrate и не пускайте migrate up за тази промяна. Съществуващите V2/catalog env настройки се запазват. Проверете за по-късни drop-ins, които биха презаписали OCR env.

4. Инсталирайте новия APK чрез обичайния update върху същия application ID, без uninstall/clear data. Влезте като служител, снимайте тестов документ, сравнете raw JSON/полета и редактирайте всички нужни стойности. Прието трябва да е празно и финализиране блокирано до физическа проверка. Самото OCR не трябва да създава доставки/продукти/партиди. Проверете отказ с невалиден токен и две едновременни заявки. Реален запис тествайте само с изрично одобрена тестова доставка или staging копие. Отделно проверете съществуващите dashboard/catalog/V2 capabilities. 1536 px остава резервна конфигурация на съществуващия engine; настоящият multipart API не предлага параметър за нейното включване от Flutter и кодът не го измисля.

## Rollback само на кода/конфигурацията

При проблем не възстановявайте автоматично pb_data: след backup може вече да има нови реални записи. Спрете PocketBase след одобрение. Върнете `pb_hooks/ocr_v3.pb.js` и `pb_hooks/lib/paddle_proxy.js` от `$backup_dir/pocketbase`, ако съответният файл е съществувал. Ако файлът е бил нов, преместете го в `$backup_dir/rejected-hooks/` извън активната hooks папка. Върнете предишния `95-store-paddle.conf`, ако е имало такъв; иначе преместете новия извън systemd drop-in папката. Върнете и допълнителен стар OCR route, ако е преместен в стъпка 3. Не заменяйте други V2 hooks и не изтривайте реални данни.

```sh
sudo systemctl daemon-reload
sudo systemctl start pocketbase.service
sudo systemctl is-active pocketbase.service
```

При rollback новото приложение може да вижда OCR като недостъпен — използвайте ръчно въвеждане. Не връщайте автоматично Tesseract pipeline. Запазете доказателствата/черновите за анализ. За пълно възстановяване на базата е нужна отделна оценка на новите записи и изрично одобрение.

Официалният [PocketBase HTTP/multipart договор](https://pocketbase.io/docs/js-sending-http-requests/) е сравнен с локалните 0.40.4 types и изпълнен с реалния 0.40.4 binary. Успешният contract mock не замества финалния smoke test през работещия OnePlus след одобрено внедряване.
