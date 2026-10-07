import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import puppeteer from 'puppeteer';
import { createMockStatus, findChrome, installMock, mockMatches, siteDir, startServer } from './uiMock.js';

const failures = [];
const checks = [];

function check(name, condition) {
  checks.push({ name, pass: Boolean(condition) });
  if (!condition) failures.push(name);
  console.log(`${condition ? 'PASS' : 'FAIL'} ${name}`);
}

function waitText(page, text) {
  return page.waitForFunction((value) => document.body.innerText.includes(value), { timeout: 10000 }, text).then(() => true).catch(() => false);
}

function clickText(page, selector, text) {
  return page.evaluate((sel, value) => {
    const element = Array.from(document.querySelectorAll(sel)).find((node) => (node.textContent || '').includes(value));
    if (!element) return false;
    element.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
    return true;
  }, selector, text);
}

function clickNav(page, index) {
  return page.evaluate((position) => {
    const item = document.querySelectorAll('mdui-navigation-drawer mdui-list-item')[position];
    item?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
  }, index);
}

function setValue(page, selector, value) {
  return page.evaluate((sel, next) => {
    const element = document.querySelector(sel);
    if (!element) return false;
    element.value = next;
    element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
    return true;
  }, selector, value);
}

function setChecked(page, selector, value) {
  return page.evaluate((sel, next) => {
    const element = document.querySelector(sel);
    if (!element) return false;
    element.checked = next;
    element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
    return true;
  }, selector, value);
}

function live(page) {
  return page.waitForFunction(() => document.querySelector('.preview-video')?.srcObject instanceof MediaStream, { timeout: 10000 }).then(() => true).catch(() => false);
}

async function doubleClick(page, point) {
  await page.mouse.move(point.x, point.y);
  await page.mouse.down({ clickCount: 1 });
  await page.mouse.up({ clickCount: 1 });
  await page.mouse.down({ clickCount: 2 });
  await page.mouse.up({ clickCount: 2 });
}

async function clickNavReal(page, index, title) {
  const point = await page.evaluate((position) => {
    const item = document.querySelectorAll('mdui-navigation-drawer mdui-list-item')[position];
    const rect = item?.getBoundingClientRect();
    return rect ? { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 } : null;
  }, index);
  if (!point) return false;
  await page.mouse.click(point.x, point.y);
  return page.waitForFunction((value) => document.querySelector('.page-title')?.textContent === value, { timeout: 5000 }, title).then(() => true).catch(() => false);
}

