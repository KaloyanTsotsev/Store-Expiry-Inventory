# StoreFlow — реализация, проверка и обновяване

Дата: 26.10.2026, Europe/Sofia. Production OnePlus/PocketBase/OCR не са променяни. Единственото обръщение към реалния PocketBase беше read-only GET към каталожната capability.

## Точна причина за „Необходим е избор на продукт“

Открити са няколко отделни причини, не само остарял надпис:

1. `delivery_editor_screen.dart` определяше текста само по productId/proposedNewProduct. Всеки друг случай — липсващ доставчик, грешен код, конфликт, неуспешно зареждане на каталог — попадаше в един и същ fallback „Необходим е избор на продукт“.
2. `_loadCatalog` четеше `products`, но не проверяваше Catalog V3 capability. Legacy списък с продукти не доказва наличен schema/endpoint за supplier-code асоциации и създаване. При липсващ каталог UI не различаваше липсваща операция от нужда да избираш продукт.
3. BulkReviewRow винаги предлагаше стария общ бутон „Продукт / още“, дори за директно разпознат OCR ред.
4. Paddle JSON не съдържа потвърден доставчик. Доставчикът е поле на документа; ако е празен, не може безопасно да се установи уникална supplier+article_code идентичност. Сега има едно ясно действие „Попълни доставчик за документа“, вместо 37 подвеждащи picker съобщения.
5. Открит е допълнителен реален каталожен дефект: `ProductsScreen.openProductForm(product)` отваряше `const ProductFormScreen()` и **изгубваше подадения product**. Изборът на съществуващ продукт водеше до празна create форма. Сега се подават същият record ID, списъкът, catalog service и проверената capability; нов widget тест покрива точно този маршрут.

Product ID не е премахнат като условие за положителен inventory запис — той е нужен за стабилната идентичност. Корекцията е в разделянето на OCR ред, каталожна идентичност и физическа проверка, вместо изискване за picker.

## Реалният Catalog V3

Проверено е `GET http://192.168.1.200:8090/api/store/catalog/capabilities`: **HTTP 404**, body `{"data":{},"message":"File not found.","status":404}`. Заявката е без employee token; не са искани/четени тайни. При наличния в проекта защитен маршрут неавтентикиран достъп нормално се отказва с 401, затова този 404 не е доказателство за работещ Catalog V3. Маршрутът не е достъпен на проверения адрес. Не е потвърдено can_manage право върху production чрез валидна сесия.

Приложението вече проверява capability **с действителния служителски token** при зареждане на каталога: protocol=3, catalog=true, can_manage=true/false. Отговорите 404/401/403/недостъпна мрежа имат отделно обяснение. Без налична операция не се показва работещ „Добави в каталога“ и save/create бутоните в каталожната форма са блокирани. Старият списък остава четим, OCR редовете и локалните корекции се пазят. Това не е фалшива симулация на каталожен запис.

За пълен автоматичен процес на **нови** продукти е нужно отделно одобрено внедряване на вече подготвения Catalog V3:

- additive migration `backend/catalog_v3/pb_migrations/1792742400_catalog_v3_schema.js`: products aliases/supplier_identifiers/catalog_revision и audit/corrections/operations collections;
- отделна activation migration `backend/catalog_v3/activation_migrations/1792742401_catalog_v3_activate.js`, която заключва директния catalog CRUD след backup и проверка;
- `backend/catalog_v3/pb_hooks/catalog_v3.pb.js` и `backend/catalog_v3/pb_hooks/lib/catalog_v3.js` — capabilities/products/corrections/confirm-match и role guard;
- изрично активиране на catalog environment и повторно тестване върху копие на реалната схема преди production.

Не копирайте стар Tesseract пакет или нов OCR route върху работещия Paddle proxy. Не изпълнявайте тези migrations без отделно одобрение; съществуващите API Rules не са променяни в тази задача. Backup paths, systemd service и точният безопасен процес са описани в предишните backend deployment документи; unit е pocketbase.service, executable `/home/user/pocketbase/pocketbase`, data `/home/user/pocketbase/pb_data`.

