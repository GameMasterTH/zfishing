import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { readFileSync, existsSync } from 'node:fs'
import { resolve } from 'node:path'

// Dev only. qa.html fetches the real locales/*.json at runtime rather than
// embedding a copy that goes stale silently; those files live outside this
// vite root, so open a path for them. `apply: 'serve'` keeps this out of the
// production build entirely.
const serveLocales = {
  name: 'zfishing-serve-locales',
  apply: 'serve' as const,
  configureServer(server: any) {
    server.middlewares.use((req: any, res: any, next: any) => {
      const match = /^\/locales\/([a-z_]+\.json)(\?|$)/.exec(req.url || '')
      if (!match) return next()
      const file = resolve(__dirname, '..', 'locales', match[1])
      if (!existsSync(file)) return next()
      res.setHeader('Content-Type', 'application/json; charset=utf-8')
      res.setHeader('Cache-Control', 'no-store')
      res.end(readFileSync(file))
    })
  },
}

export default defineConfig({
  plugins: [react(), serveLocales],
  base: './',
  build: { outDir: 'dist', assetsDir: 'assets', emptyOutDir: true },
})
