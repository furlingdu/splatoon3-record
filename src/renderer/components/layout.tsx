import { useEffect, useState, type ReactNode } from 'react';
import { iconSvg } from '../lib/icons.js';
import { useElementEvent } from '../lib/event.js';
import { appName } from '../../shared/constants.js';
import appLogo from '../assets/appIcon.png';
import characterImg from '../assets/character/character.png';
import type { PageName, RecordSettings } from '../../shared/types.js';

export const navItems: { page: PageName; label: string; icon: string }[] = [
  { page: 'status', label: '状态', icon: 'monitor' },
  { page: 'binding', label: '绑定', icon: 'link' },
  { page: 'matches', label: '对局', icon: 'videocam' },
  { page: 'gallery', label: '相册', icon: 'movie' },
  { page: 'live', label: '直播', icon: 'cast' },
  { page: 'settings', label: '设置', icon: 'settings' },
  { page: 'update', label: '更新', icon: 'update' },
  { page: 'about', label: '关于', icon: 'info' },
];

function useNarrowViewport(): boolean {
  const [narrow, setNarrow] = useState(() => window.matchMedia('(max-width: 767px)').matches);
  useEffect(() => {
    const query = window.matchMedia('(max-width: 767px)');
    const onChange = (event: MediaQueryListEvent): void => setNarrow(event.matches);
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }, []);
  return narrow;
}

function renderLayout(props: { page: PageName; onNavigate: (page: PageName) => void; settings?: RecordSettings; children: ReactNode }): ReactNode {
  const { page, onNavigate, settings, children } = props;
  const narrow = useNarrowViewport();
  const [drawerOpen, setDrawerOpen] = useState(() => !window.matchMedia('(max-width: 767px)').matches);
  useEffect(() => { setDrawerOpen(!narrow); }, [narrow]);
  const drawerRef = useElementEvent<HTMLElement>('close', () => setDrawerOpen(false));
  const syncOpen = useElementEvent<HTMLElement>('open', () => setDrawerOpen(true));
  const drawerEvents = (element: HTMLElement | null): void => { drawerRef(element); syncOpen(element); };
  const background = settings?.backgroundPath;
  const dim = Math.max(0, Math.min(100, settings?.backgroundDim ?? 40)) / 100;
  const backgroundStyle = background
    ? { backgroundImage: `linear-gradient(rgba(0,0,0,${dim}), rgba(0,0,0,${dim})), url("s3r-bg://local/bg?v=${encodeURIComponent(background)}")` }
    : undefined;
  return (
    <mdui-layout className="app-layout">
      <div className={background ? 'bg-layer bg-custom' : 'bg-layer'} style={backgroundStyle} />
      <mdui-top-app-bar>
        <img className="bar-logo" src={appLogo} alt="菜单" title="打开/关闭菜单" onClick={() => setDrawerOpen(!drawerOpen)} />
        <div className="bar-title">{appName}</div>
      </mdui-top-app-bar>
      <mdui-navigation-drawer ref={drawerEvents} placement="left" open={drawerOpen} borderless>
        <mdui-list className="drawer-nav">
          {navItems.map((item) => (
            <mdui-list-item key={item.page} rounded active={item.page === page} onClick={() => onNavigate(item.page)}>
              <mdui-icon slot="icon" dangerouslySetInnerHTML={{ __html: iconSvg(item.icon) }} />
              {item.label}
            </mdui-list-item>
          ))}
        </mdui-list>
      </mdui-navigation-drawer>
        <mdui-layout-main className="page-host">{children}</mdui-layout-main>
        {background ? null : <img className="mascot" src={characterImg} alt="" />}
      </mdui-layout>
  );
}

export { renderLayout as Layout };
