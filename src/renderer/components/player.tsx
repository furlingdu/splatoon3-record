import { useEffect, useRef, useState, type ReactElement } from 'react';
import { dialogLayer } from '../lib/portal.js';
import { useElementEvent } from '../lib/event.js';
import { matchTitle } from '../../shared/nso.js';
import type { BattleMatch } from '../../shared/types.js';

function videoPlayer(props: { match?: BattleMatch; open: boolean; onClose: () => void }): ReactElement {
  const { match, open, onClose } = props;
  const dialogRef = useRef<HTMLElement | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const [url, setUrl] = useState<string>();
  const closeRef = useElementEvent<HTMLElement>('closed', () => onClose());
  const overlayRef = useElementEvent<HTMLElement>('close', () => onClose());

  useEffect(() => {
    const dialog = dialogRef.current;
    if (dialog) (dialog as unknown as { open: boolean }).open = open;
    if (!open) videoRef.current?.pause();
  }, [open]);

  useEffect(() => {
    if (!open || !match) {
      setUrl(undefined);
      return;
    }
    let alive = true;
    void window.recordApi.getVideoUrl(match.matchId).then((value) => { if (alive) setUrl(value); });
    return () => {
      alive = false;
      setUrl(undefined);
    };
  }, [open, match?.matchId]);

  return dialogLayer(
    <mdui-dialog className="player-dialog" ref={(element) => { dialogRef.current = element; closeRef(element); overlayRef(element); }} headline={match ? videoTitle(match) : ''} close-on-overlay-click>
      {url ? (
        <video className="player-video" ref={videoRef} controls autoPlay playsInline src={url} />
      ) : (
        <div className="player-empty">正在准备录像</div>
      )}
      <mdui-button slot="action" variant="text" onClick={onClose}>关闭</mdui-button>
    </mdui-dialog>,
  );
}

export { videoPlayer as VideoPlayer };

function videoTitle(match: BattleMatch): string {
  return matchTitle(match);
}
