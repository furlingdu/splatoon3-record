import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { detectWorkers } from '../../shared/constants.js';
import { buildBlob, decodeBoxes, releaseBlob } from './letterbox.js';
import type { DetectReply } from '../../shared/types.js';
import type { InferenceSession as OrtSession, TensorConstructor } from 'onnxruntime-node';

const currentDir = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const frameTimeoutMs = 8000;
const webgpuProvider = { name: 'webgpu', label: 'WebGPU' };
const dmlProvider = { name: 'dml', label: 'DirectML' };
const coremlProvider = { name: 'coreml', label: 'CoreML' };
const cudaProvider = { name: 'cuda', label: 'CUDA' };
const hipProvider = { name: 'hip', label: 'HIP' };
const rocmProvider = { name: 'rocm', label: 'ROCm' };
const cpuProvider = { name: 'cpu', label: 'CPU' };

interface OrtModule {
  InferenceSession: { create(path: string, options?: OrtSession.SessionOptions): Promise<OrtSession> };
  Tensor: TensorConstructor;
  listSupportedBackends: () => { name: string }[];
  env: { logLevel?: string };
}

let ort: OrtModule | undefined;
let session: OrtSession | undefined;
let starting: Promise<string> | undefined;
let slots = 0;
const waiters: (() => void)[] = [];
let inputName = 'images';
let outputName = 'output0';
let inputSize = 960;
let device = '';
let failure = '';

export function detectDevice(): string {
  return device;
}

export function detectFailure(): string {
  return failure;
}

export function startDetect(): Promise<string> {
  if (session) return Promise.resolve(device);
  if (starting) return starting;
  const run = openSession();
  starting = run;
  const clear = (): void => {
    if (starting === run) starting = undefined;
  };
  void run.then(clear, clear);
  return run;
}

export function detectFrame(frame: Uint8Array, width: number, height: number, conf: number): Promise<DetectReply> {
  return acquireSlot().then(() => runFrame(frame, width, height, conf)).finally(() => releaseSlot());
}

function acquireSlot(): Promise<void> {
  if (slots < detectWorkers) {
    slots += 1;
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    waiters.push(() => {
      slots += 1;
      resolve();
    });
  });
}

function releaseSlot(): void {
  slots = Math.max(0, slots - 1);
  const next = waiters.shift();
  if (next) next();
}

export function stopDetect(): void {
  const current = session;
  session = undefined;
  device = '';
  if (current) void current.release().catch(() => undefined);
}

function loadOrt(): OrtModule {
  if (!ort) {
    const loaded = require('onnxruntime-node') as OrtModule;
    loaded.env.logLevel = 'error';
    ort = loaded;
  }
  return ort;
}

async function openSession(): Promise<string> {
  const run = loadOrt();
  let lastError: unknown;
  for (const provider of rankProviders(run)) {
    let created: OrtSession | undefined;
    try {
      created = await createSession(run, provider.name);
      inputName = created.inputNames[0] ?? 'images';
      outputName = created.outputNames[0] ?? 'output0';
      inputSize = modelSize(created);
      await warmup(created);
      session = created;
      device = provider.label;
      failure = '';
      return device;
    } catch (cause) {
      lastError = cause;
      if (created) await created.release().catch(() => undefined);
    }
  }
  failure = messageOf(lastError);
  stopDetect();
  throw new Error(failure);
}

export function rankProviders(run: OrtModule, platform = process.platform): { name: string; label: string }[] {
  const available = listBackends(run);
  const candidates = platform === 'win32'
    ? [cudaProvider, hipProvider, rocmProvider, dmlProvider, webgpuProvider, cpuProvider]
    : platform === 'darwin'
      ? [cudaProvider, hipProvider, rocmProvider, coremlProvider, webgpuProvider, cpuProvider]
      : [cudaProvider, hipProvider, rocmProvider, webgpuProvider, cpuProvider];
  return candidates.filter((provider) => provider.name === 'cpu' || available.has(provider.name));
}

function listBackends(run: OrtModule): Set<string> {
  try {
    return new Set(run.listSupportedBackends().map((item) => item.name));
  } catch {
    return new Set(['cpu']);
  }
}

function createSession(run: OrtModule, name: string): Promise<OrtSession> {
  return run.InferenceSession.create(modelPath(), {
    executionProviders: [{ name }],
    graphOptimizationLevel: 'all',
  });
}

function modelSize(created: OrtSession): number {
  const meta = created.inputMetadata[0];
  const shape = meta && 'shape' in meta ? meta.shape : [];
  const size = Number(shape[2]);
  return Number.isFinite(size) && size > 0 ? size : 960;
}

async function warmup(created: OrtSession): Promise<void> {
  const tensor = new (loadOrt().Tensor)('float32', new Float32Array(3 * inputSize * inputSize), [1, 3, inputSize, inputSize]);
  await created.run({ [inputName]: tensor });
}

async function runFrame(frame: Uint8Array, width: number, height: number, conf: number): Promise<DetectReply> {
  await startDetect();
  const active = session;
  if (!active) throw new Error('推理后端未就绪');
  if (width <= 0 || height <= 0) throw new Error('帧尺寸非法');
  if (frame.length !== width * height * 4) throw new Error('帧数据长度与尺寸不符');
  const shot = buildBlob(frame, width, height, inputSize);
  const tensor = new (loadOrt().Tensor)('float32', shot.blob, [1, 3, inputSize, inputSize]);
  const started = performance.now();
  let outputs: Record<string, { data: unknown }>;
  try {
    outputs = await withTimeout(active.run({ [inputName]: tensor }));
  } finally {
    releaseBlob(shot.blob);
  }
  const elapsed = performance.now() - started;
  const rows = outputs[outputName]?.data;
  if (!(rows instanceof Float32Array)) return { boxes: [], ms: elapsed };
  return { boxes: decodeBoxes(rows, shot, width, height, conf), ms: elapsed };
}

function withTimeout(task: Promise<Record<string, { data: unknown }>>): Promise<Record<string, { data: unknown }>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      stopDetect();
      reject(new Error('推理超时'));
    }, frameTimeoutMs);
    task.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (cause: unknown) => {
        clearTimeout(timer);
        reject(cause instanceof Error ? cause : new Error(String(cause)));
      },
    );
  });
}

function modelPath(): string {
  const packaged = join(process.resourcesPath || '', 'runtime', 'models', 'spld_v2_nickname.onnx');
  if (process.resourcesPath && existsSync(packaged)) return packaged;
  return join(currentDir, '..', '..', '..', 'runtime', 'models', 'spld_v2_nickname.onnx');
}

function messageOf(cause: unknown): string {
  const text = cause instanceof Error ? cause.message : String(cause ?? '');
  return text.split('\n')[0]?.trim() || '推理后端启动失败';
}