Employee може да работи с вече еднозначно разпознат продукт. За нов продукт текущият каталог изисква manager/admin. При наличен V3 управителят го създава с доставчика и кода в „Продукти“, после служителят обновява каталога. При реалния 404 първо е нужно внедряване на самата операция; само смяна на ролята не решава липсващ endpoint. Отделен електронен queue за предложения за нови продукти не е симулиран — планът остава в delivery-identity-workflow.md.

## Новият процес

- **Разпознат продукт**: единствената verified supplier+code асоциация дава ID/каталожно име. Няма задължителен picker или действие за избор; Детайли е незадължително. OCR оригиналът остава.
- **Нов продукт**: OCR името/кодът са редактируеми директно в основния ред. При налична capability и server can_manage има истински бутон **„Добави в каталога“** и отделен човешки диалог за името/кода. Това създава само продукт и асоциация чрез съществуващата catalog транзакция, не stock. Може да се добави identity дори когато годността още трябва да се провери; физическата проверка остава false.
- **Нужна корекция**: липсващ доставчик, неправилен код, нееднозначна/неактивна/непотвърдена асоциация. Няма отгатване по име. Показва се точният проблем и действие за редакция само на този ред.
- **Чака управител**: липсваща backend операция, невъзможно зареждане на връзките или липсващо право за нов продукт. Данните остават в черновата; няма задължителен избор на несвързан продукт.

Получени продължава да започва от Заявени като предложение. Редакцията отменя checked; „Проверено“ означава физическа проверка на продукта, количеството и положителния срок. „Маркирай всички“ е FilledButton.icon с минимална височина 52 px и нормални disabled цветове. Активен е само при поне един валиден ред; отделният диалог изисква физическа декларация, а невалидните редове остават непроверени. Не се разрешава заобикаляне на права/неразрешена каталожна идентичност.

Каталожното съпоставяне не носи количества, годности или lot от стари доставки. Всяка доставка/позиция има свои стойности и row ID; две партиди за един код не се сливат. Само атомарният V2 finalization записва batches/received movements. За същата доставка/операция идемпотентността остава. Глобално блокиране на две независими чернови за един хартиен документ **не е реализирано**; остава отделният backend план за одобрение.

## StoreFlow и логото

Android manifest label, Flutter MaterialApp title, login и home използват StoreFlow. Подзаглавието, tagline и пълното описание са запазени точно в общия StoreFlowBrand; описанието е в „За StoreFlow“. iOS CFBundleDisplayName/CFBundleName са StoreFlow.

Идентификаторите са запазени: Android `com.expiry_tracker.expiry_tracker`, iOS `com.expirytracker.expiryTracker`. Вътрешното Dart package остава expiry_tracker; няма смяна на signing ключ. APK сертификатът е сравнен с предишния APK и е същият: SHA256 `a82a9837aecece20b88c973c82a4014fdd3362d9aeab5ed453a135e2ae26c13a`.

Оригиналното logo.png е копирано byte-for-byte в `assets/branding/storeflow-logo.png`. Чрез imagegen е отделен символът без дребния надпис; source PNG е запазен. От него са произведени символ за Flutter, пет Android launcher density размера, adaptive foreground с 60% безопасна централна зона и светъл фон, splash assets и Android 12+ splash theme, iOS AppIcon размерите от Contents.json и LaunchImage 1x/2x/3x. iOS app icons са RGB без alpha. Изрязани са само празните/почти прозрачни външни полета, с допълнителен padding около измерения символ; никоя част от символа не е отрязана. Символът е проверен визуално в `build/storeflow-icon-preview.png`.

iOS имената и assets са подготвени/валидирани; iOS build не е изпълняван на Windows.

## Променени файлове

