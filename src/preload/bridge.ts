import { contextBridge, ipcRenderer } from 'electron';
import { appEvent, ipcNames, liveViewersEvent } from '../shared/events.js';
import type { AppStatus, BridgeApi, CaptureReport, LiveChunk, LiveViewerEvent, RecordSettings, SegmentDraft } from '../shared/types.js';

const recordApi: BridgeApi = {
  getStatus: () => ipcRenderer.invoke(ipcNames.getStatus),
  saveSettings: (settings: RecordSettings) => ipcRenderer.invoke(ipcNames.saveSettings, settings),
  openNsoLogin: () => ipcRenderer.invoke(ipcNames.openNsoLogin),
  clearNsoLogin: () => ipcRenderer.invoke(ipcNames.clearNsoLogin),
  unbindNso: () => ipcRenderer.invoke(ipcNames.unbindNso),
  startQqLogin: () => ipcRenderer.invoke(ipcNames.startQqLogin),
  unbindQq: () => ipcRenderer.invoke(ipcNames.unbindQq),
  listMatches: () => ipcRenderer.invoke(ipcNames.listMatches),
  thumb: (matchId: string) => ipcRenderer.invoke(ipcNames.getThumb, matchId),
  openMatch: (matchId: string) => ipcRenderer.invoke(ipcNames.openMatch, matchId),
  saveMatch: (matchId: string) => ipcRenderer.invoke(ipcNames.saveMatch, matchId),
  deleteMatch: (matchId: string) => ipcRenderer.invoke(ipcNames.deleteMatch, matchId),
  getVideoUrl: (matchId: string) => ipcRenderer.invoke(ipcNames.getVideoUrl, matchId),
  writeChunk: (id: string, chunk: ArrayBuffer, offset: number) => ipcRenderer.invoke(ipcNames.writeChunk, id, chunk, offset),
  writeSegment: (draft: SegmentDraft) => ipcRenderer.invoke(ipcNames.writeSegment, draft),
  reportCapture: (report: CaptureReport) => ipcRenderer.send(ipcNames.reportCapture, report),
  debugExportLast: () => ipcRenderer.invoke(ipcNames.debugExport),
  openPath: (targetPath: string) => ipcRenderer.invoke(ipcNames.openPath, targetPath),
  pickFolder: () => ipcRenderer.invoke(ipcNames.pickFolder),
  openLink: (url: string) => ipcRenderer.invoke(ipcNames.openLink, url),
  finishSetup: () => ipcRenderer.invoke(ipcNames.finishSetup),
  openPreview: () => ipcRenderer.invoke(ipcNames.openPreview),
  startLive: () => ipcRenderer.invoke(ipcNames.startLive),
  stopLive: () => ipcRenderer.invoke(ipcNames.stopLive),
  liveChunk: (chunk: LiveChunk) => { ipcRenderer.send(ipcNames.liveChunk, chunk); },
  onLiveViewers: (callback: (event: LiveViewerEvent) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, value: LiveViewerEvent) => callback(value);
    ipcRenderer.on(liveViewersEvent, listener);
    return () => ipcRenderer.removeListener(liveViewersEvent, listener);
  },
  startBlur: (matchId: string, mime: string) => ipcRenderer.invoke(ipcNames.startBlur, matchId, mime),
  writeBlurChunk: (jobId: string, chunk: ArrayBuffer) => ipcRenderer.invoke(ipcNames.writeBlurChunk, jobId, chunk),
  endBlur: (jobId: string, reveal = true) => ipcRenderer.invoke(ipcNames.endBlur, jobId, reveal),
  cancelBlur: (jobId: string) => ipcRenderer.invoke(ipcNames.cancelBlur, jobId),
  startDetect: () => ipcRenderer.invoke(ipcNames.startDetect),
  detectFrame: (frame: ArrayBuffer, width: number, height: number, conf: number) => ipcRenderer.invoke(ipcNames.detectFrame, frame, width, height, conf),
  stopDetect: () => ipcRenderer.invoke(ipcNames.stopDetect),
  copyText: (text: string) => ipcRenderer.invoke(ipcNames.copyText, text),
  getRuntimeInfo: () => ipcRenderer.invoke(ipcNames.getRuntimeInfo),
  getEvents: (callback: (status: AppStatus) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, status: AppStatus) => callback(status);
    ipcRenderer.on(appEvent, listener);
    return () => ipcRenderer.removeListener(appEvent, listener);
  },
};

contextBridge.exposeInMainWorld('recordApi', recordApi);
