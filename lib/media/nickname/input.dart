import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:onnxruntime_v2/src/bindings/onnxruntime_bindings_generated.dart' as bg;

/// Owns a float32 model input tensor together with the native buffer behind it.
///
/// `OrtValueTensor.createTensorWithDataList` flattens the list element by
/// element into a growable boxed list, which costs far more CPU than the GPU
/// inference itself for a 1x3x1280x1280 input. Building the tensor straight
/// from a typed buffer keeps preprocessing to a single memcpy.
class OrtFloatInput {
  OrtFloatInput._(this.Value, this.Buffer);

  final OrtValueTensor Value;
  final ffi.Pointer<ffi.Float> Buffer;

  void dispose() {
    Value.release();
    calloc.free(Buffer);
  }

  static OrtFloatInput Create(Float32List Data, List<int> Shape) {
    final Buffer = calloc<ffi.Float>(Data.length);
    Buffer.asTypedList(Data.length).setRange(0, Data.length, Data);
    final ShapePointer = calloc<ffi.Int64>(Shape.length);
    ShapePointer.asTypedList(Shape.length).setRange(0, Shape.length, Shape);
    final InfoPointer = calloc<ffi.Pointer<bg.OrtMemoryInfo>>();
    final Api = OrtEnv.instance.ortApiPtr.ref;
    var Status = Api.AllocatorGetInfo.asFunction<
        bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtAllocator>,
            ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>>)>()(OrtAllocator.instance.ptr, InfoPointer);
    OrtStatus.checkOrtStatus(Status);
    final ValuePointer = calloc<ffi.Pointer<bg.OrtValue>>();
    Status = Api.CreateTensorWithDataAsOrtValue.asFunction<
        bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtMemoryInfo>,
            ffi.Pointer<ffi.Void>,
            int,
            ffi.Pointer<ffi.Int64>,
            int,
            int,
            ffi.Pointer<ffi.Pointer<bg.OrtValue>>)>()(
      InfoPointer.value,
      Buffer.cast<ffi.Void>(),
      Data.length * ffi.sizeOf<ffi.Float>(),
      ShapePointer,
      Shape.length,
      ONNXTensorElementDataType.float.value,
      ValuePointer,
    );
    OrtStatus.checkOrtStatus(Status);
    final Value = OrtValueTensor.fromAddress(ValuePointer.value.address);
    calloc.free(ShapePointer);
    calloc.free(InfoPointer);
    calloc.free(ValuePointer);
    return OrtFloatInput._(Value, Buffer);
  }
}
