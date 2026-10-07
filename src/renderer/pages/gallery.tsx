import { useEffect, useRef, useState, type ReactElement } from 'react';
import { snackbar } from 'mdui/functions/snackbar.js';
import { durationText, kindNames, matchTitle, resultText, ruleName } from '../../shared/nso.js';
import { iconSvg } from '../lib/icons.js';
import { dialogLayer } from '../lib/portal.js';
import { targetChecked, targetValue, restoreSelect, useElementEvent } from '../lib/event.js';
import { cancelBlurJob, startBlurJob, startBlurJobs, useBlurJob, type BlurJobView, type BlurTaskView, type BlurSource } from '../lib/blurjob.js';
import type { AppStatus, BattleKind, BattleMatch, RecordSettings } from '../../shared/types.js';

type KindFilter = 'all' | BattleKind;

function galleryPage(props: { status?: AppStatus }): ReactElement {
  const [matches, setMatches] = useState<BattleMatch[]>([]);
  const [thumbs, setThumbs] = useState<Record<string, string>>({});
  const [kind, setKind] = useState<KindFilter>('all');
  const [hideUnrecorded, setHideUnrecorded] = useState(true);
  const [current, setCurrent] = useState<BattleMatch | undefined>(undefined);
  const [viewerOpen, setViewerOpen] = useState(false);
  const [videoUrl, setVideoUrl] = useState<string>();
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const viewerRef = useRef<HTMLElement | null>(null);
  const deleteRef = useRef<HTMLElement | null>(null);
  const blurRef = useRef<HTMLElement | null>(null);
  const selectRef = useSelectChange((value) => setKind(value as KindFilter));
  const filterRef = useElementEvent<HTMLElement>('change', (event) => setHideUnrecorded(targetChecked(event)));
  const viewerCloseRef = useElementEvent<HTMLElement>('close', () => setViewerOpen(false));
  const blur = useBlurJob();
  const settings: RecordSettings | undefined = props.status?.settings;

  const reload = (): void => { void window.recordApi.listMatches().then((list) => setMatches(list.filter((match) => !match.isSalmon && match.kind !== 'salmon'))); };
  useEffect(() => { reload(); }, []);

  const visible = matches.filter((match) => (kind === 'all' || match.kind === kind) && (!hideUnrecorded || Boolean(match.videoPath)));
  const kinds = [...new Set(matches.map((match) => match.kind))];
  const pickedList = visible.filter((match) => picked.has(match.matchId) && match.videoPath);

  useEffect(() => {
    for (const match of visible) {
      if (match.videoPath && !(match.matchId in thumbs)) {
        void window.recordApi.thumb(match.matchId).then((url) => setThumbs((prev) => ({ ...prev, [match.matchId]: url || '' })));
      }
    }
  }, [visible, thumbs]);

  useEffect(() => {
    if (!viewerOpen || !current?.videoPath) {
      setVideoUrl(undefined);
      return;
    }
    let alive = true;
    void window.recordApi.getVideoUrl(current.matchId).then((value) => { if (alive) setVideoUrl(value); });
    return () => { alive = false; };
  }, [viewerOpen, current?.matchId]);

  const openViewer = (match: BattleMatch): void => {
    if (!match.videoPath) {
      snackbar({ message: '此对局未录制' });
      return;
    }
    setCurrent(match);
    setViewerOpen(true);
    if (viewerRef.current) (viewerRef.current as HTMLDialogElement).open = true;
  };
  const closeViewer = (): void => {
    setViewerOpen(false);
    if (viewerRef.current) (viewerRef.current as HTMLDialogElement).open = false;
  };
  const openDelete = (): void => {
    closeViewer();
    if (deleteRef.current) (deleteRef.current as HTMLDialogElement).open = true;
  };
  const closeDelete = (): void => { if (deleteRef.current) (deleteRef.current as HTMLDialogElement).open = false; };
  const openBlurDialog = (): void => {
    closeViewer();
    if (blurRef.current) (blurRef.current as HTMLDialogElement).open = true;
  };
  const openBlur = (): void => {
    const match = current;
    if (!match?.videoPath || !videoUrl) {
      snackbar({ message: '该对局没有可用的录像文件' });
      return;
    }
    if (!settings) return;
    openBlurDialog();
    void startBlurJob(match.matchId, videoUrl, settings).catch((cause) => snackbar({ message: errorOf(cause) }));
  };
  const openBatch = (): void => {
    if (!settings || !pickedList.length) {
      snackbar({ message: '请先勾选需要打码的对局' });
      return;
    }
    openBlurDialog();
    void startBatch(pickedList, settings).catch((cause) => snackbar({ message: errorOf(cause) }));
  };
  const startBatch = async (list: BattleMatch[], next: RecordSettings): Promise<void> => {
    const sources: BlurSource[] = [];
    for (const match of list) {
      const url = await window.recordApi.getVideoUrl(match.matchId);
      if (url) sources.push({ matchId: match.matchId, videoUrl: url });
    }
    if (!sources.length) {
      snackbar({ message: '所选对局没有可用的录像文件' });
      return;
    }
    await startBlurJobs(sources, next);
  };
  const togglePick = (matchId: string): void => {
    setPicked((prev) => {
      const next = new Set(prev);
      if (next.has(matchId)) next.delete(matchId);
      else next.add(matchId);
      return next;
    });
  };
  const closeBlur = (): void => {
    const lastOutput = blur.output;
    if (blur.running) void cancelBlurJob();
    if (blurRef.current) (blurRef.current as HTMLDialogElement).open = false;
    if (lastOutput) void window.recordApi.openPath(lastOutput);
  };
  const openBlurOutput = (): void => {
    if (blur.output) void window.recordApi.openPath(blur.output);
  };
  const removeThumb = (matchId: string): void => {
    setThumbs((prev) => {
      const next = { ...prev };
      delete next[matchId];
      return next;
    });
  };

  return (
    <div className="page-body">
      <h2 className="page-title">相册</h2>
      <div className="bind-row">
        <mdui-select label="比赛类型" value={kind} ref={selectRef}>
          <mdui-menu-item value="all">全部类型</mdui-menu-item>
          {kinds.map((item) => <mdui-menu-item key={item} value={item}>{kindNames[item]}</mdui-menu-item>)}
        </mdui-select>
        <mdui-checkbox checked={hideUnrecorded} ref={filterRef}>不显示未录制对局</mdui-checkbox>
        <mdui-button variant="text" onClick={reload}>刷新</mdui-button>
        <mdui-button variant="tonal" disabled={!pickedList.length} onClick={openBatch}>
          <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('blur') }} />
          批量打码 {pickedList.length || ''}
        </mdui-button>
      </div>
      {visible.length ? (
        <div className="gallery-grid">
          {visible.map((match) => (
            <GalleryCard key={match.matchId} match={match} thumb={thumbs[match.matchId]} picked={picked.has(match.matchId)} onPick={togglePick} onOpen={openViewer} />
          ))}
        </div>
      ) : (
        <div className="empty-tip">暂无对局录像</div>
      )}

      {dialogLayer(
        <>
          <mdui-dialog ref={(element) => { viewerRef.current = element; viewerCloseRef(element); }} close-on-overlay-click headline={current ? viewerTitle(current) : ''}>
            {current ? (
              <div className="viewer-body">
                <div className="viewer-thumb">
                  {videoUrl
                    ? <video className="viewer-video" controls autoPlay playsInline src={videoUrl} />
                    : <div className="viewer-empty"><mdui-icon dangerouslySetInnerHTML={{ __html: iconSvg('movie') }} />正在准备录像</div>}
                </div>
                <div className="status-grid viewer-info">
                  <span className="status-label">结果</span><span className="status-value">{current.isDisconnected ? '掉线' : resultText(current.result)}</span>
                  <span className="status-label">结束时间</span><span className="status-value">{new Date(current.endAt).toLocaleString('zh-CN')}</span>
                  <span className="status-label">持续时间</span><span className="status-value">{durationText(current.duration)}</span>
                </div>
              </div>
            ) : null}
            <mdui-button slot="action" variant="text" disabled={!current?.videoPath} onClick={openBlur}>
              <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('blur') }} />
              昵称打码
            </mdui-button>
            <mdui-button slot="action" variant="text" disabled={!current?.videoPath}
              onClick={() => { if (current) void window.recordApi.openMatch(current.matchId); }}>
              <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('folder') }} />
              打开位置
            </mdui-button>
            <mdui-button slot="action" variant="text" onClick={openDelete}>
              <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('delete') }} />
              删除
            </mdui-button>
          </mdui-dialog>

          <mdui-dialog ref={blurRef} headline="昵称打码" description="将按原速重放所选录像逐帧识别昵称并做高斯模糊，处理完成后自动打开文件所在位置。">
            <div className="blur-body">
              <span className="status-value">{blurHeadline(blur)}</span>
              {blur.running ? <mdui-linear-progress value={blur.progress} /> : null}
              {blur.tasks.length > 1 ? (
                <div className="blur-tasks">
                  {blur.tasks.map((task) => (
                    <div className="blur-task" key={task.id}>
                      <span className="blur-task-name">{task.matchId}</span>
                      <span className="blur-task-state">{taskStateText(task)}</span>
                    </div>
                  ))}
                </div>
              ) : null}
              {blur.error ? <span className="status-value blur-error">{blur.error}</span> : null}
            </div>
            {blur.running ? (
              <mdui-button slot="action" variant="text" onClick={closeBlur}>取消</mdui-button>
            ) : (
              <>
                {blur.output ? (
                  <mdui-button slot="action" variant="tonal" onClick={openBlurOutput}>
                    <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('folder') }} />
                    打开文件夹
                  </mdui-button>
                ) : null}
                <mdui-button slot="action" variant="filled" onClick={closeBlur}>关闭</mdui-button>
              </>
            )}
          </mdui-dialog>

          <mdui-dialog ref={deleteRef} headline="删除录像" description="将同时删除归档视频与比赛记录，确定删除？">
            <mdui-button slot="action" variant="text" onClick={closeDelete}>取消</mdui-button>
            <mdui-button slot="action" variant="filled" onClick={() => {
              if (current) removeThumb(current.matchId);
              closeDelete();
              void window.recordApi.deleteMatch(current?.matchId || '').then(reload);
            }}>删除</mdui-button>
          </mdui-dialog>
        </>,
      )}
    </div>
  );
}

