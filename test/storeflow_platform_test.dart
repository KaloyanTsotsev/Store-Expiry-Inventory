import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'StoreFlow display names preserve Android/iOS identity and signing setup',
    () {
      final android = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(android, contains('android:label="StoreFlow"'));
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('"com.expiry_tracker.expiry_tracker"'));
      expect(
        gradle,
        contains('signingConfig = signingConfigs.getByName("debug")'),
      );
      final ios = File('ios/Runner/Info.plist').readAsStringSync();
      expect(
        ios.replaceAll('\r\n','\n'),
        contains(
          '<key>CFBundleDisplayName</key>\n\t<string>StoreFlow</string>',
        ),
      );
      expect(ios, contains(r'$(PRODUCT_BUNDLE_IDENTIFIER)'));
      expect(
        File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync(),
        contains(
          'PRODUCT_BUNDLE_IDENTIFIER = com.expirytracker.expiryTracker;',
        ),
      );
    },
  );
  test(
    'All adaptive, legacy, iOS and splash assets exist with complete PNG data',
    () {
      for (final density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
        for (final name in ['ic_launcher.png', 'ic_launcher_foreground.png']) {
          final bytes = File('android/app/src/main/res/mipmap-$density/$name')
              .readAsBytesSync();
          expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
        }
      }
      expect(
        File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml')
            .readAsStringSync(),
        contains('<adaptive-icon'),
      );
      final folder = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      final config =
          jsonDecode(File('$folder/Contents.json').readAsStringSync()) as Map;
      for (final entry in config['images'] as List) {
        if (entry['filename'] != null) {
          expect(File('$folder/${entry['filename']}').existsSync(), isTrue);
        }
      }
      expect(File('assets/branding/storeflow-symbol.png').existsSync(), isTrue);
      expect(
        File('android/app/src/main/res/drawable/launch_background.xml')
            .readAsStringSync(),
        contains('storeflow_splash'),
      );
    },
  );
}
