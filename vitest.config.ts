import { defineConfig } from 'vitest/config';

const integrationTests = ['tests/media.test.ts', 'tests/liveserver.test.ts'];

export default defineConfig(({ mode }) => {
  const integration = mode === 'integration';
  return {
    root: '.',
    test: {
      environment: 'node',
      include: integration ? integrationTests : ['tests/**/*.test.ts'],
      exclude: integration ? [] : integrationTests,
      testTimeout: integration ? 120000 : 30000,
      hookTimeout: integration ? 120000 : 30000,
    },
  };
});
