import { useEffect, useState, type ReactElement } from 'react';
import { hardwareReady } from '../lib/encode.js';

function encodeHint(props: { width: number; height: number; fps: number }): ReactElement | null {
  const [ready, setReady] = useState<boolean | undefined>(undefined);
  useEffect(() => {
    if (props.width < 2 || props.height < 2) {
      setReady(undefined);
      return undefined;
    }
    let alive = true;
    void hardwareReady(props.width, props.height, props.fps).then((value) => { if (alive) setReady(value); });
    return () => { alive = false; };
  }, [props.width, props.height, props.fps]);
  if (ready === undefined) return <span className="form-hint">录制编码：检测本机编码能力中……</span>;
  if (ready) return <span className="form-hint">录制编码：硬件编码</span>;
  return <span className="form-hint">录制编码：软件编码，该档位在本机没有硬件编码，录制会丢帧，建议改用有硬编的档位</span>;
}

export { encodeHint as EncodeHint };
