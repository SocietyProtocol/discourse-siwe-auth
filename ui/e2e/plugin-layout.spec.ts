import { test, expect } from '@playwright/test'
import { existsSync, readdirSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * The stand-in page mounts the bundle once, but on the forum the mount runs
 * in the controller's constructor, once per controller Ember builds. The
 * module loader resolves `controllers/x` to `controllers/x/index` when only
 * the latter exists, so a nested `controllers/siwe-auth/index.js` was built
 * for both the `siwe-auth` route and its `siwe-auth.index` child, and the
 * wallet UI mounted twice. This checks the plugin's files instead.
 */
const DISCOURSE = fileURLToPath(
  new URL('../../assets/javascripts/discourse', import.meta.url),
)

const files = (dir: string): string[] =>
  existsSync(dir)
    ? readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
        e.isDirectory() ? files(join(dir, e.name)) : [join(dir, e.name)],
      )
    : []

test('no controller or route module is an index module of its parent', () => {
  const nested = ['controllers', 'routes'].flatMap((kind) =>
    files(join(DISCOURSE, kind))
      .map((f) => relative(DISCOURSE, f))
      .filter((f) => /(^|\/)index\.(js|gjs|ts)$/.test(f)),
  )
  expect(nested).toEqual([])
})

test('the sign-in page has one controller and one template', () => {
  expect(existsSync(join(DISCOURSE, 'controllers/siwe-auth.js'))).toBe(true)
  expect(existsSync(join(DISCOURSE, 'templates/siwe-auth.gjs'))).toBe(true)
  expect(files(join(DISCOURSE, 'controllers/siwe-auth'))).toEqual([])
  expect(files(join(DISCOURSE, 'templates/siwe-auth'))).toEqual([])
})
