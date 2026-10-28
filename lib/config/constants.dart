abstract final class Config {
  static const String ModelPath = 'assets/models/splatoonNickname.onnx';
  static const String FFmpegAsset = 'assets/tools/ffmpeg.exe';
  static const String FFmpegAssetUnix = 'assets/tools/ffmpeg';
  static const String FFplayAsset = 'assets/tools/ffplay.exe';
  static const String VideoToolbox = 'h264_videotoolbox';
  static const String MediaCodec = 'h264_mediacodec';
  static const int SegmentSeconds = 600;
  static const String BackgroundPath = 'assets/backgrounds/informationBg.jpg';
  static const String AppIconPath = 'assets/images/appIcon.png';
  static const String CharacterPath = 'assets/images/character.png';
  static const int PreviewInstancePort = 36766;
  static const int MaskWidth = 480;
  static const int MaskHeight = 270;
  static const int MaskFps = 5;
  static const int PreviewWidth = 1280;
  static const int PreviewHeight = 720;
  static const int PreviewFps = 30;
  static const String CaptureBuffer = '32M';
  static const String AudioBitrate = '192k';
  static const int AudioSampleRate = 48000;
  static const int AudioChannels = 2;
  static const String CacheFilePattern = r'Cache-(\d{8})-(\d{6})\.mp4$';
  static const String CacheTimePattern = r'(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})';
  static const String AppVersion = '3.0.0';
  static const String UserAgent = 'Splatoon3Record/3.0.0';
  static const int BattleDelayMs = 22000;
  static const int ClipLeadMs = 15000;
  static const int ClipTailMs = 30000;
  static const int MaxNSOAccounts = 5;
  static const int SingleInstancePort = 36763;
  static const int NSOPollSeconds = 60;
  static const int NSORetryMinutes = 10;
  static const int UpdatePollSeconds = 60;
  static const String QQHost = 'q.qq.com';
  static const String QQApi = 'https://api.sgroup.qq.com';
  static const String QQTokenUrl = 'https://bots.qq.com/app/getAppAccessToken';
  static const String NSOClientId = '71b963c1b7b6d119';
  static const String NSOAuthClientId = 'GlR_qsPZpNcxqMwnbsSjMA';
  static const String NSOAuthServer = 'https://nxapi-auth.fancy.org.uk';
  static const String NSOFServer = 'https://nxapi-znca-api.fancy.org.uk/api/znca';
  static const String NSOFServerAlternative = 'https://znca.furlingdu.com/api/znca';
  static const String NSOCoral = 'https://api-lp1.znc.srv.nintendo.net';
  static const String NSOSplatNet = 'https://api.lp1.av5ja.srv.nintendo.net';
  static const String NSOAppVersion = '10.0.0-dfefd0af';
  static const String NSOZncaVersion = '3.5.0';
  static const String NSOClientVersion = 'd8fAZDPzwimzQ7c6';
  static const int NSOWebServiceId = 4834290508791808;
  static const String NSOLatestQuery = 'b24d22fd6cb251c515c2b90044039698aa27bc1fab15801d83014d919cd45780';
  static const String NSODetailQuery = '94faa2ff992222d11ced55e0f349920a82ac50f414ae33c83d1d1c9d8161c5dd';
  static const List<String> ThemeColors = <String>['#4285f4', '#3f51b5', '#9c27b0', '#e91e63', '#f44336', '#ff9800', '#4caf50', '#009688', '#00bcd4', '#607d8b'];
}







