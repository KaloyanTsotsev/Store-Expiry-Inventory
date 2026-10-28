# V2, етап 1 — локален OCR и чернови

## Реализирано

Начало → Сканирай доставка → камера или няколко снимки от галерията →
автоматичен локален OCR → позиции за редакция → физическа проверка →
локална чернова. Повторно снимане/замяна на отделна страница, визуален преглед
с увеличение, преглед на raw OCR, ръчно добавяне/премахване на погрешен ред,
разделяне на един артикул на две отделни партиди.

Черновите са в private application support directory, по employee ID.
Снимките се копират от временния picker cache. JSON snapshot се записва с
flush и atomic rename; предходният snapshot се пази като draft.previous.json.
Паралелните локални saves се сериализират. При грешка се показва незаписаното
състояние и екранът не се затваря до успешен повторен запис.
Възстановяване на picker response след унищожена Activity запазва собственика
и заменя само избраната страница при retake.

Полученото количество винаги се въвежда физически. OCR не извежда receipt
от „Заявени“/„Разлика“. „1“ не е дата и се маркира и като неясен lot placeholder.
Всяка положителна позиция изисква изрично избран каталожен product, реално
прието количество, unit, валиден срок и партида, преди да бъде маркирана
„Проверена“. Нула е валидна неполучена позиция. Идентични product имена не
се сливат или съпоставят автоматично; изборът показва barcode и record ID.
Кодът на доставчика не се записва като barcode.

Няма запис на deliveries/batches/stock_movements на сървъра от този етап.
Проверена чернова не означава финализирана доставка. Активни партиди,
Dashboard, физически batch checks, брак и многотелефонните транзакции са
следващи етапи, зависещи от одобрението на backend-v2-proposal.md.

## Избор и реална поддръжка на OCR

- Android: Tesseract4Android 4.9.0 (Tesseract 5.5.1), LSTM-only,
  official tessdata_fast bul+eng, PSM 4. Моделите са в APK и не се теглят
  при сканиране. Няма мрежов OCR/AI endpoint и няма качване на снимки.
- Tesseract има официален Bulgarian модел `bul`. Кирилица и латински имена
  се разпознават заедно, но това не гарантира точни таблични стойности.
- Google ML Kit Text Recognition v2 не е избран: официалният списък няма
  Bulgarian/Cyrillic модел за нужния Android сценарий. Romanized Bulgarian
  не е доказателство за поддръжка на сниман български текст на кирилица.
- Tesseract връща текст, bounding boxes и confidence на думите. Геометричният
  Dart parser реконструира колоните на предоставения шаблон и компенсира
  умерен наклон. Това не е универсално разбиране на всякакви фактури.
- Нативната обработка е на отделен executor, с една операция едновременно;
  EXIF rotation се отчита и големи изображения се ограничават до 3200 px
  чрез decode sampling. Не се изпълнява OCR върху UI нишката.
- iOS: снимане/избор и моделите за чернови са подготвени; OcrEngine е интерфейс.
  Нативният iOS OCR adapter още не е реализиран. Показва се ясна грешка;
  няма твърдение за тестван iPhone build.

