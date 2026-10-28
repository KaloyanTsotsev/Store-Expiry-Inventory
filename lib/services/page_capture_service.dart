import 'package:image_picker/image_picker.dart';

abstract class PageCapture {
  Future<List<XFile>> camera();
  Future<List<XFile>> gallery({required bool multiple});
}

class PageCaptureService implements PageCapture {
  final ImagePicker picker;
  PageCaptureService({ImagePicker? picker}) : picker = picker ?? ImagePicker();
  @override
  Future<List<XFile>> camera() async {
    final image = await picker.pickImage(
      source: ImageSource.camera,
      requestFullMetadata: false,
    );
    return image == null ? [] : [image];
  }

  @override
  Future<List<XFile>> gallery({required bool multiple}) async {
    if (multiple) return picker.pickMultiImage(requestFullMetadata: false);
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
    return image == null ? [] : [image];
  }
}
