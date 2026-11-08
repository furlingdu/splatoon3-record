export function errorText(error: unknown): string {
  const text = (error instanceof Error ? error.message : String(error ?? '')).replace(/^Error invoking remote method '[^']*':\s*(Error:\s*)?/, '').trim();
  return text || '操作失败';
}
