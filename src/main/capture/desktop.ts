import { desktopCapturer, session } from 'electron';

export function setDesktopAudioHandler(): void {
  session.defaultSession.setDisplayMediaRequestHandler(async (_request, callback) => {
    const sources = await desktopCapturer.getSources({ types: ['screen'] }).catch(() => []);
    const screen = sources[0];
    callback(screen ? { video: screen, audio: 'loopback' } : {});
  });
}