export { galleryPage as GalleryPage };

function blurHeadline(view: BlurJobView): string {
  if (view.running) return `正在打码 ${Math.min(view.done + 1, view.total)}/${view.total}`;
  if (view.error) return '打码失败';
  if (view.output) return '打码完成';
  return '准备中';
}

function taskStateText(task: BlurTaskView): string {
  if (task.error) return task.error;
  if (task.output) return '已完成';
  return `${Math.round(task.progress * 100)}%`;
}

function errorOf(cause: unknown, fallback = '昵称打码失败'): string {
  const text = (cause instanceof Error ? cause.message : String(cause ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || fallback;
}

function viewerTitle(match: BattleMatch): string {
  return matchTitle(match);
}

function galleryCard(props: { match: BattleMatch; thumb?: string; picked: boolean; onPick: (matchId: string) => void; onOpen: (match: BattleMatch) => void }): ReactElement {
  const { match, thumb, picked, onPick, onOpen } = props;
  const win = /WIN/i.test(match.result);
  const pickRef = useElementEvent<HTMLElement>('change', () => onPick(match.matchId));
  return (
    <div className="gallery-card" onClick={() => onOpen(match)}>
      <div className="gallery-thumb">
        {thumb
          ? <img src={thumb} alt={`${kindNames[match.kind]}缩略图`} loading="lazy" />
          : <div className="gallery-placeholder"><mdui-icon dangerouslySetInnerHTML={{ __html: iconSvg('movie') }} /></div>}
        {match.videoPath ? (
          <mdui-checkbox className="gallery-pick" checked={picked} ref={pickRef}
            onClick={(event) => event.stopPropagation()}>{''}</mdui-checkbox>
        ) : null}
        <span className={`gallery-result ${match.isDisconnected || !win ? 'is-lose' : 'is-win'}`}>{match.isDisconnected ? '掉线' : resultText(match.result)}</span>
        {match.duration ? <span className="gallery-duration">{durationText(match.duration)}</span> : null}
      </div>
      <div className="gallery-info">
        <div className="gallery-mode">{kindNames[match.kind]}</div>
        <div className="gallery-sub">{ruleName(match.rule)} · {new Date(match.endAt).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })}</div>
      </div>
    </div>
  );
}

const GalleryCard = galleryCard;

function useSelectChange(onChange: (value: string) => void): (element: HTMLElement | null) => void {
  const bound = useRef<WeakSet<HTMLElement>>(new WeakSet());
  return (element) => {
    if (!element || bound.current.has(element)) return;
    bound.current.add(element);
    element.addEventListener('change', (event) => {
      const data = targetValue(event);
      if (data === '') {
        restoreSelect(event);
        return;
      }
      onChange(data);
    });
  };
}
