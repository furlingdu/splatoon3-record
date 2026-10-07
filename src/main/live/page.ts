export function playerPage(): string {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Splatoon3 Record 直播</title>
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden}
#view{position:absolute;left:50%;top:50%;transform-origin:center center;background:#000}
</style>
</head>
<body>
<canvas id="view" width="1280" height="720"></canvas>
<script>
var view = document.getElementById('view');
var ctx = view.getContext('2d');
var stats = { video: 0, audio: 0, key: 0, started: 0, width: 0, height: 0, bytes: 0, codec: '' };
window.__liveStats = stats;
var metaInfo = null;
var hasKey = false;
var decoder = null;
var audioCtx = null;
var gain = null;
var nextAudio = 0;
var channels = 2;
var sampleRate = 48000;
var busy = false;
var lastKeyRequest = -Infinity;

function fit() {
  if (!view.width || !view.height) return;
  var scale = Math.min(window.innerWidth / view.width, window.innerHeight / view.height);
  view.style.transform = 'translate(-50%,-50%) scale(' + (scale || 1) + ')';
}

window.addEventListener('resize', fit);

function base64(text) {
  var raw = atob(text);
  var bytes = new Uint8Array(raw.length);
  for (var index = 0; index < raw.length; index += 1) bytes[index] = raw.charCodeAt(index);
  return bytes;
}

function draw(frame) {
  if (view.width !== frame.displayWidth || view.height !== frame.displayHeight) {
    view.width = frame.displayWidth;
    view.height = frame.displayHeight;
    fit();
  }
  ctx.drawImage(frame, 0, 0);
  stats.width = view.width;
  stats.height = view.height;
  stats.video += 1;
}

function resetDecoder() {
  var previous = decoder;
  decoder = null;
  if (previous) {
    try {
      previous.close();
    } catch (cause) {
      void cause;
    }
  }
  hasKey = false;
}

function stopVideo() {
  resetDecoder();
  metaInfo = null;
  nextAudio = 0;
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, view.width, view.height);
}

function ensureDecoder() {
  if (decoder && decoder.state === 'configured') return true;
  if (!metaInfo) return false;
  var config = { codec: metaInfo.codec, optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware' };
  if (metaInfo.description) config.description = base64(metaInfo.description);
  try {
    var next = new VideoDecoder({
      output: function (frame) {
        if (decoder === next) draw(frame);
        frame.close();
      },
      error: function () {
        if (decoder !== next) return;
        resetDecoder();
        requestKey();
      },
    });
    next.configure(config);
    decoder = next;
    return true;
  } catch (cause) {
    void cause;
    if (next) next.close();
    resetDecoder();
    return false;
  }
}

function resumeAudio() {
  if (audioCtx && audioCtx.state !== 'running') void audioCtx.resume().catch(function () { void 0; });
}

function startAudio() {
  if (audioCtx) return;
  var Ctor = window.AudioContext || window.webkitAudioContext;
  if (!Ctor) return;
  audioCtx = new Ctor({ latencyHint: 'interactive' });
  gain = audioCtx.createGain();
  gain.connect(audioCtx.destination);
  nextAudio = 0;
  resumeAudio();
}

document.addEventListener('pointerdown', resumeAudio);
document.addEventListener('keydown', resumeAudio);

function playAudio(samples) {
  if (!audioCtx || !gain || audioCtx.state !== 'running') return;
  var count = channels === 1 ? 1 : 2;
  var frames = Math.floor(samples.length / Math.max(1, channels));
  if (!frames) return;
  var buffer = audioCtx.createBuffer(count, frames, sampleRate);
  for (var channel = 0; channel < count; channel += 1) {
    var target = buffer.getChannelData(channel);
    for (var index = 0; index < frames; index += 1) target[index] = samples[index * channels + Math.min(channel, channels - 1)];
  }
  var node = audioCtx.createBufferSource();
  node.buffer = buffer;
  node.connect(gain);
  node.onended = function () {
    try {
      node.disconnect();
    } catch (cause) {
      void cause;
    }
  };
  var now = audioCtx.currentTime;
  if (nextAudio < now + 0.02 || nextAudio > now + 0.3) nextAudio = now + 0.05;
  node.start(nextAudio);
  nextAudio += buffer.duration;
  stats.audio += 1;
}

function requestKey() {
  var now = performance.now();
  if (now - lastKeyRequest < 250) return;
  lastKeyRequest = now;
  void fetch('/key', { method: 'POST', cache: 'no-store' }).catch(function () { void 0; });
}

function applyMeta(info) {
  metaInfo = info;
  stats.codec = info.codec;
  channels = info.channels === 1 ? 1 : 2;
  sampleRate = info.sampleRate || 48000;
  startAudio();
  resetDecoder();
  ensureDecoder();
  requestKey();
}

function handle(kind, flags, stamp, payload) {
  if (kind === 1) {
    try {
      applyMeta(JSON.parse(new TextDecoder().decode(payload)));
    } catch (cause) {
      void cause;
    }
    return;
  }
  if (kind === 2) {
    var key = (flags & 1) === 1;
    if (key) {
      hasKey = true;
      stats.key += 1;
    }
    if (!hasKey) return;
    if (!ensureDecoder()) return;
    if (decoder.decodeQueueSize > 6) {
      resetDecoder();
      if (!key) {
        requestKey();
        return;
      }
      if (!ensureDecoder()) {
        requestKey();
        return;
      }
      hasKey = true;
    }
    try {
      decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: Math.round(stamp), data: payload }));
    } catch (cause) {
      void cause;
      resetDecoder();
      requestKey();
    }
    return;
  }
  if (kind === 3 && payload.byteLength >= 4) {
    var samples = payload.byteOffset % 4 === 0
      ? new Float32Array(payload.buffer, payload.byteOffset, payload.byteLength / 4)
      : new Float32Array(payload.slice().buffer);
    playAudio(samples);
  }
}

async function pump(body) {
  var reader = body.getReader();
  var pending = new Uint8Array(0);
  for (;;) {
    var step = await reader.read();
    if (step.done) break;
    var value = step.value;
    if (!pending.length) {
      pending = value;
    } else {
      var merged = new Uint8Array(pending.length + value.length);
      merged.set(pending);
      merged.set(value, pending.length);
      pending = merged;
    }
    for (;;) {
      if (pending.length < 16) break;
      var head = new DataView(pending.buffer, pending.byteOffset, 16);
      var size = head.getUint32(12, true);
      if (pending.length < 16 + size) break;
      stats.bytes += 16 + size;
      handle(pending[0], pending[1], head.getFloat64(4, true), pending.subarray(16, 16 + size));
      pending = pending.subarray(16 + size);
      if (pending.length === 0) pending = new Uint8Array(0);
    }
  }
}

async function connect() {
  requestKey();
  var response = await fetch('/stream', { cache: 'no-store' }).catch(function () { return undefined; });
  if (!response || !response.ok || !response.body) return false;
  stats.started += 1;
  await pump(response.body);
  return true;
}

async function status() {
  var response = await fetch('/status', { cache: 'no-store' }).catch(function () { return undefined; });
  if (!response || !response.ok) return undefined;
  return response.json().catch(function () { return undefined; });
}

async function loop() {
  if (busy) {
    setTimeout(loop, 500);
    return;
  }
  busy = true;
  try {
    var info = await status();
    if (!info || !info.live) {
      stopVideo();
    } else {
      await connect();
      stopVideo();
    }
  } catch (cause) {
    void cause;
  }
  busy = false;
  setTimeout(loop, 1000);
}

fit();
loop();
</script>
</body>
</html>`;
}
