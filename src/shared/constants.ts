export const appName = 'Splatoon3 Record';
export const projectName = 'Splatoon3Record';
export const projectVersion = '2.0.0';
export const projectUrl = 'https://github.com/furlingdu/splatoon3-record';
export const authorName = '澪度';
export const avatarUrl = 'https://q2.qlogo.cn/headimg_dl?dst_uin=3648192311&spec=640';
export const groupUrl = '';
export const maxMatchSeconds = 360;
export const cacheMinutesFixed = 10;
export const segmentSecondsFixed = 30;
export const pollSecondsFixed = 10;
export const pushFileLimitMb = 100;
export const pushTargetMb = 100;
export const pushBitrateDefault = 2;
export const pushBitrateRange = { min: 0.1, max: 50 };
export const pushCodecDefault = 'hevc';
export const qualityTiers = [18, 22, 28];
export const qualityDefault = 22;
export const livePortDefault = 11567;
export const livePortRange = { min: 1024, max: 65535 };
export const nsoBackendDefault = 'https://znca.furlingdu.com';
export const localPortRange = { min: 10000, max: 65535 };
export const liveTimesliceMs = 1000;
export const blurConfidence = 0.1;
export const blurRadius = 10;
export const blurFeather = 4;
export const blurBoxLimit = 10;
export const detectBoxLimit = 12;
export const detectFrameWidth = 640;
export const blurJobWorkers = 3;
export const detectWorkers = 4;
export const defaultSettings = {
  videoDevice: '',
  audioDevice: '',
  width: 1920,
  height: 1080,
  fps: 60,
  flipVertical: false,
  encoder: 'auto' as const,
  quality: qualityDefault,
  saveDir: '',
  autoPush: true,
  autoRecord: true,
  autoLaunch: false,
  blurNickname: false,
  monitorAudio: false,
  pollSeconds: 10,
};
