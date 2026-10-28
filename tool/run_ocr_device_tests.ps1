param(
    [Parameter(Mandatory = $true)][string]$Photo1,
    [Parameter(Mandatory = $true)][string]$Photo2,
    [string]$Flutter = 'D:\Programming\FlutterAPK\flutter\bin\flutter.bat',
    [string]$Adb = 'C:\Users\cocev\AppData\Local\Android\sdk\platform-tools\adb.exe',
    [string]$Device = 'emulator-5554'
)
$ErrorActionPreference = 'Stop'
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $Program (exit $LASTEXITCODE)" }
}
$input1 = (Resolve-Path -LiteralPath $Photo1).Path
$input2 = (Resolve-Path -LiteralPath $Photo2).Path
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location -LiteralPath $project
try {
    Invoke-Checked $Flutter @('build', 'apk', '--debug', '--target=integration_test/ocr_device_test.dart', '--dart-define=OCR_TEST_APP=true')
    $metadata = Get-Content -LiteralPath 'build/app/outputs/apk/debug/output-metadata.json' -Raw | ConvertFrom-Json
    $testApp = 'com.expiry_tracker.expiry_tracker.ocrtest'
    if ($metadata.applicationId -ne $testApp) { throw 'Refusing to install a non-test APK.' }
    Invoke-Checked $Adb @('-s', $Device, 'install', '-r', 'build/app/outputs/flutter-apk/app-debug.apk')
    Invoke-Checked $Adb @('-s', $Device, 'push', $input1, '/data/local/tmp/expiry_page1.jpg')
    Invoke-Checked $Adb @('-s', $Device, 'push', $input2, '/data/local/tmp/expiry_page2.jpg')
    Invoke-Checked $Adb @('-s', $Device, 'shell', 'run-as', $testApp, 'mkdir', '-p', 'files/ocr_test')
    Invoke-Checked $Adb @('-s', $Device, 'shell', 'run-as', $testApp, 'cp', '/data/local/tmp/expiry_page1.jpg', 'files/ocr_test/page1.jpg')
    Invoke-Checked $Adb @('-s', $Device, 'shell', 'run-as', $testApp, 'cp', '/data/local/tmp/expiry_page2.jpg', 'files/ocr_test/page2.jpg')
    Invoke-Checked $Flutter @('drive', '--driver=test_driver/ocr_driver.dart',
        '--target=integration_test/ocr_device_test.dart', '--dart-define=OCR_TEST_APP=true',
        '--use-application-binary=build/app/outputs/flutter-apk/app-debug.apk', '-d', $Device)
} finally {
    Pop-Location
}
