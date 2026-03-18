import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  resolve: {
    alias: {
      '@forge/api': path.resolve(__dirname, './apps/api/src'),
    },
  },
  test: {
    globals: true,
    environment: 'node',
    include: [
      'tests/**/*.test.ts',
      'tests/**/*.spec.ts',
      'src/**/*.test.ts',
      'src/**/*.spec.ts',
      'src/**/*.test.tsx',
      'src/**/*.spec.tsx',
      'apps/api/src/**/*.test.ts',
      'apps/api/src/**/*.spec.ts',
    ],
    exclude: ['tests/e2e/**', 'node_modules/**'],
    env: {
      JWT_SECRET: 'test-secret-key-for-unit-tests',
      JWT_EXPIRES_IN: '1h',
      REFRESH_TOKEN_EXPIRES_IN: '7d',
    },
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      exclude: ['node_modules/', 'dist/'],
    },
  },
});
