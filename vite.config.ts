import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  root: 'src/renderer',
  envDir: __dirname,
  base: './',
  build: {
    outDir: '../../dist/renderer',
    emptyOutDir: true,
    minify: false,
  },
});
