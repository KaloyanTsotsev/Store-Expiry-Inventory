# StoreFlow — Android emulator test, 12 November 2026

## Result

Started the existing **Pixel_8 AVD, Android 17 / API 37, x86_64, 1080×2400**. Tested the real Flutter Android application against a real, disposable **PocketBase 0.40.4** on this computer. The schema has the three intentionally removed product fields absent. No request or migration was sent to the production OnePlus, and no physical employee phone was modified.

The emulator remains open with a normally launching test app, application ID **`com.expiry_tracker.expiry_tracker.ocrtest`**. It connects only through ADB reverse to the isolated database. The standard app ID/signing configuration remains unchanged. The standard debug APK at `build/app/outputs/flutter-apk/app-debug.apk` was rebuilt with the normal production profile after device testing; the separate emulator-only APK is `build/emulator-report/storeflow-emulator.apk`.

## Verified on Android

| Flow | Verified result |
| --- | --- |
| Login | Incorrect credentials rejected, corrected credentials reach the employee dashboard |
| Product catalog | Manager creates a product using the three-field form; leading-zero article code persists exactly |
| Document import | Original supplied JPEG passes through the real authenticated PocketBase OCR proxy to a **recorded Paddle response** with 37 rows |
| Automatic validation | 23 rows initially ready, 14 missing dates correctly blocked; numeric date corrections become Ready without another review button |
| Quantity correction | Entering `1`, then `15`, keeps the original quantity until explicit confirmation |
| Actual delivery save | One Save creates **37 batches and 37 received movements**, reusing/creating products by exact code; local receipt and completed status persist |
| Repeat submission | Exact finalization replay returns the same receipt; batch count stays 37 |
| Another expiry | Existing code reuses its product ID; second date/quantity creates a separate batch without overwriting the first |
| Calendar | Existing date picker opens and cancels while preserving the manually entered date |
| Drafts | Save, back navigation, reopen and confirmed local deletion work |
| Markdown acknowledgement | Actual 25% acknowledgement reaches PocketBase; task disappears from the markdown queue; unavailable push configuration is clearly displayed |
| Expired entry handling | Cancel leaves the entry unchanged; confirmation closes only that batch; another expiry and the product remain intact; a second authenticated session sees the change; no stock/waste movement is added |
| Failed finalization | A test-only injected receipt failure rolls back the entire transaction. Draft and exact pending request survive. The unfinished staged delivery can then be discarded safely |
| Product deletion | A product with batch/history references is refused deletion; no cascade occurs |
| Appearance | Light/dark theme switches work; native screenshot confirms StoreFlow branding and readable login |

The main Android integration test passed in **54 seconds** and the safety integration test in **24 seconds** (excluding builds/installation). Final host verification: **150 Flutter tests passed**, 4 localhost-only live tests skipped in the general suite; **Flutter analysis reported no issues**. Device tests exercise actual network, filesystem, authentication and persistence.

Independent post-test API verification of delivery `lb6mcrojavrgm89` found **37 batches, 37 received movements, 37 product IDs**. Batch quantities and incoming movement quantities both total **243**. This is intentional test data: the first document quantity was changed from 2 to 15 to test quantity correction. It is not a claim about a real shipment. Proof is saved in `build/emulator-report/persistence-proof.json`.

## Finding fixed

A controlled HTTP 409 transaction failure was previously described as a revision conflict or already processed delivery. The error mapper now distinguishes `transaction_not_confirmed` and tells the employee:

> Записването не е потвърдено от сървъра. Черновата е запазена. Опитайте отново от този екран, без да създавате нова доставка.

Changed application file: `lib/services/delivery_finalization_service.dart`. Added a regression assertion in `test/finalization_test.dart`. No persistence logic, backend hook, schema, API Rule, product identity or signing key was changed by this correction.

Earlier test-driver attempts needed explicit native text focus, server-response waits and scroll positioning above the sticky footer. Those were automation adjustments, not additional application failures. The final successful logs are the results quoted above. Two nonfatal hit-test warnings on popup-menu text occur in the safety log; both brightness assertions passed. Some framework-captured theme images can precede asset decoding; the final native screenshot confirms the logo renders correctly. The Firebase dependency also emits the existing future Kotlin Gradle Plugin migration warning; current builds succeed.

## Limits — not claimed as tested

