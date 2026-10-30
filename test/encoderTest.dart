import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:splatoon3record/domain/models.dart';
import 'package:splatoon3record/media/ffmpeg/ffmpegService.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Explain an outdated NVENC driver', () {
    const Text = '[h264_nvenc @ 0000016c3e5d4640] Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0\n'
        '[h264_nvenc @ 0000016c3e5d4640] The minimum required Nvidia driver for nvenc is 610.00 or newer\n'
        '[vost#0:0/h264_nvenc @ 0000016c3bf56fc0] [enc:h264_nvenc @ 0000016c3e1ddc40] Error while opening encoder';
    expect(FFmpegService.EncoderHint(Text), contains('610.00'));
    expect(FFmpegService.EncoderHint('Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0'), 'NVIDIA 驱动版本过低，需要更新显卡驱动');
    expect(FFmpegService.EncoderHint('Cannot load nvcuda.dll'), '未检测到支持 NVENC 的 NVIDIA 显卡');
    expect(FFmpegService.EncoderHint('Error while opening encoder'), '编码器初始化失败');
    expect(FFmpegService.EncoderHint('frame=0\nfps=0.00\nspeed=0.798x'), '');
  });
  test('Order encoder candidates', () {
    expect(FFmpegService.EncoderLabel('h264_nvenc'), 'NVIDIA NVENC');
    expect(FFmpegService.EncoderLabel('h264_qsv'), 'Intel QSV');
    expect(FFmpegService.EncoderLabel('h264_amf'), 'AMD AMF');
    expect(FFmpegService.EncoderLabel('libx264'), '软件编码');
    expect(FFmpegService.EncoderOrder(RecordSettings()), <String>['h264_nvenc', 'h264_qsv', 'h264_amf', 'libx264']);
    expect(FFmpegService.EncoderOrder(RecordSettings(Encoder: 'amd')), <String>['h264_amf', 'libx264']);
    expect(FFmpegService.EncoderOrder(RecordSettings(Encoder: 'intel')), <String>['h264_qsv', 'libx264']);
  });
  test('Order archive H.265 encoders', () {
    expect(FFmpegService.ArchiveEncoderOrder(RecordSettings()), <String>['hevc_nvenc', 'hevc_qsv', 'hevc_amf', 'libx265']);
    expect(FFmpegService.ArchiveEncoderOrder(RecordSettings(Encoder: 'software')), <String>['hevc_nvenc', 'hevc_qsv', 'hevc_amf', 'libx265']);
    expect(FFmpegService.ArchiveEncoderOrder(RecordSettings(Encoder: 'nvidia')), <String>['hevc_nvenc', 'libx265']);
    expect(FFmpegService.ArchiveEncoderOrder(RecordSettings(Encoder: 'amd')), <String>['hevc_amf', 'libx265']);
    expect(FFmpegService.ArchiveEncoderOrder(RecordSettings(Encoder: 'intel')), <String>['hevc_qsv', 'libx265']);
  });
  test('Build archive H.265 quality arguments', () {
    final Temp = Directory.systemTemp.createTempSync('s3r-args-');
    final Service = FFmpegService(AppDirectories(Root: Temp.path));
    expect(Service.QualityArgs('hevc_nvenc', 22), containsAll(<String>['-preset', 'p4', '-rc', 'constqp', '-qp', '22']));
    expect(Service.QualityArgs('hevc_qsv', 22), containsAll(<String>['-global_quality', '22']));
    expect(Service.QualityArgs('libx265', 22), containsAll(<String>['-crf', '22']));
    expect(Service.QualityArgs('hevc_videotoolbox', 22), contains('-b:v'));
    expect(Service.ArchiveVideoArgs('libx265', 22), containsAll(<String>['-c:v', 'libx265', '-tag:v', 'hvc1']));
    Temp.deleteSync(recursive: true);
  });
  test('Probe bundled encoders and fall back to a working one', () async {
    final Temp = await Directory.systemTemp.createTemp('s3r-encoder-');
    final Directories = AppDirectories(Root: Temp.path);
    await Directories.Create();
    final Service = FFmpegService(Directories);
    expect(await Service.Probe('libx264'), true);
    final Picked = await Service.Encoder(RecordSettings());
    expect(const <String>['h264_nvenc', 'h264_qsv', 'h264_amf', 'libx264'], contains(Picked));
    expect(await Service.Probe(Picked), true);
    await Temp.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
  test('Extract ffmpeg once under concurrent calls', () async {
    final Temp = await Directory.systemTemp.createTemp('s3r-extract-');
    final Directories = AppDirectories(Root: Temp.path);
    await Directories.Create();
    final Service = FFmpegService(Directories);
    final Paths = await Future.wait(<Future<String>>[Service.Ensure(), Service.Ensure(), Service.Ensure()]);
    expect(Paths.toSet().length, 1);
    final FileRef = File(Paths.first);
    expect(FileRef.existsSync(), true);
    expect(FileRef.lengthSync(), greaterThan(1000000));
    expect(FileRef.path.endsWith('.tmp'), false);
    await Temp.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
