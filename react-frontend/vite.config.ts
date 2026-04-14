import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: { port: 5500, host: true },
  preview: { port: 5500, host: true },
  build: { outDir: 'dist', sourcemap: false },
})
