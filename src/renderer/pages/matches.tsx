import { useEffect, useState, type ReactElement } from 'react';
import { durationText, kindNames, paintText, resultText, ruleName } from '../../shared/nso.js';
import { VideoPlayer } from '../components/player.js';
import { iconSvg } from '../lib/icons.js';
import type { BattleKind, BattleMatch } from '../../shared/types.js';

type StatKey = 'turf' | 'anarchy' | 'private' | 'event' | 'x';

interface StatRow {
  key: StatKey;
  label: string;
  count: number;
  win: number;
  lose: number;
  kill: number;
  death: number;
  special: number;
  paint: number;
}

interface PersonalStats {
  kill: number;
  death: number;
  special: number;
  paint: number;
}

function matchesPage(): ReactElement {
  const [matches, setMatches] = useState<BattleMatch[]>([]);
  const [playing, setPlaying] = useState<BattleMatch>();
  const [showTop, setShowTop] = useState(false);
  const reload = (): void => { void window.recordApi.listMatches().then((list) => setMatches(list.filter((match) => !match.isSalmon && match.kind !== 'salmon'))); };
  useEffect(() => { reload(); }, []);
  useEffect(() => {
    if (!matches.length) { setShowTop(false); return undefined; }
    const host = document.querySelector('.page-host');
    if (!host) return undefined;
    const onScroll = (): void => setShowTop(host.scrollTop > 240);
    onScroll();
    host.addEventListener('scroll', onScroll, { passive: true });
    return () => host.removeEventListener('scroll', onScroll);
  }, [matches.length]);
  const backToTop = (): void => {
    document.querySelector('.page-host')?.scrollTo({ top: 0, behavior: 'smooth' });
  };
  const stats = statRows(matches);

  return (
    <div className="page-body">
      <h2 className="page-title">对局</h2>
      <div className="stat-grid">
        {stats.map((row) => (
          <div className="stat-card" key={row.key}>
            <div className="stat-name">{row.label}</div>
            <div className="stat-count">{row.count} 局</div>
            <div className="stat-line">胜 {row.win} · 负 {row.lose}</div>
            <div className="stat-line">个人 K/D {row.death ? (row.kill / row.death).toFixed(2) : '-'}</div>
            <div className="stat-line">大招 {row.special} · 涂地 {paintText(row.paint)}</div>
          </div>
        ))}
      </div>
      <div className="bind-row">
        <mdui-button variant="text" onClick={reload}>刷新</mdui-button>
      </div>
      {matches.length ? (
        <div className="match-list">
          {matches.map((match) => <MatchRow key={match.matchId} match={match} onPlay={setPlaying} />)}
        </div>
      ) : (
        <div className="empty-tip">暂无对局记录</div>
      )}
      <VideoPlayer match={playing} open={Boolean(playing)} onClose={() => setPlaying(undefined)} />
      {showTop ? (
        <mdui-fab className="top-fab" variant="surface" onClick={backToTop}>
          <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg('top') }} />
        </mdui-fab>
      ) : null}
    </div>
  );
}

export { matchesPage as MatchesPage };

function matchRow(props: { match: BattleMatch; onPlay: (match: BattleMatch) => void }): ReactElement {
  const { match, onPlay } = props;
  const stats = personalStats(match);
  const title = viewTitle(match);
  const state = match.isDisconnected ? '掉线' : resultText(match.result);
  return (
    <div className="match-row">
      <div className="match-main">
        <div className="match-title">{title}</div>
        <div className="match-sub">
          {new Date(match.endAt).toLocaleString('zh-CN')} · {durationText(match.duration)} · {state} · {match.videoPath ? '已录制' : '未录制'}
        </div>
        <div className="match-sub">
          个人 K/D {stats.death ? (stats.kill / stats.death).toFixed(2) : '-'} · 击杀 {stats.kill} · 死亡 {stats.death} · 大招 {stats.special} · 涂地 {paintText(stats.paint)}
        </div>
      </div>
      <div className="match-actions">
        <mdui-button variant="text" disabled={!match.videoPath} onClick={() => onPlay(match)}>播放录像</mdui-button>
        <mdui-button variant="text" disabled={!match.videoPath} onClick={() => void window.recordApi.openMatch(match.matchId)}>打开位置</mdui-button>
        <mdui-button variant="text" disabled={!match.videoPath} onClick={() => void window.recordApi.saveMatch(match.matchId)}>保存录像</mdui-button>
      </div>
    </div>
  );
}

const MatchRow = matchRow;

function viewTitle(match: BattleMatch): string {
  const kind = kindNames[match.kind];
  const rule = ruleName(match.rule);
  return kind === rule ? kind : `${kind} · ${rule}`;
}

function statRows(matches: BattleMatch[]): StatRow[] {
  const categories = [
    { key: 'turf' as const, label: '涂地', kinds: ['regular'] as BattleKind[] },
    { key: 'anarchy' as const, label: '真格', kinds: ['anarchyOpen', 'anarchySeries'] as BattleKind[] },
    { key: 'private' as const, label: '私人比赛', kinds: ['private'] as BattleKind[] },
    { key: 'event' as const, label: '活动比赛', kinds: ['event'] as BattleKind[] },
    { key: 'x' as const, label: 'X比赛', kinds: ['xBattle'] as BattleKind[] },
  ];
  return categories.map((category) => {
    const list = matches.filter((match) => category.kinds.includes(match.kind));
    const totals = list.reduce((value, match) => {
      const personal = personalStats(match);
      return {
        count: value.count + 1,
        win: value.win + (/WIN/i.test(match.result) ? 1 : 0),
        lose: value.lose + (/LOSE|DEEMED_LOSE|EXEMPTED_LOSE/i.test(match.result) ? 1 : 0),
        kill: value.kill + personal.kill,
        death: value.death + personal.death,
        special: value.special + personal.special,
        paint: value.paint + personal.paint,
      };
    }, { count: 0, win: 0, lose: 0, kill: 0, death: 0, special: 0, paint: 0 });
    return { key: category.key, label: category.label, ...totals };
  });
}

function personalStats(match: BattleMatch): PersonalStats {
  const detail = matchDetail(match);
  const myPlayers = asArray(recordValue(detail?.myTeam)?.players);
  const myself = myPlayers.find((value) => Boolean(recordValue(value)?.isMyself));
  if (myself) {
    const player = recordValue(myself);
    const result = recordValue(player?.result);
    const killOrAssist = Number(result?.kill) || 0;
    const assist = Number(result?.assist) || 0;
    return {
      kill: Math.max(0, killOrAssist - assist),
      death: Number(result?.death) || 0,
      special: Number(result?.special) || 0,
      paint: Number(player?.paint) || 0,
    };
  }
  const coop = recordValue(detail?.myResult) ?? asArray(detail?.memberResults).map(recordValue).find((value) => Boolean(recordValue(value?.player)?.isMyself));
  const player = recordValue(coop?.player);
  return {
    kill: Number(coop?.defeatEnemyCount) || 0,
    death: 0,
    special: 0,
    paint: Number(player?.paint) || 0,
  };
}

function matchDetail(match: BattleMatch): Record<string, unknown> | undefined {
  const raw = recordValue(match.rawData);
  const data = recordValue(raw?.data ?? raw);
  return recordValue(data?.vsHistoryDetail ?? data?.coopHistoryDetail ?? data);
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === 'object' ? value as Record<string, unknown> : undefined;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}