async function main() {
  const { server, port } = await startServer();
  const builtHtml = await readFile(join(siteDir, 'index.html'), 'utf8');
  const assetNames = readdirSync(join(siteDir, 'assets')).filter((name) => name.endsWith('.css'));
  const assetTexts = await Promise.all(assetNames.map((name) => readFile(join(siteDir, 'assets', name), 'utf8')));
  check('构建产物包含居中启动层', builtHtml.includes('id="boot"') && builtHtml.includes('class="boot-layer"'));
  check('构建产物包含启动层样式', assetTexts.some((text) => text.includes('.boot-layer') && text.includes('.boot-logo')));
  check('构建产物包含页面切换动画', assetTexts.some((text) => text.includes('.page-transition-wrapper') && text.includes('pageEnter')));
  check('构建产物不含旧后端进程代码', !assetTexts.some((text) => text.includes('s3rCapture')) && builtHtml.includes('type="module"'));
  check('构建产物保留布局容器类名', assetTexts.some((text) => text.includes('.app-layout')) && assetTexts.some((text) => text.includes('.app-layout mdui-navigation-drawer')));
  check('构建产物固定深色主题', builtHtml.includes('mdui-theme-dark') && !builtHtml.includes('mdui-theme-auto'));

  const userDataDir = await mkdtemp(join(tmpdir(), 's3recordUi'));
  const browser = await puppeteer.launch({
    headless: 'new',
    userDataDir,
    executablePath: await findChrome(),
    args: ['--no-first-run', '--disable-extensions', '--autoplay-policy=no-user-gesture-required', '--mute-audio'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1360, height: 860 });
  await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }]);
  await installMock(page, createMockStatus(), mockMatches);
  page.on('console', (message) => {
    const text = message.text();
    if (message.type() === 'error' && !text.includes('ERR_UNKNOWN_URL_SCHEME')) console.log('  [renderer]', text);
  });
  await page.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil: 'networkidle0' });

  await page.waitForSelector('mdui-top-app-bar', { timeout: 15000 });
  check('顶栏渲染', await page.evaluate(() => document.querySelector('mdui-top-app-bar') !== null));
  check('浅色系统下界面仍为深色', await page.evaluate(() => {
    const value = getComputedStyle(document.documentElement).getPropertyValue('--mdui-color-background').trim();
    const [red, green, blue] = value.split(',').map((part) => Number(part));
    return document.documentElement.classList.contains('mdui-theme-dark') && (red + green + blue) / 3 < 60;
  }));
  check('启动层在主界面就绪后移除', await page.waitForFunction(() => !document.getElementById('boot'), { timeout: 5000 }).then(() => true).catch(() => false));
  check('吉祥物首屏可见', await page.evaluate(() => {
    const mascot = document.querySelector('.mascot');
    if (!mascot) return false;
    const rect = mascot.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0 && rect.top < window.innerHeight && rect.left < window.innerWidth;
  }));
  check('侧边栏渲染七个菜单项', await page.evaluate(() => document.querySelectorAll('mdui-navigation-drawer mdui-list-item').length === 7));
  check('布局容器使用样式表定义的类名', await page.evaluate(() => Boolean(document.querySelector('mdui-layout.app-layout'))));
  check('滚动页面时侧边栏不跟随滚动', await page.evaluate(async () => {
    const drawer = document.querySelector('mdui-navigation-drawer');
    const host = document.querySelector('.page-host');
    const before = drawer.getBoundingClientRect().top;
    window.scrollBy(0, 600);
    if (host) host.scrollTop = 600;
    await new Promise((resolve) => requestAnimationFrame(resolve));
    const moved = Math.abs(drawer.getBoundingClientRect().top - before) > 1;
    if (host) host.scrollTop = 0;
    window.scrollTo(0, 0);
    return !moved;
  }));
  check('侧边栏菜单项未被内容区遮挡', await page.evaluate(() => {
    const item = document.querySelectorAll('mdui-navigation-drawer mdui-list-item')[1];
    const rect = item?.getBoundingClientRect();
    if (!rect || !rect.width) return false;
    const top = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
    return Boolean(top) && (top === item || item.contains(top));
  }));
  check('侧边栏可用鼠标真实点击切换页面', await clickNavReal(page, 1, '绑定'));
  await clickNav(page, 0);
  check('回到状态页', await page.waitForFunction(() => document.querySelector('.page-title')?.textContent === '状态', { timeout: 5000 }).then(() => true).catch(() => false));

  check('状态页预览绑定采集流', await live(page));
  check('采集流直接来自浏览器设备接口', await page.evaluate(() => {
    const stream = document.querySelector('.preview-video')?.srcObject;
    const track = stream?.getVideoTracks?.()[0];
    return Boolean(track) && track.kind === 'video' && stream.getTracks().every((item) => item.readyState === 'live');
  }));
  check('采集流同时携带视频与音频轨', await page.evaluate(() => {
    const streams = window.__ui.streams || [];
    const stream = streams[streams.length - 1];
    const tracks = stream?.getTracks?.() ?? [];
    const shown = document.querySelector('.preview-video')?.srcObject?.getVideoTracks?.()[0];
    const video = tracks.find((item) => item.kind === 'video');
    return tracks.some((item) => item.kind === 'audio') && Boolean(video) && Boolean(shown) && shown.id === video.id;
  }));
  check('状态页显示分辨率', await waitText(page, '1920 x 1080'));
  check('状态页显示编码器', await waitText(page, 'hevc_amf'));
  check('状态页显示硬件解码档位', await waitText(page, 'CUDA'));
  check('状态页显示最近对局类型', await waitText(page, '占地对战'));
  check('状态页显示对局正在保存', await waitText(page, '正在保存'));
  check('状态页不提供设备选择', await page.evaluate(() => !document.querySelector('mdui-select[name="videoDevice"]') && !document.querySelector('mdui-select[name="audioDevice"]')));
  check('状态页直接显示内嵌预览', await page.waitForSelector('.preview-video', { timeout: 5000 }).then(() => true).catch(() => false));
  const pipPoint = await page.evaluate(() => {
    const rect = document.querySelector('.preview-box')?.getBoundingClientRect();
    return rect ? { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 } : null;
  });
  check('状态页预览区可双击', Boolean(pipPoint));
  if (pipPoint) {
    await doubleClick(page, pipPoint);
    check('双击预览把画面交给画中画窗口', await page.waitForFunction(() => {
      const video = document.querySelector('.preview-video');
      return Boolean(video) && document.pictureInPictureElement === video;
    }, { timeout: 5000 }).then(() => true).catch(() => false));
    check('画中画打开时主画面关掉并保留采集流', await page.waitForFunction(() => {
      const notice = document.querySelector('.preview-moved');
      const video = document.querySelector('.preview-video');
      return Boolean(notice) && notice.textContent?.includes('画面已转移到画中画窗口') && video?.srcObject instanceof MediaStream;
    }, { timeout: 5000 }).then(() => true).catch(() => false));
    await doubleClick(page, pipPoint);
    check('再次双击关闭画中画并恢复预览', await page.waitForFunction(() => !document.pictureInPictureElement && !document.querySelector('.preview-moved'), { timeout: 5000 }).then(() => true).catch(() => false));
  }
  check('画中画关闭后预览仍绑定采集流', await live(page));
  check('状态页不提供录制参数修改', await page.evaluate(() => {
    const editors = document.querySelectorAll('mdui-select[name="width"], mdui-select[name="fps"], mdui-switch[name="flipVertical"]');
    const titles = Array.from(document.querySelectorAll('.section-title')).map((item) => item.textContent || '');
    return editors.length === 0 && !titles.includes('录制参数');
  }));
  check('状态页不再提示录制参数在设置页修改', await page.evaluate(() => !document.body.innerText.includes('录制参数在设置页修改') && !document.body.innerText.includes('录制状态') && !document.body.innerText.includes('实际分辨率') && !document.body.innerText.includes('实际帧率') && !document.body.innerText.includes('缓存分段')));
  check('状态页停止录制旁提供预览窗口按钮', await page.evaluate(() => {
    const actions = document.querySelector('.status-actions');
    if (!actions) return false;
    const buttons = Array.from(actions.querySelectorAll('mdui-button'));
    const stop = buttons.findIndex((element) => element.textContent?.includes('停止录制'));
    const preview = buttons[stop + 1];
    const hasMonitor = Array.from(actions.children).some((element) => element.textContent?.includes('声音返听'));
    return stop >= 0 && Boolean(preview?.textContent?.includes('打开预览窗口'))
      && preview.getAttribute('variant') === 'filled'
      && preview.disabled === false && hasMonitor;
  }));
  await clickText(page, '.status-actions mdui-button', '打开预览窗口');
  check('状态页预览窗口按钮调用主进程', await page.evaluate(() => window.__ui.calls.openPreview === 1));
  await setChecked(page, 'mdui-switch[name="monitorAudio"]', true);
  check('声音返听开关写回设置', await page.waitForFunction(() => window.__ui.lastSettings?.monitorAudio === true, { timeout: 5000 }).then(() => true).catch(() => false));
  check('声音返听绑定采集音频流', await page.waitForFunction(() => {
    const monitor = window.__monitor;
    return Boolean(monitor) && monitor.on && monitor.bound && monitor.state === 'running';
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  await clickNav(page, 5);
  check('切换标签页后声音返听继续播放', await page.evaluate(() => {
    const monitor = window.__monitor;
    return Boolean(monitor) && monitor.on && monitor.bound && monitor.state === 'running';
  }));
  await page.evaluate(() => window.__patchSettings({ monitorAudio: false }));
  check('关闭返听后停止播放', await page.waitForFunction(() => {
    const monitor = window.__monitor;
    return Boolean(monitor) && !monitor.on && !monitor.bound;
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  await page.evaluate(() => window.__patchSettings({ monitorAudio: true }));
  check('离开状态页也能按持久化设置恢复返听', await page.waitForFunction(() => {
    const monitor = window.__monitor;
    return Boolean(monitor) && monitor.on && monitor.bound && monitor.state === 'running';
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  await clickNav(page, 0);
  check('返回状态页声音返听开关保持开启', await page.waitForFunction(() => document.querySelector('mdui-switch[name="monitorAudio"]')?.checked === true, { timeout: 5000 }).then(() => true).catch(() => false));
  check('状态页不显示独立调试导出入口', await page.evaluate(() => {
    const hasDebugButton = Array.from(document.querySelectorAll('.status-actions mdui-button')).some((element) => element.textContent?.includes('Debug'));
    return !hasDebugButton && !document.body.innerText.includes('按住 Shift');
  }));

  await page.evaluate(() => window.__patchSettings({ width: 1280, height: 720 }));
  check('状态页跟随设置切换实际画幅', await page.waitForFunction(() => {
    const report = window.__ui.reports[window.__ui.reports.length - 1];
    return Boolean(report) && report.width === 1280 && report.height === 720;
  }, { timeout: 10000 }).then(() => true).catch(() => false));
  check('状态页显示切换后的实际分辨率', await waitText(page, '1280 x 720'));
  check('状态页画幅生效后不显示未接受提示', await page.evaluate(() => !(document.body.innerText || '').includes('采集卡未接受设置页的分辨率')));

  const opened = await page.evaluate(() => (window.__ui.streams || []).length);
  await page.evaluate(() => { window.__ui.blockApply = true; });
  await page.evaluate(() => window.__patchSettings({ width: 960, height: 540 }));
  check('采集卡拒绝就地改画幅时重建采集', await page.waitForFunction(() => {
    const report = window.__ui.reports[window.__ui.reports.length - 1];
    return Boolean(report) && report.width === 960 && report.height === 540;
  }, { timeout: 10000 }).then(() => true).catch(() => false));
  check('重建采集会重新打开设备', await page.evaluate((before) => (window.__ui.streams || []).length > before, opened));
  await page.evaluate(() => { window.__ui.blockApply = false; });
  await page.evaluate(() => window.__patchSettings({ width: 1280, height: 720, fps: 30 }));
  check('状态页显示切换后的实际帧率', await page.waitForFunction(() => {
    const report = window.__ui.reports[window.__ui.reports.length - 1];
    const item = Array.from(document.querySelectorAll('.status-row')).find((node) => node.querySelector('.status-label')?.textContent === '帧率');
    const value = Number.parseFloat(item?.querySelector('.status-value')?.textContent || '');
    return Boolean(report) && Math.abs(Number(report.fps) - 30) <= 1 && Number.isFinite(value) && Math.abs(value - 30) <= 1;
  }, { timeout: 10000 }).then(() => true).catch(() => false));

  await page.evaluate(() => window.__patchSettings({ flipVertical: true }));
  check('状态页预览跟随设置垂直翻转', await page.waitForFunction(() => {
    const video = document.querySelector('.preview-video');
    return Boolean(video) && (video.style.transform || '').includes('scaleY(-1)');
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  await page.evaluate(() => window.__patchSettings({ flipVertical: false }));

  await page.evaluate(() => window.__patchSettings({ videoDevice: 'cam2', width: 1920, height: 1080 }));
  check('状态页在采集卡拒绝配置分辨率时提示未接受', await waitText(page, '采集卡未接受设置页的分辨率'));
  await page.evaluate(() => window.__patchSettings({ videoDevice: 'obs1', width: 1280, height: 720, fps: 30 }));
  check('换回采集卡后未接受提示消失', await page.evaluate(() => !(document.body.innerText || '').includes('采集卡未接受设置页的分辨率')));
  const switchBefore = await page.evaluate(() => (window.__ui.streams || []).length);
  await page.evaluate(() => window.__patchSettings({ videoDevice: 'cam2', width: 1280, height: 720, fps: 30 }));
  check('切换摄像头后预览绑定新采集流', await page.waitForFunction(() => {
    const shown = document.querySelector('.preview-video')?.srcObject?.getVideoTracks?.()[0];
    return Boolean(shown) && (window.__ui.streams || []).some((stream) => stream.__tag?.deviceId === 'cam2' && stream.getVideoTracks()[0]?.id === shown.id);
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  check('切换摄像头会重新打开设备', await page.evaluate((before) => (window.__ui.streams || []).length > before, switchBefore));
  await page.evaluate(() => window.__patchSettings({ videoDevice: 'obs1', width: 1280, height: 720, fps: 30 }));
  check('切回采集卡后预览跟随绑定', await page.waitForFunction(() => {
    const shown = document.querySelector('.preview-video')?.srcObject?.getVideoTracks?.()[0];
    return Boolean(shown) && (window.__ui.streams || []).some((stream) => stream.__tag?.deviceId === 'obs1' && stream.getVideoTracks()[0]?.id === shown.id);
  }, { timeout: 5000 }).then(() => true).catch(() => false));

  await clickText(page, '.status-actions mdui-button', '开始录制');
  check('开始录制后进入录制中', await page.waitForFunction(() => window.__ui.reports.some((report) => report.recordState === 'recording'), { timeout: 10000 }).then(() => true).catch(() => false));
  check('状态页显示录制提示', await waitText(page, '正在录制对局中……'));
  check('录制中预览保持显示', await page.evaluate(() => {
    const video = document.querySelector('.preview-video');
    return Boolean(video && video.srcObject instanceof MediaStream);
  }));
  check('录制期间上报采集规格', await page.evaluate(() => window.__ui.reports.some((report) => report.recordState === 'recording' && report.width === 1280 && report.height === 720)));
  check('录制期间切片写入缓存', await page.waitForFunction(() => window.__ui.chunks.length > 0, { timeout: 45000 }).then(() => true).catch(() => false));
  check('切片内容非空并带分段编号', await page.evaluate(() => window.__ui.chunks.every((chunk) => chunk.size > 0 && /^seg/.test(chunk.id))));
  await clickText(page, '.status-actions mdui-button', '停止录制');
  check('停止录制后分段入库', await page.waitForFunction(() => window.__ui.segments.length > 0, { timeout: 10000 }).then(() => true).catch(() => false));
  check('入库分段带完整规格与真实时长', await page.evaluate(() => {
    const draft = window.__ui.segments[0];
    const chunk = window.__ui.chunks.find((item) => item.id === draft.id);
    return Boolean(chunk) && draft.endAt > draft.startAt && draft.width === 1280 && draft.height === 720
      && draft.fps === 30 && draft.hasAudio === true && /^(mp4|mkv|webm)$/.test(draft.ext);
  }));
  check('停止后回到空闲状态', await page.waitForFunction(() => window.__ui.reports.some((report) => report.recordState === 'idle'), { timeout: 10000 }).then(() => true).catch(() => false));

  await page.evaluate(() => { window.__ui.missingDevice = 'cam2'; window.__patchSettings({ videoDevice: 'cam2' }); });
  check('设备缺失时显示采集错误', await page.waitForFunction(() => document.querySelector('.preview-placeholder')?.textContent?.includes('Requested device not found'), { timeout: 10000 }).then(() => true).catch(() => false));
  check('采集失败时提供重试入口', await page.evaluate(() => Boolean(document.querySelector('.status-actions')) && Array.from(document.querySelectorAll('.status-actions mdui-button')).some((element) => element.textContent?.includes('重试采集'))));
  await page.evaluate(() => { window.__ui.missingDevice = null; });
  await clickText(page, '.status-actions mdui-button', '重试采集');
  check('重试采集后画面恢复', await live(page));

  await page.evaluate(() => window.__patchSettings({ videoDevice: 'OBS Virtual Camera', audioDevice: 'Audio 1' }));
  check('配置存设备名时解析到真实设备标识', await page.waitForFunction(() => window.__ui.lastConstraints?.video?.deviceId?.exact === 'obs1' && window.__ui.lastConstraints?.audio?.deviceId?.exact === 'audio1', { timeout: 10000 }).then(() => true).catch(() => false));
  check('设备名解析后不再提示采集错误', await page.evaluate(() => !document.querySelector('.preview-placeholder')?.textContent?.includes('Requested device not found')));

  await page.evaluate(() => window.__patchSettings({ videoDevice: 'obs1' }));

  const unknownMain = await page.evaluate(() => window.__ui.unknown.slice());
  check('主界面只调用白名单桥接方法', unknownMain.length === 0);
  check('渲染进程不再调用旧后端接口', !unknownMain.includes('startRecord') && !unknownMain.includes('startPreview') && !unknownMain.includes('listDevices'));
  check('状态页只上报采集规格不改录制参数', await page.evaluate(() => {
    const recordOnly = (settings) => {
      const next = { ...settings };
      delete next.monitorAudio;
      return JSON.stringify(next);
    };
    const base = recordOnly(window.__ui.baseSettings);
    return (window.__ui.reports || []).length > 0 && window.__ui.calls.writeSegment > 0 && (window.__ui.settingsWrites || []).every((item) => recordOnly(item) === base);
  }));

  await clickNav(page, 2);
  check('切换到对局页', (await waitText(page, '对局')) && await page.evaluate(() => document.querySelectorAll('.match-list .match-row').length) === 3);
  check('页面切换播放进入动画', await page.evaluate(() => {
    const wrapper = document.querySelector('.page-host .page-transition-wrapper');
    if (!wrapper) return false;
    const style = getComputedStyle(wrapper);
    return style.animationName === 'pageEnter' && style.animationDuration === '0.3s';
  }));
  check('对局统计显示', (await waitText(page, '真格')) && await waitText(page, '涂地'));
  check('对局页不显示鲑鱼跑', await page.evaluate(() => !document.body.innerText.includes('鲑鱼跑')));
  check('对局快捷按钮', await page.evaluate(() => document.querySelectorAll('.match-actions mdui-button').length >= 3));
  check('对局页未滚动时不显示返回顶部按钮', await page.evaluate(() => document.querySelector('.top-fab') === null));
  await page.setViewport({ width: 1360, height: 520 });
  await page.evaluate(() => { document.querySelector('.page-host')?.scrollTo({ top: 900 }); });
  check('对局页下滑后显示原版样式的返回顶部按钮', await page.waitForFunction(() => {
    const fab = document.querySelector('.top-fab');
    return Boolean(fab) && fab.tagName.toLowerCase() === 'mdui-fab' && fab.getAttribute('variant') === 'surface' && Boolean(fab.querySelector('svg'));
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  await page.evaluate(() => {
    const fab = document.querySelector('.top-fab');
    fab?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
  });
  check('点击返回顶部按钮回到列表顶部并隐藏按钮', await page.waitForFunction(() => {
    const host = document.querySelector('.page-host');
    return Boolean(host) && host.scrollTop <= 240 && document.querySelector('.top-fab') === null;
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  await page.setViewport({ width: 1360, height: 860 });
  await clickText(page, '.match-actions mdui-button', '播放录像');
  check('对局页弹窗内播放录像', await page.waitForSelector('.player-video', { timeout: 5000 }).then(() => true).catch(() => false));
  check('对局弹窗地址指向录像文件', await page.evaluate(() => String(document.querySelector('.player-video')?.getAttribute('src') || '').startsWith('s3r-video://match/')));

  await clickNav(page, 3);
  check('相册默认过滤未录制对局', (await waitText(page, '相册')) && await page.evaluate(() => {
    const box = document.querySelector('mdui-checkbox');
    return Boolean(box) && box.checked === true && document.querySelectorAll('.gallery-card').length === 2;
  }));
  await page.click('mdui-checkbox').catch(() => undefined);
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('取消过滤后显示未录制对局', await page.evaluate(() => document.querySelectorAll('.gallery-card').length === 3 && !document.body.innerText.includes('鲑鱼跑')));
  check('相册显示掉线标记', await waitText(page, '掉线'));
  await page.evaluate(() => {
    const card = Array.from(document.querySelectorAll('.gallery-card')).find((element) => element.textContent?.includes('X对战'));
    card?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
  });
  check('未录制对局点击提示且不弹窗', (await waitText(page, '此对局未录制')) && await page.evaluate(() => document.querySelector('.viewer-body') === null));
  await page.evaluate(() => {
    const card = Array.from(document.querySelectorAll('.gallery-card')).find((element) => element.textContent?.includes('占地对战'));
    card?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
  });
  check('相册可打开浏览对话框', await waitText(page, '结束时间'));
  check('相册弹窗标题为模式与结束时间', await page.evaluate(() => {
    const dialog = Array.from(document.querySelectorAll('mdui-dialog')).find((element) => element.querySelector('.viewer-body'));
    const headline = dialog?.getAttribute('headline') || '';
    return headline.startsWith('占地对战-')
      && /\d{4}\/\d{1,2}\/\d{1,2}\s+\d{1,2}:\d{2}:\d{2}/.test(headline)
      && !headline.includes('[') && !headline.includes(']');
  }));
  check('相册弹窗直接内嵌录像播放', await page.waitForSelector('.viewer-body .viewer-video', { timeout: 5000 }).then(() => true).catch(() => false));
  check('相册弹窗地址指向录像文件', await page.evaluate(() => String(document.querySelector('.viewer-body .viewer-video')?.getAttribute('src') || '').startsWith('s3r-video://match/')));
  check('相册弹窗不显示录像文件路径', await page.evaluate(() => {
    const body = document.querySelector('.viewer-body');
    return Boolean(body) && !(body.textContent || '').includes('录像文件') && !(body.textContent || '').includes('.mp4');
  }));
  check('相册弹窗层级高于顶栏与侧边栏', await page.evaluate(() => {
    const dialog = Array.from(document.querySelectorAll('mdui-dialog')).find((element) => element.querySelector('.viewer-body'));
    if (!dialog) return false;
    const above = (target) => {
      const box = target.getBoundingClientRect();
      const stack = document.elementsFromPoint(box.left + box.width / 2, box.top + box.height / 2);
      const index = stack.indexOf(target);
      return stack.includes(dialog) && index > -1 && stack.indexOf(dialog) < index;
    };
    return above(document.querySelector('mdui-top-app-bar')) && above(document.querySelector('mdui-navigation-drawer'));
  }));


  check('相册弹窗提供昵称打码入口', await page.evaluate(() => {
    const dialog = Array.from(document.querySelectorAll('mdui-dialog')).find((element) => element.querySelector('.viewer-body'));
    return Array.from(dialog?.querySelectorAll('mdui-button') ?? []).some((element) => element.textContent?.includes('昵称打码'));
  }));
  await clickText(page, 'mdui-dialog mdui-button', '昵称打码');
  check('相册昵称打码按对局与格式启动任务', await page.waitForFunction(() => window.__ui.blurStart?.matchId === 'vs-100' && /video\//.test(window.__ui.blurStart?.mime || ''), { timeout: 5000 }).then(() => true).catch(() => false));
  check('相册昵称打码显示进度对话框', await page.waitForFunction(() => {
    const dialog = Array.from(document.querySelectorAll('mdui-dialog')).find((element) => element.querySelector('.blur-body'));
    return Boolean(dialog) && dialog.open === true;
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  check('相册昵称打码读不到画面时报错并保留原文件', await waitText(page, '无法打开该录像文件'));
  check('相册昵称打码出错时收回任务', await page.evaluate(() => (window.__ui.calls.cancelBlur || 0) > 0));
  await clickText(page, 'mdui-dialog mdui-button', '关闭');
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('相册可关闭打码对话框', await page.evaluate(() => !Array.from(document.querySelectorAll('mdui-dialog')).some((element) => element.querySelector('.blur-body') && element.open === true)));

  await page.evaluate(() => {
    for (const pick of document.querySelectorAll('.gallery-pick')) {
      pick.checked = true;
      pick.dispatchEvent(new Event('change', { bubbles: true }));
    }
  });
  check('相册勾选对局后批量打码按钮可用', await page.evaluate(() => {
    const button = Array.from(document.querySelectorAll('.bind-row mdui-button')).find((element) => element.textContent?.includes('批量打码'));
    return Boolean(button) && button.disabled === false;
  }));
  const blurBefore = await page.evaluate(() => ({ start: window.__ui.calls.startBlur || 0, cancel: window.__ui.calls.cancelBlur || 0 }));
  await clickText(page, '.bind-row mdui-button', '批量打码');
  check('相册批量打码为多局并发建任务', await page.waitForFunction((before) => (window.__ui.calls.startBlur || 0) >= before + 2, { timeout: 5000 }, blurBefore.start).then(() => true).catch(() => false));
  check('相册批量打码任务失败时逐个收回', await page.waitForFunction((before) => (window.__ui.calls.cancelBlur || 0) >= before + 2, { timeout: 5000 }, blurBefore.cancel).then(() => true).catch(() => false));
  await clickText(page, 'mdui-dialog mdui-button', '关闭');
  await new Promise((resolve) => setTimeout(resolve, 200));

  await page.evaluate(() => {
    const card = Array.from(document.querySelectorAll('.gallery-card')).find((element) => element.textContent?.includes('占地对战'));
    card?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
  });
  await waitText(page, '结束时间');
  await clickNav(page, 1);
  check('绑定页显示二维码图片', await page.waitForSelector('.qr-image', { timeout: 10000 }).then(() => true).catch(() => false));
  check('离开相册页后内嵌播放器销毁', await page.evaluate(() => document.querySelector('.viewer-video') === null));
  check('绑定页推送用户只显示绑定状态', (await waitText(page, '已绑定')) && !(await page.evaluate(() => document.body.innerText.includes('openid-owner'))));
  check('绑定页显示 id_token 第三方提示', await waitText(page, 'id_token'));
  check('绑定页已绑定时按钮禁用', await page.evaluate(() => {
    const buttons = Array.from(document.querySelectorAll('.bind-row mdui-button'));
    const nso = buttons.find((element) => element.textContent?.includes('登录 Nintendo 账号'));
    const qq = buttons.find((element) => element.textContent?.includes('获取绑定机器人二维码'));
    return Boolean(nso && nso.disabled === true && qq && qq.disabled === true);
  }));
  await page.evaluate(() => window.__patchStatus({ nsoState: 'expired', qqState: 'unbound' }));
  await new Promise((resolve) => setTimeout(resolve, 200));
  await clickText(page, '.bind-row mdui-button', '登录 Nintendo 账号');
  check('绑定页失效状态下 NSO 登录按钮可点击', await page.evaluate(() => window.__ui.calls.openNsoLogin === 1));
  await clickText(page, '.bind-row mdui-button', '获取绑定机器人二维码');
  check('绑定页未绑定时可重新获取二维码', await page.evaluate(() => window.__ui.calls.startQqLogin === 1));


  await clickNav(page, 4);
  check('切换到直播页', await page.waitForFunction(() => document.querySelector('.page-title')?.textContent === '直播', { timeout: 5000 }).then(() => true).catch(() => false));
  check('直播页同时显示采集画面与直播画面', await page.evaluate(() => {
    const canvas = document.querySelector('.live-stage .live-canvas');
    return document.querySelectorAll('.live-pane').length === 2 && Boolean(document.querySelector('.live-pane .preview-box')) && Boolean(canvas);
  }));
  check('直播画面由独立画布绘制并与采集画幅一致', await page.evaluate(() => {
    const canvas = document.querySelector('.live-stage .live-canvas');
    const video = document.querySelector('.live-pane .preview-video');
    if (!canvas || !video) return false;
    return canvas !== video && canvas.width === video.videoWidth && canvas.height === video.videoHeight && canvas.width > 0;
  }));
  const livePoint = await page.evaluate(() => {
    const rect = document.querySelector('.live-pane .preview-box')?.getBoundingClientRect();
    return rect ? { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 } : null;
  });
  check('直播页预览区可双击测试', Boolean(livePoint));
  if (livePoint) await doubleClick(page, livePoint);
  check('直播页双击不进入画中画', await page.evaluate(() => document.pictureInPictureElement === null));
  check('直播页不提供录制参数编辑入口', await page.evaluate(() => {
    const editors = document.querySelectorAll('mdui-select[name="width"], mdui-select[name="fps"], mdui-select[name="quality"], mdui-switch[name="flipVertical"]');
    return editors.length === 0;
  }));
  check('直播页提供独立的直播与打码设置', await page.evaluate(() => document.body.innerText.includes('直播与打码') && Boolean(document.querySelector('mdui-switch[name="blurNickname"]'))));
  check('直播页未开播时显示观看地址', await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll('.live-address')).map((item) => (item.textContent || '').trim());
    const labels = Array.from(document.querySelectorAll('.status-row .status-label')).map((item) => (item.textContent || '').trim());
    return rows.includes('http://localhost:11567/')
      && rows.length === 1
      && labels.includes('观看地址')
      && !labels.includes('监听地址')
      && labels.includes('端口')
      && document.querySelectorAll('.status-row mdui-button-icon').length === 1;
  }));
  check('直播页提示把观看地址填入 OBS', await waitText(page, '请将下面的观看地址填入OBS内'));
  check('直播页提示码率分辨率跟随设置', await waitText(page, '直播码率、分辨率跟随设置中设定的画面进行直播'));
  await page.evaluate(() => {
    document.querySelectorAll('.status-row mdui-button-icon')[0]?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
  });
  check('直播页可复制观看地址', await page.evaluate(() => (window.__ui.copied || []).includes('http://localhost:11567/')));
  check('直播页未开播时显示未直播与未开启打码', await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll('.status-row')).map((item) => (item.textContent || '').replace(/\s+/g, ''));
    return rows.some((text) => text.includes('直播状态') && text.includes('未直播'))
      && rows.some((text) => text.includes('推理设备') && text.includes('未开启打码'))
      && rows.some((text) => text.includes('直播码率') && text.includes('未直播'));
  }));
  await setChecked(page, 'mdui-switch[name="blurNickname"]', true);
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('直播页打码开关写回设置', await page.evaluate(() => window.__ui.lastSettings?.blurNickname === true));
  check('未开播但停留在直播页时开启打码会加载推理模型', await page.waitForFunction(() => (window.__ui.calls.startDetect || 0) > 0, { timeout: 10000 }).then(() => true).catch(() => false));
  await clickNav(page, 0);
  check('未开播时离开直播页会卸载推理模型', await page.waitForFunction(() => (window.__ui.calls.stopDetect || 0) > 0, { timeout: 10000 }).then(() => true).catch(() => false));
  await clickNav(page, 4);
  await page.waitForFunction(() => document.querySelector('.page-title')?.textContent === '直播', { timeout: 5000 }).catch(() => undefined);
  await setChecked(page, 'mdui-switch[name="blurNickname"]', false);
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('直播页关闭打码开关同样写回设置', await page.evaluate(() => window.__ui.lastSettings?.blurNickname === false));
  const blurPoint = await page.evaluate(() => {
    const rect = document.querySelector('mdui-switch[name="blurNickname"]')?.getBoundingClientRect();
    return rect ? { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 } : null;
  });
  if (blurPoint) {
    await page.keyboard.down('Shift');
    await page.mouse.click(blurPoint.x, blurPoint.y);
    await page.keyboard.up('Shift');
  }
  check('Shift 点击昵称自动打码开启检测框调试', await page.waitForFunction(() => window.__ui.lastSettings?.blurNickname === true && document.body.innerText.includes('检测框调试已开启'), { timeout: 5000 }).then(() => true).catch(() => false));
  check('开启打码后直播画面沿用采集原画幅', await page.evaluate(() => {
    const canvas = document.querySelector('.live-stage .live-canvas');
    const video = document.querySelector('.live-pane .preview-video');
    return Boolean(canvas && video) && canvas.width === video.videoWidth && canvas.height === video.videoHeight && canvas.width > 0;
  }));
  if (blurPoint) await page.mouse.click(blurPoint.x, blurPoint.y);
  check('普通点击关闭打码后检测框调试结束', await page.waitForFunction(() => window.__ui.lastSettings?.blurNickname === false && !document.body.innerText.includes('检测框调试已开启'), { timeout: 5000 }).then(() => true).catch(() => false));
  const detectBeforeLive = await page.evaluate(() => window.__ui.calls.startDetect || 0);
  await page.evaluate(() => { window.__ui.liveFail = true; });
  await clickText(page, '.status-actions mdui-button', '开始直播');
  check('直播启动失败时显示原因并保持开始按钮', await page.waitForFunction(() => {
    const rows = Array.from(document.querySelectorAll('.status-row')).map((item) => (item.textContent || '').replace(/\s+/g, ''));
    const button = document.querySelector('.status-actions mdui-button');
    return rows.some((text) => text.includes('直播错误') && text.includes('监听端口被占用')) && (button?.textContent || '').includes('开始直播');
  }, { timeout: 10000 }).then(() => true).catch(() => false));
  await page.evaluate(() => { window.__ui.liveFail = false; });
  await clickText(page, '.status-actions mdui-button', '开始直播');
  check('直播页开始直播调用主进程', await page.waitForFunction(() => (window.__ui.liveStarted || 0) > 0, { timeout: 10000 }).then(() => true).catch(() => false));
  check('未开启打码开播时不加载推理模型', await page.evaluate((before) => (window.__ui.calls.startDetect || 0) === before, detectBeforeLive));
  await setChecked(page, 'mdui-switch[name="blurNickname"]', true);
  check('直播中开启打码后加载推理模型', await page.waitForFunction((before) => (window.__ui.calls.startDetect || 0) > before, { timeout: 10000 }, detectBeforeLive).then(() => true).catch(() => false));
  await setChecked(page, 'mdui-switch[name="blurNickname"]', false);
  check('直播中关闭打码后卸载推理模型', await page.waitForFunction(() => (window.__ui.calls.stopDetect || 0) > 0, { timeout: 10000 }).then(() => true).catch(() => false));
  check('直播页显示直播中状态', await waitText(page, '直播中'));
  check('直播页显示本机观看地址', await waitText(page, 'http://localhost:11567/'));
  check('直播页开播后显示端口', await waitText(page, '11567'));
  await clickText(page, '.status-actions mdui-button', '停止直播');
  check('直播页停止直播通知主进程', await page.waitForFunction(() => (window.__ui.calls.stopLive || 0) > 0, { timeout: 10000 }).then(() => true).catch(() => false));
  check('停止后回到未直播状态', await waitText(page, '未直播'));
  check('直播页只调用白名单桥接方法', await page.evaluate(() => window.__ui.unknown.length === 0));

  await clickNav(page, 5);
  check('设置页渲染选择框', await page.waitForSelector('mdui-select', { timeout: 10000 }).then(() => true).catch(() => false));
  check('设置页列出枚举到的采集设备', await page.waitForFunction(() => {
    const items = Array.from(document.querySelectorAll('mdui-select[name="videoDevice"] mdui-menu-item')).map((item) => item.textContent || '');
    return items.some((text) => text.includes('OBS Virtual Camera')) && items.some((text) => text.includes('Camera 2'));
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  check('设置页列出音频设备', await page.waitForFunction(() => {
    const items = Array.from(document.querySelectorAll('mdui-select[name="audioDevice"] mdui-menu-item')).map((item) => item.textContent || '');
    return items.includes('不录制音频') && items.some((text) => text.includes('Audio 1'));
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  check('设置页提供分辨率与帧率选择', await page.waitForFunction(() => {
    const size = document.querySelector('mdui-select[name="width"]');
    const fps = document.querySelector('mdui-select[name="fps"]');
    const sizes = Array.from(size?.querySelectorAll('mdui-menu-item') ?? []).map((item) => item.getAttribute('value'));
    const rates = Array.from(fps?.querySelectorAll('mdui-menu-item') ?? []).map((item) => item.getAttribute('value'));
    return sizes.includes('3840x2160') && rates.includes('60');
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  await setValue(page, 'mdui-select[name="width"]', '1920x1080');
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('设置页分辨率改动即时保存', await page.evaluate(() => window.__ui.lastSettings?.width === 1920 && window.__ui.lastSettings?.height === 1080));
  check('设置页改分辨率后实际画幅生效', await page.waitForFunction(() => {
    const report = window.__ui.reports[window.__ui.reports.length - 1];
    return Boolean(report) && report.width === 1920 && report.height === 1080;
  }, { timeout: 10000 }).then(() => true).catch(() => false));
  await setValue(page, 'mdui-select[name="fps"]', '60');
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('设置页帧率改动即时保存', await page.evaluate(() => window.__ui.lastSettings?.fps === 60));
  await setChecked(page, 'mdui-switch[name="flipVertical"]', true);
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('设置页垂直翻转即时保存', await page.evaluate(() => window.__ui.lastSettings?.flipVertical === true));
  check('设置页只有一处录制参数入口', await page.evaluate(() => document.querySelectorAll('mdui-select[name="width"]').length === 1 && document.querySelectorAll('mdui-switch[name="flipVertical"]').length === 1));
  check('设置页不提供缓存与分段编辑入口', await page.evaluate(() => !document.querySelector('mdui-slider[name="cacheMinutes"]')
    && !document.querySelector('mdui-slider[name="segmentSeconds"]')
    && !document.body.innerText.includes('缓存保留')));
  check('设备名不带浏览器追加的芯片编号', await page.evaluate(() => {
    const items = Array.from(document.querySelectorAll('mdui-select[name="videoDevice"] mdui-menu-item, mdui-select[name="audioDevice"] mdui-menu-item'));
    return items.length >= 5 && items.every((item) => !/\([0-9a-f]{4}:[0-9a-f]{4}\)$/i.test((item.textContent || '').trim()));
  }));
  check('设置页按配置选中去编号后的设备', await page.evaluate(() => document.querySelector('mdui-select[name="videoDevice"]')?.value === 'obs1'));
  check('设置页显示编码器策略档位', await page.waitForFunction(() => {
    const items = Array.from(document.querySelectorAll('mdui-select[name="encoder"] mdui-menu-item')).map((item) => item.textContent || '');
    return items.some((text) => text.includes('NVIDIA NVENC')) && items.some((text) => text.includes('软件编码'));
  }, { timeout: 5000 }).then(() => true).catch(() => false));
  await page.evaluate(() => { window.__deviceDelay = 1200; });
  await page.evaluate(() => {
    document.querySelector('.select-icon-row mdui-button-icon')?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
  });
  check('设置页检索设备显示进度条', await page.waitForSelector('.device-loading', { timeout: 3000 }).then(() => true).catch(() => false));
  await page.waitForFunction(() => !document.querySelector('.device-loading'), { timeout: 5000 }).catch(() => undefined);
  await page.evaluate(() => { window.__deviceDelay = 0; });
  await setValue(page, 'mdui-select[name="encoder"]', 'nvidia');
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('设置页编码器策略即时保存', await page.evaluate(() => window.__ui.lastSettings?.encoder === 'nvidia'));
  await setValue(page, 'mdui-select[name="videoDevice"]', 'cam2');
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('设置页选择摄像头即时保存', await page.evaluate(() => window.__ui.lastSettings?.videoDevice === 'cam2'));
  check('设置页分辨率档位跟随采集卡上报能力', await page.waitForFunction(() => {
    const values = Array.from(document.querySelectorAll('mdui-select[name="width"] mdui-menu-item')).map((item) => item.getAttribute('value'));
    return values.includes('1280x720') && !values.includes('3840x2160') && !values.includes('2560x1440');
  }, { timeout: 10000 }).then(() => true).catch(() => false));
  check('设置页帧率档位跟随采集卡上报能力', await page.evaluate(() => {
    const values = Array.from(document.querySelectorAll('mdui-select[name="fps"] mdui-menu-item')).map((item) => item.getAttribute('value'));
    return values.includes('30') && !values.includes('60');
  }));
  check('设置页在采集卡拒绝配置分辨率时提示未接受', await waitText(page, '采集卡未接受该分辨率'));
  check('设置页录制质量按固定三档渲染', await page.evaluate(() => {
    const select = document.querySelector('mdui-select[name="quality"]');
    const items = Array.from(select?.querySelectorAll('mdui-menu-item') ?? []);
    const values = items.map((item) => item.getAttribute('value'));
    const labels = items.map((item) => item.textContent || '');
    return Boolean(select) && values.join(',') === '18,22,28'
      && labels.some((text) => text.includes('高质量、存储占用大'))
      && labels.some((text) => text.includes('普通质量、存储占用适中'))
      && labels.some((text) => text.includes('低质量、存储占用小'));
  }));
  check('设置页质量提示画质与体积关系', await waitText(page, 'CQP 数值越低画质越高'));
  check('设置页删除档位来源与重建提示', await page.evaluate(() => !document.body.innerText.includes('档位来自采集卡上报能力')
    && !document.body.innerText.includes('录制中修改会短暂重建采集')
    && !document.body.innerText.includes('自动探测 NVIDIA、AMD、Intel 硬件编码器')
    && !document.body.innerText.includes('缓存与分段')
    && !document.body.innerText.includes('缓存保留')));
  check('设置页编码器选择框改名为编码器', await page.evaluate(() => {
    const select = document.querySelector('mdui-select[name="encoder"]');
    const label = select?.getAttribute('label') || '';
    const texts = Array.from(document.querySelectorAll('.form-label')).map((item) => item.textContent || '');
    return label === '编码器' && !texts.includes('编码器策略');
  }));
  await setValue(page, 'mdui-select[name="quality"]', '18');
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('设置页录制质量即时保存', await page.evaluate(() => window.__ui.lastSettings?.quality === 18));
  await setValue(page, 'mdui-select[name="quality"]', '28');
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('设置页切换质量档即时保存', await page.evaluate(() => window.__ui.lastSettings?.quality === 28));
  await setChecked(page, '.form-switch mdui-switch[name="autoPush"]', false);
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('设置页开关即时保存', await page.evaluate(() => window.__ui.lastSettings?.autoPush === false));

  await page.evaluate(() => {
    document.querySelectorAll('.select-icon-row mdui-button-icon')[1]?.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
  });
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('设置页可挑选保存目录', await page.evaluate(() => window.__ui.lastSettings?.saveDir === 'D:/picked'));
  check('设置页无保存按钮', await page.evaluate(() => !document.body.innerText.includes('保存设置')));
  check('设置页不再提供直播与打码设置', await page.evaluate(() => !document.body.innerText.includes('直播与打码') && !document.querySelector('mdui-switch[name="blurNickname"]')));
  check('设置页保存设置并继续写入分段', await page.evaluate(() => (window.__ui.calls.saveSettings || 0) > 0 && window.__ui.calls.writeSegment > 0));

  await clickNav(page, 6);
  check('关于页显示项目名', await waitText(page, 'Splatoon3Record'));
  check('关于页显示版本', await waitText(page, '2.0.0'));
  check('关于页显示作者简介', await waitText(page, '巨齿刮水刀'));
  check('作者头像指向作者 QQ 头像并与应用图标区分', await page.evaluate(() => {
    const logo = document.querySelector('.about-logo');
    const avatar = document.querySelector('.about-avatar[alt="澪度"]');
    if (!logo || !avatar) return false;
    const url = new URL(avatar.src);
    return url.hostname.endsWith('qlogo.cn') && url.searchParams.get('dst_uin') === '3648192311' && avatar.src !== logo.src;
  }));
  check('关于页显示 nxapi 致谢', await waitText(page, 'samuelthomas2774/nxapi'));
  check('关于页提供设备信息复制按钮', await page.evaluate(() => Array.from(document.querySelectorAll('.about-card mdui-button')).some((element) => element.textContent?.includes('复制设备信息') && element.getAttribute('variant') === 'filled')));
  const copiesBeforeDiagnostic = await page.evaluate(() => window.__ui.copied.length);
  await clickText(page, '.about-card mdui-button', '复制设备信息');
  check('关于页复制设备信息调用运行环境接口', await page.waitForFunction((before) => (window.__ui.calls.getRuntimeInfo || 0) === 1 && window.__ui.copied.length > before, { timeout: 5000 }, copiesBeforeDiagnostic).then(() => true).catch(() => false));
  check('关于页诊断包含已选采集卡能力与硬件详情', await page.evaluate(() => {
    const diagnostic = window.__ui.copied.at(-1) || '';
    return diagnostic.includes('已选采集卡：Camera 2')
      && diagnostic.includes('采集卡能力上限：1280x720 @ 30 fps')
      && diagnostic.includes('采集卡原生规格：1280x720 @ 30 fps')
      && diagnostic.includes('已选音频设备：Audio 1')
      && diagnostic.includes('GPU：NVIDIA / GeForce RTX 4060')
      && diagnostic.includes('硬件加速：已启用')
      && diagnostic.includes('GPU 功能：video_decode=enabled, video_encode=enabled')
      && diagnostic.includes('硬件解码档位：CUDA')
      && diagnostic.includes('归档编码器：hevc_amf');
  }));
  check('关于页只调用白名单桥接方法', await page.evaluate(() => window.__ui.unknown.length === 0));

  await page.setViewport({ width: 640, height: 560 });
  await new Promise((resolve) => setTimeout(resolve, 600));
  check('窄窗口无横向溢出', await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1));
  check('窄窗口顶栏标题可见', await page.evaluate(() => {
    const bar = document.querySelector('mdui-top-app-bar .bar-title');
    if (!bar) return false;
    const rect = bar.getBoundingClientRect();
    return rect.width > 0 && rect.right <= window.innerWidth + 1;
  }));
  await page.setViewport({ width: 1360, height: 860 });

  await page.goto(`http://127.0.0.1:${port}/index.html?preview=1`, { waitUntil: 'networkidle0' });
  check('独立预览页面只渲染无控制视频', await page.waitForFunction(() => {
    const video = document.querySelector('video');
    return Boolean(video) && document.querySelectorAll('video').length === 1
      && !document.querySelector('mdui-top-app-bar') && !document.querySelector('.boot-layer')
      && document.body.innerText.trim() === '';
  }, { timeout: 15000 }).then(() => true).catch(() => false));

  await page.goto(`http://127.0.0.1:${port}/index.html?setup=1`, { waitUntil: 'networkidle0' });
  await page.waitForSelector('.setup-body', { timeout: 15000 });
  check('setup 页吉祥物首屏可见', await page.evaluate(() => {
    const mascot = document.querySelector('.mascot');
    if (!mascot) return false;
    const rect = mascot.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0 && rect.top < window.innerHeight && rect.left < window.innerWidth;
  }));
  check('setup 页吉祥物位于表单之下', await page.evaluate(() => {
    const mascot = document.querySelector('.mascot');
    const step = document.querySelector('.setup-step');
    if (!mascot || !step) return false;
    const a = mascot.getBoundingClientRect();
    const b = step.getBoundingClientRect();
    const left = Math.max(a.left, b.left);
    const right = Math.min(a.right, b.right);
    const top = Math.max(a.top, b.top);
    const bottom = Math.min(a.bottom, b.bottom);
    if (right - left < 2 || bottom - top < 2) return false;
    const previous = mascot.style.pointerEvents;
    mascot.style.pointerEvents = 'auto';
    const hit = document.elementFromPoint((left + right) / 2, (top + bottom) / 2);
    mascot.style.pointerEvents = previous;
    return Boolean(hit) && hit !== mascot && !mascot.contains(hit);
  }));
  check('setup 页引导样式生效', await page.evaluate(() => {
    const body = document.querySelector('.setup-body');
    const actions = document.querySelector('.setup-actions');
    if (!body || !actions) return false;
    const bodyStyle = getComputedStyle(body);
    const actionsStyle = getComputedStyle(actions);
    return bodyStyle.maxWidth === '640px' && actionsStyle.display === 'flex' && actionsStyle.gap === '12px';
  }));
  check('setup 页按枚举结果默认第一个摄像头', await page.waitForFunction(() => document.querySelector('mdui-select[name="videoDevice"]')?.value === 'obs1', { timeout: 5000 }).then(() => true).catch(() => false));
  await clickText(page, '.setup-actions mdui-button', '下一步');
  await new Promise((resolve) => setTimeout(resolve, 300));
  check('setup 页保存采集设备与画幅', await page.evaluate(() => {
    const saved = window.__ui.lastSettings;
    return Boolean(saved && saved.videoDevice === 'obs1' && saved.width === 1920 && saved.height === 1080 && saved.fps === 60);
  }));
  check('setup 页进入账号绑定步骤', await waitText(page, '绑定 Nintendo 账号'));
  await page.evaluate(() => window.__patchStatus({ nsoState: 'unbound' }));
  await new Promise((resolve) => setTimeout(resolve, 200));
  check('setup 页未登录时无法继续', await page.evaluate(() => {
    const button = Array.from(document.querySelectorAll('.setup-actions mdui-button')).find((element) => element.textContent?.includes('下一步'));
    return Boolean(button) && button.disabled === true;
  }));
  await page.evaluate(() => window.__patchStatus({ nsoState: 'connected' }));
  check('setup 页登录成功后自动进入 QQBot 步骤', await waitText(page, '绑定 QQBot'));
  await clickText(page, '.setup-actions mdui-button', '获取绑定机器人二维码');
  check('setup 页可获取绑定二维码', await page.evaluate(() => window.__ui.calls.startQqLogin === 1));
  await page.evaluate(() => window.__patchStatus({ qqState: 'unbound', qqOwner: undefined }));
  check('setup 页 QQBot 未连接时禁止完成', await page.evaluate(() => {
    const button = Array.from(document.querySelectorAll('.setup-actions mdui-button')).find((element) => element.textContent?.includes('完成并进入应用'));
    return Boolean(button?.disabled) && !window.__ui.calls.finishSetup;
  }));
  await page.evaluate(() => window.__patchStatus({ qqState: 'connected' }));
  check('setup 页未绑定用户时提示并禁止完成', await page.evaluate(() => {
    const button = Array.from(document.querySelectorAll('.setup-actions mdui-button')).find((element) => element.textContent?.includes('完成并进入应用'));
    return Boolean(button?.disabled) && document.body.innerText.includes('请在 QQBot 私聊中发送 /bind 绑定用户');
  }));
  await page.evaluate(() => window.__patchStatus({ qqOwner: 'openid-owner' }));
  check('setup 页连接且绑定后可完成', await page.evaluate(() => {
    const button = Array.from(document.querySelectorAll('.setup-actions mdui-button')).find((element) => element.textContent?.includes('完成并进入应用'));
    return button?.disabled === false;
  }));
  await page.evaluate(() => { window.__ui.finishError = '请先连接 QQBot，再完成初始设置。'; });
  await clickText(page, '.setup-actions mdui-button', '完成并进入应用');
  check('setup 页显示后端校验错误', await page.waitForFunction(() => document.querySelector('[role="alert"]')?.textContent?.includes('请先连接 QQBot'), { timeout: 5000 }).then(() => true).catch(() => false));
  await page.evaluate(() => { window.__ui.finishError = null; });
  await clickText(page, '.setup-actions mdui-button', '完成并进入应用');
  check('setup 页 finishSetup 正常', await page.evaluate(() => window.__ui.calls.finishSetup === 2 && !document.querySelector('[role="alert"]')));

  const startupPage = await browser.newPage();
  await startupPage.setViewport({ width: 1360, height: 860 });
  await installMock(startupPage, createMockStatus(), mockMatches);
  await startupPage.evaluateOnNewDocument(() => { window.__forceDefaultOpen = 1; window.__openTimeoutOnce = true; window.__openDelay = 150; });
  await startupPage.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil: 'networkidle0' });
  await startupPage.waitForSelector('mdui-top-app-bar', { timeout: 15000 });
  check('设备首次打开落在默认档位时按配置画幅校正', await startupPage.waitForFunction(() => {
    const report = window.__ui.reports[window.__ui.reports.length - 1];
    return Boolean(report) && report.width === 1920 && report.height === 1080;
  }, { timeout: 15000 }).then(() => true).catch(() => false));
  check('设备默认档位确实生效过', await startupPage.evaluate(() => (window.__ui.opens || []).some((item) => item.forced && item.width === 640 && item.height === 480)));
  check('校正后状态页显示配置分辨率', await waitText(startupPage, '1920 x 1080'));
  check('校正后不显示未接受提示', await startupPage.evaluate(() => !(document.body.innerText || '').includes('采集卡未接受设置页的分辨率')));
  check('设备启动超时后自动重试恢复', await startupPage.evaluate(() => {
    const report = window.__ui.reports[window.__ui.reports.length - 1];
    return Boolean(report) && window.__openTimeoutOnce === false && !String(report.error || '').includes('Timeout');
  }));
  check('采集与探测不会同时打开设备', await startupPage.evaluate(() => window.__ui.openMax === 1));
  await startupPage.close();

  await browser.close();
  await server.close();
  await rm(userDataDir, { recursive: true, force: true });

  console.log(`\nUI 测试：${checks.length - failures.length}/${checks.length} 通过`);
  if (failures.length) {
    console.error(`失败项：${failures.join('、')}`);
    process.exit(1);
  }
}

main().catch(async (error) => {
  console.error(error);
  process.exit(1);
});
