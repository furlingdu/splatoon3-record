import { useEffect, useRef, useState, type ReactElement } from 'react';
import { snackbar } from 'mdui/functions/snackbar.js';
import { activeStream, previewStream } from '../lib/device.js';
import type { SessionView } from '../lib/session.js';
import type { RecordSettings } from '../../shared/types.js';

function renderPreview(props: { session: SessionView; settings?: RecordSettings; pip?: boolean }): ReactElement {
  const { session, settings } = props;
  const pip = props.pip !== false;
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const [moved, setMoved] = useState(false);
  const live = Boolean(activeStream()) && !session.error;
  const flip = Boolean(settings?.flipVertical);

  useEffect(() => {
    const element = videoRef.current;
    if (!element) return;
    element.srcObject = live ? previewStream() ?? null : null;
  }, [live, session.revision, session.error]);

  useEffect(() => {
    const element = videoRef.current;
    if (!element) return undefined;
    const enter = (): void => setMoved(true);
    const leave = (): void => setMoved(false);
    element.addEventListener('enterpictureinpicture', enter);
    element.addEventListener('leavepictureinpicture', leave);
    return () => {
      element.removeEventListener('enterpictureinpicture', enter);
      element.removeEventListener('leavepictureinpicture', leave);
    };
  }, []);

  const toggleWindow = (): void => {
    const element = videoRef.current;
    if (!element) return;
    const action = document.pictureInPictureElement ? document.exitPictureInPicture() : element.requestPictureInPicture();
    void action.catch(() => snackbar({ message: moved ? '画中画窗口关闭失败' : '无法打开画中画窗口，请先开始采集' }));
  };

  const hint = session.error
    ? session.error
    : !settings?.videoDevice
      ? '未选择采集设备，请到设置页选择采集卡'
      : !live
        ? '正在打开采集设备'
        : '';

  return (
    <div className="preview-box" onDoubleClick={pip ? toggleWindow : undefined}>
      <video className="preview-video" ref={videoRef} style={{ transform: flip ? 'scaleY(-1)' : undefined }} muted playsInline autoPlay />
      {moved ? <div className="preview-placeholder preview-moved">画面已转移到画中画窗口</div> : null}
      {!moved && hint ? <div className="preview-placeholder">{hint}</div> : null}
    </div>
  );
}

export { renderPreview as Preview };
