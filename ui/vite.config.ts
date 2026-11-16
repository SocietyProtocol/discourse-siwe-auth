import {
  existsSync,
  readFileSync,
  writeFileSync,
  unlinkSync,
  readdirSync,
} from 'fs'
import { resolve } from 'path'
import { defineConfig, type Plugin } from 'vite'
import vue from '@vitejs/plugin-vue'
import {
  BUNDLE_FILE,
  VERSION_MODULE_FILE,
  bundleVersion,
  versionModule,
} from './scripts/bundle-version.mjs'

/**
 * After Vite writes the build output, reads any extracted CSS files,
 * prepends them to the JS bundle as `var __siwe_css__`, and deletes
 * the CSS files. This lets mountSiwe() inject component styles into
 * the shadow DOM at runtime.
 */
function cssToShadow(): Plugin {
  let outDir = ''
  return {
    name: 'css-to-shadow',
    configResolved(config) {
      outDir = config.build.outDir
    },
    closeBundle() {
      const absOut = resolve(outDir)
      const files = readdirSync(absOut)
      const cssFiles = files.filter((f) => f.endsWith('.css'))
      if (!cssFiles.length) return

      let css = ''
      for (const f of cssFiles) {
        css += readFileSync(resolve(absOut, f), 'utf-8')
        unlinkSync(resolve(absOut, f))
      }

      const jsFile = files.find((f) => f === 'siwe.iife.js')
      if (!jsFile) return

      const jsPath = resolve(absOut, jsFile)
      const js = readFileSync(jsPath, 'utf-8')
      // Prepend __siwe_css__ as a global before the IIFE
      writeFileSync(jsPath, `var __siwe_css__ = ${JSON.stringify(css)};\n` + js)
    },
  }
}

/**
 * After the bundle is final (runs after css-to-shadow), writes its content
 * hash into assets/javascripts/discourse/lib/siwe-bundle-version.js, which
 * the controller loads the bundle with (`siwe.iife.js?v=<hash>`). The bundle
 * is served as immutable, so a new URL is the only way a new bundle reaches
 * browsers and the CDN. See scripts/bundle-version.mjs.
 */
function bundleVersionModule(): Plugin {
  let outDir = ''
  return {
    name: 'siwe-bundle-version',
    configResolved(config) {
      outDir = resolve(config.root, config.build.outDir)
    },
    // After every other closeBundle hook, so the CSS is already prepended.
    closeBundle: {
      order: 'post',
      sequential: true,
      handler() {
        const jsPath = resolve(outDir, 'siwe.iife.js')
        // Only the committed bundle has a committed version module.
        if (jsPath !== BUNDLE_FILE || !existsSync(jsPath)) return
        const text = versionModule(bundleVersion(readFileSync(jsPath)))
        if (
          !existsSync(VERSION_MODULE_FILE) ||
          readFileSync(VERSION_MODULE_FILE, 'utf8') !== text
        ) {
          writeFileSync(VERSION_MODULE_FILE, text)
        }
      },
    },
  }
}

export default defineConfig({
  plugins: [vue(), cssToShadow(), bundleVersionModule()],
  define: {
    'process.env.NODE_ENV': JSON.stringify('production'),
  },
  build: {
    lib: {
      entry: 'src/main.ts',
      formats: ['iife'],
      name: 'SiweAuth',
      fileName: () => 'siwe.iife.js',
    },
    outDir: '../public/javascripts',
    emptyOutDir: false,
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
  },
  resolve: {
    dedupe: ['vue', '@wagmi/core', '@wagmi/vue'],
  },
  optimizeDeps: {
    exclude: ['@1001-digital/components', '@1001-digital/components.evm'],
    include: [
      'eventemitter3',
      'qrcode',
      '@walletconnect/ethereum-provider',
      '@reown/appkit/core',
    ],
  },
})
