// electron-builder 打包配置。
// 构建架构跟随运行所在的主机架构（CI 由 matrix 选择对应架构的运行器，本地构建前先确认自己的机器架构）。
// 各平台只保留本机对应的 onnxruntime 原生运行库，其余平台与架构的二进制通过 files 排除，控制安装包体积。
// 本机存在 Electron 解包目录时直接复用，避免打包阶段访问 GitHub；CI 上没有该目录，回退官方下载。
const { existsSync } = require('node:fs');
const path = require('node:path');
const napiRoot = 'node_modules/onnxruntime-node/bin/napi-v6';
const localElectron = path.join(__dirname, 'node_modules', 'electron', 'dist');
const platforms = ['darwin', 'linux', 'win32'];
const arch = process.arch === 'arm64' ? 'arm64' : 'x64';
const otherArch = arch === 'arm64' ? 'x64' : 'arm64';

// electron-builder 对 node_modules 只应用 "!" 排除规则，因此需要逐个列出不需要的目录
function appFiles(platform) {
  return [
    'dist/**/*',
    'package.json',
    ...platforms.filter((name) => name !== platform).map((name) => `!${napiRoot}/${name}/**`),
    `!${napiRoot}/${platform}/${otherArch}/**`,
  ];
}

module.exports = {
  appId: 'cn.miodu.splatoon3record',
  productName: 'Splatoon3 Record',
  directories: {
    output: 'release',
  },
  afterPack: './build/xattr.js',
  files: ['dist/**/*', 'package.json'],
  extraResources: [
    {
      from: 'src/renderer/assets/appIcon512.png',
      to: 'appIcon.png',
    },
    {
      from: 'runtime',
      to: 'runtime',
    },
  ],
  asarUnpack: ['node_modules/onnxruntime-node/**'],
  ...(existsSync(localElectron) ? { electronDist: localElectron } : {}),
  win: {
    icon: 'src/renderer/assets/appIcon.ico',
    target: ['nsis'],
    artifactName: 'splatoon3Record${version}${arch}Setup.${ext}',
    files: appFiles('win32'),
    extraResources: [
      {
        from: 'bin/ffmpeg.exe',
        to: 'bin/ffmpeg.exe',
      },
    ],
  },
  nsis: {
    oneClick: false,
    perMachine: false,
    allowToChangeInstallationDirectory: true,
  },
  mac: {
    icon: 'src/renderer/assets/appIcon.icns',
    category: 'public.app-category.games',
    identity: '-',
    hardenedRuntime: false,
    target: ['dmg'],
    artifactName: 'splatoon3Record${version}-mac-${arch}.${ext}',
    extendInfo: {
      NSCameraUsageDescription: '录制与直播需要读取采集卡或摄像头画面',
      NSMicrophoneUsageDescription: '录制与直播需要采集麦克风声音',
    },
    files: appFiles('darwin'),
    extraResources: [
      {
        from: 'bin/ffmpeg',
        to: 'bin/ffmpeg',
      },
    ],
  },
  linux: {
    target: ['AppImage'],
    artifactName: 'splatoon3Record${version}-linux-${arch}.${ext}',
    files: appFiles('linux'),
    extraResources: [
      {
        from: 'bin/ffmpeg',
        to: 'bin/ffmpeg',
      },
    ],
  },
};
