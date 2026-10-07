import type { ReactElement } from 'react';
import { StatusPage } from './pages/status.js';
import { BindingPage } from './pages/binding.js';
import { MatchesPage } from './pages/matches.js';
import { GalleryPage } from './pages/gallery.js';
import { LivePage } from './pages/live.js';
import { SettingsPage } from './pages/settings.js';
import { AboutPage } from './pages/about.js';
import type { AppStatus, PageName } from '../shared/types.js';

function pageView(props: { page: PageName; status?: AppStatus }): ReactElement {
  switch (props.page) {
    case 'binding': return <BindingPage status={props.status} />;
    case 'matches': return <MatchesPage />;
    case 'gallery': return <GalleryPage status={props.status} />;
    case 'live': return <LivePage status={props.status} />;
    case 'settings': return <SettingsPage status={props.status} />;
    case 'about': return <AboutPage status={props.status} />;
    default: return <StatusPage status={props.status} />;
  }
}

export { pageView as PageView };
