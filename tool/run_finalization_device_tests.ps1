param(
  [string]$Device='R58MB04FNJD',
  [string]$Flutter='D:/Programming/FlutterAPK/flutter/bin/flutter.bat',
  [string]$Adb='C:/Users/cocev/AppData/Local/Android/sdk/platform-tools/adb.exe'
)
$ErrorActionPreference='Stop'
function Invoke-Checked {
  param([string]$Program,[string[]]$Arguments)
  & $Program @Arguments
  if($LASTEXITCODE -ne 0) {throw "Command failed: $Program ($LASTEXITCODE)"}
}
$project=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Push-Location -LiteralPath $project
try {
  $deviceState=& $Adb -s $Device get-state 2>$null
  if($deviceState -ne 'device') {throw 'Connect and authorize the unlocked phone first.'}
  $window= & $Adb -s $Device shell dumpsys window
  if($window -match 'isKeyguardShowing=true|mDreamingLockscreen=true') {throw 'Unlock the phone before running the UI tests.'}
  Invoke-Checked $Flutter @('build','apk','--debug','--no-pub','--target=integration_test/finalization_device_test.dart','--dart-define=OCR_TEST_APP=true')
  $metadata=Get-Content -LiteralPath 'build/app/outputs/apk/debug/output-metadata.json' -Raw | ConvertFrom-Json
  if($metadata.applicationId -ne 'com.expiry_tracker.expiry_tracker.ocrtest') {throw 'Refusing to run a non-test APK.'}
  $testApk=(Resolve-Path -LiteralPath 'build/app/outputs/flutter-apk/app-debug.apk').Path
  # Critical: give Flutter the verified prebuilt APK. Parsing the Gradle source
  # can incorrectly identify the main package and uninstall it during cleanup.
  Invoke-Checked $Flutter @('drive','--driver=test_driver/finalization_driver.dart',
    '--target=integration_test/finalization_device_test.dart',"--use-application-binary=$testApk",'-d',$Device)
} finally {Pop-Location}
