// Fails when the built bundle contains a stub for a package that was missing
// at build time. Vite/Rolldown turn an unresolvable dynamic import (such as an
// optional peer dependency of @wagmi/connectors that is not installed) into
// code that throws 'Could not resolve "<pkg>"' only when a user clicks the
// connector, so the build itself still succeeds.
//
// For the committed bundle it also fails when the content hash in
// assets/javascripts/discourse/lib/siwe-bundle-version.js does not match it:
// the controller loads the bundle by that hash, and a stale hash means
// browsers and the CDN keep serving the old bundle (see bundle-version.mjs).
//
// Usage: node scripts/check-bundle.mjs [path/to/siwe.iife.js]
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  BUNDLE_FILE,
  VERSION_MODULE_FILE,
  bundleVersion,
  committedVersion,
} from './bundle-version.mjs'

const file = resolve(process.argv[2] ?? BUNDLE_FILE)

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

if (file === BUNDLE_FILE) {
  const actual = bundleVersion(readFileSync(file))
  const committed = committedVersion()
  if (committed !== actual) {
    console.error(
      `${VERSION_MODULE_FILE} has version ${committed}, but the bundle's hash is ${actual}.\n` +
        'Rebuild with npm run build (it rewrites the module), and commit both files.',
    )
    process.exit(1)
  }
  console.log(`${VERSION_MODULE_FILE}: version ${actual} matches the bundle`)
} else {
  console.log(
    `(not the committed bundle, so the version module is not checked; its hash is ${bundleVersion(readFileSync(file))})`,
  )
}
