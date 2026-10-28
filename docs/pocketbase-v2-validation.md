# PocketBase V2 — резултати от проверките

Дата: 22.10.2026. Среда: Windows, официален **PocketBase 0.40.4 windows_amd64**, SHA256 сверена с checksums.txt от същия GitHub release. Няма заявки към production, няма промени или спиране на OnePlus услугата.

## Реални интеграционни тестове: 13/13 успешни

Изпълнение: `backend/tool/test_backend.py --flutter` с exact-version binary. Всеки run създава отделна база, миграции и localhost процес; процесът се спира във finally. Реалните PocketBase migrations/JSVM/SQLite/HTTP се изпълняват, не се заменят с mock adapter.

| Проверка | Наблюдаван резултат |
| --- | --- |
| Capabilities + employees auth | protocol 2 на реален 0.40.4 |
| Анонимна заявка | 401 |
| Успешно финализиране | 1 нов продукт, 2 отделни N/A партиди с различни дати, 2 received движения, finalized |
| Повторен stage / finalize | Същият записан отговор, без нови inventory записи |
| Същият ключ, различен payload | 409 |
| Нов ключ за вече finalized доставка | 409, без дублиране |
| Отрицателно, NaN, липсващо количество, невалидна дата, unchecked | 400, без writes |
| Реален транзакционен rollback | Тестова грешка при второто движение; първите product/batch/movement също изчезват, revision/status остават предишните |
| Два паралелни автентикирани HTTP клиента | Един 200 и един 409; един комплект партиди/движения |
| Чужд служител / директен CRUD | Отказ; не могат да заобиколят endpoint-а |
| Нулево получено количество | Няма нов продукт/партида/движение |
| Защитена снимка | Липсваща снимка блокира finalize; upload се повтаря безопасно; finalized документът е заключен |
| Legacy sentinel записи | Първоначалните данни остават непроменени след всички V2 операции |

Отделно harness-ът сравнява всички оригинални колони и правила преди/след additive migration: без промени в стойности, timestamps или старите API Rules. Activation е изпълнена само върху synthetic базата.

## Flutter и Android build

- `flutter analyze`: **No issues found**.
- `flutter test --no-pub`: **50 успешни**, един live SDK тест е пропуснат по дизайн, когато няма изолиран backend.
- Същият live SDK тест, изпълнен отделно през harness-а: **успешен**. Реален вход като employee, capabilities probe, persistent staging, PNG upload, повторен prepare, finalize, повторен finalize и проверка на отделните batch ID/срокове през PocketBase SDK. Локалната receipt и проверките се отварят повторно от диска.
- `flutter build apk --debug --no-pub`: **успешен**, `build/app/outputs/flutter-apk/app-debug.apk`.

Предишните widget тестове покриват видимия sticky бутон, disabled състоянието, двойно натискане, последно потвърждение, изгубен отговор и disk failure след committed receipt. Live SDK проверката допълва тези UI проверки с реален backend.

## Граници на проверката и следващи приемателни условия

Fixtures съдържат реконструкция на четирите предоставени inventory exports и **синтетична employees auth схема**, защото не е предоставен пълен актуален export на employees. Не е използвано копие на реалните production данни. Реалната схема, съществуващите hooks и encryption/storage конфигурацията трябва да се сравнят и да се направи restore rehearsal според deployment плана. Няма автоматичен backfill или редакция на реални доставки.

Native ARM64 изпълнение на OnePlus и проверка през физически Samsung Galaxy A50 не са правени в тази backend сесия. APK build и live SDK тестът доказват интеграцията локално; не заместват приемателна проверка след одобрено внедряване. Автоматичен тест за разпознаване на един и същ хартиен документ като две отделно създадени чернови няма: защитата от повторение е върху стабилните client/server ID, revision и operation_key.

Нови продадени/бракувани/коригиращи операции и нови физически проверки през V2 endpoints са извън този пакет. Activation заключва старите директни inventory write APIs; това е изрично условие за одобрение на cutover.

Машинният отчет е `build/backend-v2/latest-report.json`. Подробните локални run бази и server.log са под `build/backend-v2/runs/`; те са тестови артефакти и не се внедряват. В `backend_review/` остава историческият прототип; каноничният изпълним код е в `backend/`.
