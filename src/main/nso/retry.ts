export function isRetryableLogin(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return !/重新登录|会员|停用|频繁/.test(message);
}

export async function retryLogin<T>(task: () => Promise<T>, retries: number, delayMs: number, onRetry?: (attempt: number, error: unknown) => void): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await task();
    } catch (error) {
      lastError = error;
      if (attempt >= retries || !isRetryableLogin(error)) break;
      onRetry?.(attempt + 1, error);
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  throw lastError;
}