Официални източници:
[ML Kit езици](https://developers.google.com/ml-kit/vision/text-recognition/v2/languages),
[Tesseract модели](https://tesseract-ocr.github.io/tessdoc/Data-Files.html),
[Android wrapper](https://github.com/adaptech-cz/Tesseract4Android),
[Tesseract.js benchmark](https://github.com/naptha/tesseract.js).

## Реални тестови снимки и ограничения на качеството

Двата предоставени JPEG файла са обработени локално на Windows и на
emulator-5554. Визуално показват една и съща таблица с 37 позиции, а не
две различни страници. Сходството се маркира като възможно повторение;
няма автоматично сливане или изтриване. Прегледът от човек остава задължителен.

За независима проверка има ръчно преписани supplier codes, ordered quantities,
dates и lots в test/fixtures/document_reference.json. Това е референция от
снимката, не измислен OCR резултат. Header-ът с лични данни е изключен.

Първоначален Windows baseline с Tesseract.js PSM 4 и геометричния parser:

| Снимка | OCR време | Редове | Точни кодове /37 | Точни заявени /37 | Точни реални дати /23 | Точни lot стойности /37 |
|---|---|---|---|---|---|---|
| pq3yI77f1.jpg | 3.397 s | 37 | 35 | 31 | 19 | 14 |
| yXHe3CpH1.jpg | 2.973 s | 37 | 14 | 33 | 18 | 7 |

Числата са exact match по реда на документа, без автоматично поправяне на
OCR. 14 позиции в оригинала имат „1“ вместо срок; те не са сред 23-те реални
дати. Lot знаменателят включва тези placeholder стойности — съвпадението с
„1“ не го прави валиден номер на партида. Confidence не е процент точност.
Резултатите на native Android engine се пазят отделно в device_metrics.json;
не се смесват с резултатите на WebAssembly engine.

Финален native Android резултат след поправката за подравняване по OCR text lines:

| Снимка | OCR време | Редове | Точни кодове /37 | Точни заявени /37 | Точни реални дати /23 | Точни lot стойности /37 |
|---|---|---|---|---|---|---|
| pq3yI77f1.jpg | 2.850 s | 37 | 33 | 30 | 17 | 14 |
| yXHe3CpH1.jpg | 2.235 s | 37 | 12 | 35 | 17 | 9 |

Първоначалното подравняване по крайни колони се оказа недостатъчно при
липсващ code/unit OCR token. Финалната версия използва геометрията на
разпознатите text lines и има regression тест за този конкретен дефект.

Примери за необходими корекции: supplier код, разпознат с начално 3 вместо 9;
„10“ разпознато като „40“; `L` като `1`; липсващи точки в дата; слепени дата
и партида; латински и кирилски букви в имената. Доставчикът и номерът на
документа са замазани на примерите и не се попълват чрез догадки.

Пробвани са PSM 3/4/6 и експериментално изправяне/премахване на линии;
PSM 4 върху оригиналите е избран след сравнението. Непотвърдените резултати
не се превръщат в активни партиди. Това е работещ прототип с човешка проверка,
не unattended OCR за production документи.

## Light/Dark и навигация

Началният режим е Dark: navy фон #111C29, карти #233244, emerald акцент.
Light използва #E9F0F3 и бели карти. Меню „Тема“ предлага Системна/Светла/Тъмна;
изборът се запазва чрез SharedPreferencesAsync. Данните на черновите не се
пазят в preferences. Цветовете на текст/грешки и status bar следват темата.
Bottom Navigation има Начало, Доставки и Продукти; няма фиктивни броячи на
партиди и нефункционална секция Проверки преди реалния backend етап.

## Файлове

- lib/main.dart, theme/app_theme.dart: тема и зареждане на предпочитанието.
- screens/home_screen.dart, login_screen.dart, product_form_screen.dart:
  нов Home, навигация, theme-aware login и грешки; съществуващите Login,
  Products/Create Product и Logout са запазени.
- models/delivery_draft.dart: raw OCR, координати, позиции, чернови и валидация.
- services/ocr_service.dart: OcrEngine, native adapter и table parser.
- services/page_capture_service.dart: камера/избор на няколко снимки.
- services/draft_repository.dart: private файлове, atomic snapshots, picker recovery.
- screens/deliveries_screen.dart, delivery_editor_screen.dart,
  delivery_item_screen.dart, widgets/document_photo.dart: workflow и редактор.
- Android MainActivity.kt, app/root build.gradle.kts, assets/tessdata:
  локалният OCR, моделите и изолираният test application ID.
- ios/Runner/Info.plist: описания за camera/photo picker.
- pubspec.yaml/lock: image_picker, path_provider, shared_preferences;
  integration_test е от Flutter SDK, няма допълнителна state management система.
- test/, integration_test/, test_driver/, tool/ocr_benchmark/:
  синтетични fixtures, референция от документа, тестове и измервания.

## Възпроизвеждане

`flutter analyze`, `flutter test`, `flutter build apk --debug`.

За реалните Android тестове (подават се локалните фотографии):

```powershell
.\tool\run_ocr_device_tests.ps1 -Photo1 'C:\Users\cocev\Downloads\pq3yI77f1.jpg' -Photo2 'C:\Users\cocev\Downloads\yXHe3CpH1.jpg'
```

Скриптът проверява, че APK е с applicationId `.ocrtest`, преди да го инсталира.
Тестовият runner използва disposable приложение, отделно от служебните чернови.
След тестовете build/ съдържа тестов APK: за нормално приложение отново
изпълнете `flutter build apk --debug` **без** OCR_TEST_APP define.

Резултати: build/screenshots/, build/ocr_benchmark/device_report.json.
`python tool/ocr_benchmark/metrics.py` изчислява сравненията на native output.
За Windows benchmark: npm ci в tool/ocr_benchmark, bul/eng моделите от
Android assets се копират в tool/ocr_benchmark/models; OCR_PSM=4;
`node tool/ocr_benchmark/recognize.cjs <photo1> <photo2>`.
Следва `flutter test tool/ocr_benchmark/parse_test.dart`. Това е benchmark инструмент,
не част от мобилния runtime. Raw снимки и резултати са в ignored build/.

## Какво още не е проверено

Реалният camera/photo picker UI на физически Android телефон, lifecycle kill
по време на камерата на реално устройство, iOS build и iOS native OCR.
Device тестът подава две реални снимки през тестов picker adapter; самият OCR,
файловата система и Android preferences plugin са реални. Unit тестовете на
PocketBase използват mock HTTP сървър; в този етап няма реални backend writes.
Многотелефонни finalize/check/waste транзакции се тестват след одобрен backend.

## Финално изпълнени проверки

- flutter analyze: No issues found.
- flutter test: 20 unit/widget теста. Запазени са предишните тестове за Login,
  Products SDK authorization/pagination/create/errors и Logout.
- Реален Android: пет сценария чрез flutter drive на emulator-5554 — native
  OCR на двете фотографии; multi-page import и автоматичен OCR с повторно
  отваряне на чернова; двойно натискане и retry след synthetic OCR failure;
  реално запазване на тема чрез Android plugin; Dark/Light Home render.
- Получени и визуално прегледани home-dark.png, home-light.png,
  delivery-dark.png. Това са реални Flutter renders, не макети.
- Debug APK build: успешен. Финалният нормален APK се строи без OCR_TEST_APP,
  за да е с оригиналния application ID.

Нативният picker UI е заменен с тестов adapter само за автоматизирания import;
OCR на реалните фотографии не е mock. Retry сценарият използва изрично fake
OCR engine, а PocketBase unit тестовете — локален mock HTTP сървър.
