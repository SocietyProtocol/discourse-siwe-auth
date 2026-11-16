// Fails when the built bundle contains a stub for a package that was missing
// at build time. Vite/Rolldown turn an unresolvable dynamic import (such as an
// optional peer dependency of @wagmi/connectors that is not installed) into
// code that throws 'Could not resolve "<pkg>"' only when a user clicks the
// connector, so the build itself still succeeds.
//
// Usage: node scripts/check-bundle.mjs [path/to/siwe.iife.js]
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const file =
  process.argv[2] ??
  fileURLToPath(
    new URL('../../public/javascripts/siwe.iife.js', import.meta.url),
  )

const js = readFileSync(file, 'utf8')
const stubs = [
  ...new Set(
    [...js.matchAll(/Could not resolve \\?["']([^"'\\]+)/g)].map((m) => m[1]),
  ),
]

if (stubs.length) {
  console.error(
    `${file} has runtime stubs for packages that were missing at build time:\n` +
      stubs.map((s) => `  - ${s}`).join('\n') +
      '\nInstall them (optional peer dependencies are not installed by npm) or stop importing the code that needs them.',
  )
  process.exit(1)
}

console.log(`${file}: no unresolved-import stubs (${js.length} bytes)`)
