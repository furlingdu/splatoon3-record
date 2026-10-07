export type PageName = 'status' | 'live' | 'binding' | 'matches' | 'gallery' | 'settings' | 'about';
export type RecordState = 'idle' | 'starting' | 'recording' | 'error';
export type LiveState = 'idle' | 'live' | 'error';
export type LinkState = 'unbound' | 'connecting' | 'connected' | 'expired' | 'error';
export type BattleKind = 'regular' | 'anarchyOpen' | 'anarchySeries' | 'xBattle' | 'event' | 'splatfest' | 'private' | 'salmon' | 'unknown';

export interface CaptureDevice {
  id: string;
  name: string;
  kind: 'video' | 'audio';
  maxWidth?: number;
  maxHeight?: number;
  maxFps?: number;
  nativeWidth?: number;
  nativeHeight?: number;
  nativeFps?: number;
}

export interface CaptureReport {
  recordState: RecordState;
  error?: string;
  width: number;
  height: number;
  fps: number;
  format?: string;
  hasAudio: boolean;
}

export interface RecordSettings {
  videoDevice: string;
  audioDevice: string;
  width: number;
  height: number;
  fps: number;
  flipVertical?: boolean;
  encoder: 'auto' | 'nvidia' | 'amd' | 'intel' | 'software';
  quality: number;
  saveDir: string;
  autoPush: boolean;
  autoRecord: boolean;
  autoLaunch: boolean;
  blurNickname: boolean;
  monitorAudio: boolean;
  pollSeconds: number;
}

export type PushCodec = 'hevc' | 'h264' | 'av1';

export interface PushOptions {
  cap: number;
  codec: PushCodec;
  targetMb: number;
}

export interface SegmentDraft {
  id: string;
  ext: string;
  startAt: number;
  endAt: number;
  width: number;
  height: number;
  fps: number;
  encoder: string;
  hasAudio: boolean;
}

export interface VideoRecord {
  filePath: string;
  startAt: number;
  endAt: number;
  width: number;
  height: number;
  fps: number;
  encoder: string;
  hasAudio: boolean;
  flip: boolean;
}

export interface WindowBounds {
  x?: number;
  y?: number;
  width: number;
  height: number;
  maximized?: boolean;
}

export interface LiveOptions {
  port: number;
}

export type LiveChunk =
  | { kind: 'meta'; codec: string; width: number; height: number; fps: number; channels: number; sampleRate: number; description?: ArrayBuffer }
  | { kind: 'video'; key: boolean; timestampUs: number; data: ArrayBuffer }
  | { kind: 'audio'; timestampUs: number; data: ArrayBuffer };

export interface LiveViewerEvent {
  viewers: number;
  key: boolean;
}

export interface RuntimeInfo {
  appVersion: string;
  electronVersion: string;
  chromeVersion: string;
  nodeVersion: string;
  platform: string;
  arch: string;
  osRelease: string;
  gpu: string[];
  gpuStatus: Record<string, string>;
  hardwareAcceleration: boolean;
  displays: string[];
}

export interface BlurJob {
  jobId: string;
  output: string;
}

export interface DetectBox {
  x: number;
  y: number;
  width: number;
  height: number;
  conf: number;
}

export interface DetectReply {
  boxes: DetectBox[];
  ms: number;
}

export interface AppConfig {
  settings: RecordSettings;
  pushEnabled: boolean;
  setupDone: boolean;
  qqOwner?: string;
  handledIds: string[];
  windowBounds?: WindowBounds;
}

export interface BattleMatch {
  matchId: string;
  kind: BattleKind;
  mode: string;
  rule: string;
  startAt: number;
  endAt: number;
  duration: number;
  result: string;
  isDisconnected: boolean;
  isSalmon: boolean;
  videoPath?: string;
  rawData: unknown;
}

export interface AppStatus {
  recordState: RecordState;
  recordError?: string;
  streamWidth: number;
  streamHeight: number;
  streamFps: number;
  streamFormat?: string;
  streamAudio: boolean;
  segments: number;
  cacheStart?: number;
  cacheEnd?: number;
  hwAccel?: string;
  encoder?: string;
  nsoState: LinkState;
  nsoError?: string;
  qqState: LinkState;
  qqOwner?: string;
  qrCode?: string;
  setupDone: boolean;
  recentMatches?: BattleMatch[];
  processingMatchIds?: string[];
  latestMatch?: BattleMatch;
  pushState?: 'idle' | 'sending' | 'error';
  pushError?: string;
  settings: RecordSettings;
  pushOptions: PushOptions;
  liveState: LiveState;
  liveError?: string;
  liveUrl?: string;
  liveOptions: LiveOptions;

}

export interface UserMessage {
  content: string;
  senderId: string;
  target: unknown;
  isPrivate: boolean;
  isProxy: boolean;
}

export interface SecretData {
  nsoSession?: string;
  nsoToken?: NsoToken;
  qqAppId?: string;
  qqSecret?: string;
}

export interface NsoToken {
  bulletToken: string;
  gToken: string;
  language: string;
  country: string;
  userAgent: string;
  expiresAt: number;
}

export interface NsoLoginData {
  authUrl: string;
  state: string;
  verifier: string;
}

export type SetupResult = { success: true } | { success: false; error: string };

export interface BridgeApi {
  getStatus: () => Promise<AppStatus>;
  saveSettings: (settings: RecordSettings) => Promise<AppStatus>;
  openNsoLogin: () => Promise<void>;
  clearNsoLogin: () => Promise<void>;
  unbindNso: () => Promise<void>;
  startQqLogin: () => Promise<void>;
  unbindQq: () => Promise<void>;
  listMatches: () => Promise<BattleMatch[]>;
  thumb: (matchId: string) => Promise<string>;
  openMatch: (matchId: string) => Promise<void>;
  saveMatch: (matchId: string) => Promise<string | undefined>;
  deleteMatch: (matchId: string) => Promise<void>;
  getVideoUrl: (matchId: string) => Promise<string | undefined>;
  writeChunk: (id: string, chunk: ArrayBuffer, offset: number) => Promise<boolean>;
  writeSegment: (draft: SegmentDraft) => Promise<VideoRecord | undefined>;
  reportCapture: (report: CaptureReport) => void;
  debugExportLast: () => Promise<string | undefined>;
  openPath: (targetPath: string) => Promise<void>;
  pickFolder: () => Promise<string | undefined>;
  openLink: (url: string) => Promise<void>;
  finishSetup: () => Promise<SetupResult>;
  openPreview: () => Promise<void>;
  startLive: () => Promise<AppStatus>;
  stopLive: () => Promise<AppStatus>;
  liveChunk: (chunk: LiveChunk) => void;
  onLiveViewers: (callback: (event: LiveViewerEvent) => void) => () => void;
  startBlur: (matchId: string, mime: string) => Promise<BlurJob | undefined>;
  writeBlurChunk: (jobId: string, chunk: ArrayBuffer) => Promise<boolean>;
  endBlur: (jobId: string, reveal?: boolean) => Promise<string | undefined>;
  cancelBlur: (jobId: string) => Promise<void>;
  startDetect: () => Promise<string>;
  detectFrame: (frame: ArrayBuffer, width: number, height: number, conf: number) => Promise<DetectReply>;
  stopDetect: () => Promise<void>;
  copyText: (text: string) => Promise<void>;
  getRuntimeInfo: () => Promise<RuntimeInfo>;
  getEvents: (callback: (status: AppStatus) => void) => () => void;
}

declare global {
  interface Window {
    recordApi: BridgeApi;
  }
}
