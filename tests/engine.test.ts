import { describe, expect, it } from 'vitest';
import { rankProviders } from '../src/main/detect/engine.js';

function ort(names: string[]): never {
  return { listSupportedBackends: () => names.map((name) => ({ name })) } as never;
}

describe('rankProviders', () => {
  it('Windows 按 CUDA、HIP、ROCm、DirectML、WebGPU、CPU 排序', () => {
    expect(rankProviders(ort(['cpu', 'dml', 'webgpu', 'rocm', 'hip', 'cuda']), 'win32').map((item) => item.name)).toEqual(['cuda', 'hip', 'rocm', 'dml', 'webgpu', 'cpu']);
  });

  it('Windows 缺少 WebGPU 时使用 DirectML', () => {
    expect(rankProviders(ort(['cpu', 'dml']), 'win32').map((item) => item.name)).toEqual(['dml', 'cpu']);
  });

  it('macOS 优先实际暴露的 CoreML，再使用 WebGPU', () => {
    expect(rankProviders(ort(['cpu', 'webgpu', 'coreml']), 'darwin').map((item) => item.name)).toEqual(['coreml', 'webgpu', 'cpu']);
  });

  it('未暴露平台 GPU 后端时回退 CPU', () => {
    expect(rankProviders(ort(['cpu', 'dml']), 'darwin').map((item) => item.name)).toEqual(['cpu']);
  });

  it('后端枚举失败时回退 CPU', () => {
    const broken = { listSupportedBackends: () => { throw new Error('no'); } } as never;
    expect(rankProviders(broken, 'win32').map((item) => item.name)).toEqual(['cpu']);
  });
});