- **Live PaddleOCR inference on OnePlus was not rerun.** The real supplied JPEG and recorded real 37-row JSON test the Android import/proxy/parser/review/save integration. This does not remeasure OCR accuracy or recognition speed.
- The image-picker chooser is injected with the supplied photo. Physical camera quality, autofocus, native camera/gallery permission dialogs and real scanning hardware are not certified by this run.
- Real FCM closed-app delivery is untested and disabled: the owner has no Firebase project or protected remote-access configuration yet.
- Production deployment, mobile-data/VPN/HTTPS connectivity and a physical Galaxy A50 remain separate acceptance checks. Android 17 emulator results are not a guarantee for every device/OS combination.
- This is broad acceptance coverage of the principal flows, not an exhaustive test of every possible input, role and failure combination.

## Evidence

- [Native emulator screenshot](C:/Users/cocev/AndroidStudioProjects/expiry_tracker/build/emulator-report/13-emulator-live.png)
- [Dashboard after real test persistence](C:/Users/cocev/AndroidStudioProjects/expiry_tracker/build/emulator-report/05-expiry-dashboard-after-save.png)
- [OCR review](C:/Users/cocev/AndroidStudioProjects/expiry_tracker/build/emulator-report/04-ocr-review.png)
- [Markdown tasks](C:/Users/cocev/AndroidStudioProjects/expiry_tracker/build/emulator-report/06-markdowns.png)
- [Controlled transaction failure](C:/Users/cocev/AndroidStudioProjects/expiry_tracker/build/emulator-report/09-transaction-rollback.png)
- [Unsafe product deletion refused](C:/Users/cocev/AndroidStudioProjects/expiry_tracker/build/emulator-report/10-unsafe-delete-blocked.png)
- [Light theme](C:/Users/cocev/AndroidStudioProjects/expiry_tracker/build/emulator-report/11-light-theme.png)

Device-side screenshots and results were exported to `build/emulator-report`. The main and safety JSON reports contain 8 and 4 grouped assertions respectively. Logs: `build/emulator-app-test.log`, `build/emulator-safety-test.log`, `build/emulator-analyze.log`, `build/emulator-unit-tests.log`, `build/emulator-backend.log`.

## Manual use of the open emulator

The account is synthetic, created only in the disposable test database:

```text
Username: owner
Password: synthetic-test-only-40.4!
```

Do not use these credentials on the real server. A manager test account uses username `manager` and the same synthetic password. The test backend is bound to loopback and automatically stops approximately **12 November 2026, 02:53 Europe/Sofia**, two hours after startup. The emulator itself stays open. When the backend stops, this test app must report the connection failure; it must not be pointed at production to continue these destructive/synthetic tests.

The runtime URL/work directory/stop-file path are recorded in `build/emulator-test-runtime.json`. To stop the fixture manually, create the indicated `STOP_EMULATOR_TEST` file. To restart testing later:

```powershell
& 'C:\Users\cocev\AppData\Local\Android\Sdk\emulator\emulator.exe' -avd Pixel_8
& 'C:\Users\cocev\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' backend/tool/test_backend.py --catalog --without-product-fields --markdown --hold-emulator
```

In another terminal, after “EMULATOR TEST BACKEND READY”:

```powershell
$runtime = Get-Content build/emulator-test-runtime.json | ConvertFrom-Json
$port = ([uri]$runtime.url).Port
$adb = 'C:\Users\cocev\AppData\Local\Android\Sdk\platform-tools\adb.exe'
& $adb -s emulator-5554 reverse tcp:18090 "tcp:$port"
& $adb -s emulator-5554 reverse tcp:18765 tcp:8765
flutter test --no-pub integration_test/emulator_app_test.dart -d emulator-5554 --no-uninstall --dart-define=OCR_TEST_APP=true --dart-define=POCKETBASE_URL=http://127.0.0.1:18090
flutter test --no-pub integration_test/emulator_safety_test.dart -d emulator-5554 --no-uninstall --dart-define=OCR_TEST_APP=true --dart-define=POCKETBASE_URL=http://127.0.0.1:18090
```

Use a fresh fixture runtime for a complete repeat. Integration-runner builds are for automated tests; the retained standalone emulator APK launches `lib/main.dart` normally and does not rerun test scenarios when opened.

## Added test infrastructure

- `integration_test/emulator_app_test.dart`
- `integration_test/emulator_safety_test.dart`
- `backend/tool/emulator_fixture_server.py`
- Optional `--hold-emulator` mode in `backend/tool/test_backend.py`

These files are not production deployment hooks and require no migration on OnePlus.
