import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { viteSingleFile } from 'vite-plugin-singlefile'

// One self-contained index.html: JS and CSS are inlined by vite-plugin-singlefile.
export default defineConfig({
  base: './',
  plugins: [react(), viteSingleFile()],
  build: { target: 'es2022' },
  resolve: { dedupe: ['react', 'react-dom'] },
})