- `lib/services/product_catalog_service.dart`: реална auth capability проверка и точни грешки/permissions.
- нов `lib/services/delivery_row_status.dart`: обща типизирана логика на статусите/действията.
- `lib/screens/delivery_editor_screen.dart`, `delivery_item_screen.dart`, `lib/widgets/bulk_review_row.dart`: ясни редове/статуси, catalog-only добавяне, блокиране при липсващ backend, Filled mark-all.
- `lib/services/delivery_catalog_service.dart`: отделен catalogOnly режим без физическо потвърждение/stock ефект.
- `lib/screens/products_screen.dart`, `product_form_screen.dart`: правилният stable ID в редактора и реален capability gate.
- нов `lib/widgets/storeflow_brand.dart`, `lib/main.dart`, `lib/screens/login_screen.dart`, `home_screen.dart`, `lib/widgets/expiry_dashboard.dart`: име/текстове/брандиране.
- `pubspec.yaml`, `assets/branding/*`, Android manifest/res mipmap/drawable/colors/styles, iOS Info.plist/AppIcon/LaunchImage assets: платформена идентичност.
- `test/storeflow_workflow_test.dart`, `storeflow_platform_test.dart`, `paddle_http_test.dart`, `delivery_identity_test.dart`, `widget_test.dart`: нови проверки и scroll адаптация на login теста.

V2 runtime JS файловете и Paddle proxy са сравнени с прегледаните release архиви и са непроменени. Production migrations/hooks/database не са редактирани.

## Резултати

| Проверка | Резултат |
|---|---|
| flutter analyze --no-pub | чист |
| flutter test --no-pub | 110 успешни; 2 live SDK сценария изпълнени отделно |
| Реален изолиран PB 0.40.4 | 14 V2 + 10 catalog + 6 proxy групи успешни |
| Реални Flutter SDK сценарии | 2 успешни |
| Две теми, 320 px, 200% текст | widget проверки без overflow; mark-all ≥48 px |
| Android APK | успешен build; aapt потвърждава StoreFlow, същия application ID и adaptive icon |
| Подпис | същият сертификат като previous-app-debug.apk |
| iOS | имена, PNG размери и RGB icons валидирани; без native build |
| A50 | ADB показа само offline устройство; не е инсталиран/тестван новият APK на телефон |

## Точен APK и време

`C:\Users\cocev\AndroidStudioProjects\expiry_tracker\build\app\outputs\flutter-apk\app-debug.apk`

Генериран на **26.10.2026 00:25:39 Europe/Sofia** (25.10.2026 22:25:39 UTC), 200827070 bytes. SHA256: `b0ae6a2965180cdf12d75032d044838db4edc76473415f209e1fb64735308ef0`.

Предишният APK е запазен в `build/storeflow/previous-app-debug.apk`. Компактният report е `build/storeflow/validation.json`.

## Безопасно обновяване на Galaxy A50

Свържете USB, отключете телефона и разрешете debugging. В PowerShell:

```powershell
$adb = 'C:\Users\cocev\AppData\Local\Android\sdk\platform-tools\adb.exe'
& $adb devices -l
```

Използвайте serial само ако редът е `device`, не offline/unauthorized. За предишния A50 serial R58MB04FNJD, ако отново е потвърден в списъка:

```powershell
& $adb -s R58MB04FNJD shell pm path com.expiry_tracker.expiry_tracker
& $adb -s R58MB04FNJD install -r 'C:\Users\cocev\AndroidStudioProjects\expiry_tracker\build\app\outputs\flutter-apk\app-debug.apk'
```

Не използвайте uninstall, pm clear или изтриване на app data. Преди update запазете важните чернови чрез наличния си backup процес. При signature mismatch спрете и проверете APK/ключа; не премахвайте приложението като „решение“. Този build има същия подпис като запазения предишен debug APK, но не е прочетен сертификат от самия offline телефон.

След update проверете StoreFlow icon/name, вход, каталожния capability banner, доставчик на документа и 37-те OCR реда. При текущия реален Catalog 404 **не очаквайте успешно създаване на нови продукти** — те остават запазени в черновата с ясно обяснение до одобрено внедряване на V3. Изпитвайте реално финализиране само с одобрена тестова доставка; OCR или catalog create сами не трябва да променят наличности.

За UI rollback може да използвате предишния APK със същия подпис чрез install -r, без data reset. Не изтривайте вече потвърдени каталожни продукти или реални доставки и не възстановявайте стара production база заради UI rollback.
