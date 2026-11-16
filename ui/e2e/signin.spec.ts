import { test as base, expect, type Page } from '@playwright/test'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { startDiscourseStub, type DiscourseStub } from './discourse-stub'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { installWallet, GENERIC, METAMASK, type WalletInfo } from './wallet'
import {
  lightAccountAddress,
  lightAccountSignRequest,
  wrapLightAccountSignature,
} from '../src/lightAccount'
import {
  SIWE_BUNDLE_URL,
  SIWE_BUNDLE_VERSION,
} from '../../assets/javascripts/discourse/lib/siwe-bundle-version.js'
import { BUNDLE_FILE, bundleVersion } from '../scripts/bundle-version.mjs'

/**
 * Loads the built bundle (public/javascripts/siwe.iife.js, or SIWE_BUNDLE)
 * the way the forum does (from the versioned URL the controller uses), in
 * Chromium, and clicks through the sign-in.
 * Nothing leaves 127.0.0.1: every other request and WebSocket is refused
 * and recorded.
 */
const BUNDLE = resolve(process.env.SIWE_BUNDLE ?? BUNDLE_FILE)

type Fixtures = {
  stub: DiscourseStub
  /** Console errors and page errors. */
  errors: string[]
  /** Hosts outside the stub the page tried to reach (refused). */
  outside: string[]
}

const test = base.extend<Fixtures>({
  stub: async ({}, use) => {
    const stub = await startDiscourseStub(BUNDLE)
    await use(stub)
    await stub.close()
  },
  errors: async ({ page }, use) => {
    const errors: string[] = []
    page.on('console', (m) => m.type() === 'error' && errors.push(m.text()))
    page.on('pageerror', (e) => errors.push(e.message))
    await use(errors)
  },
  outside: async ({ context, stub }, use) => {
    const outside: string[] = []
    const local = new URL(stub.origin).host
    await context.route('**/*', (route) => {
      const url = new URL(route.request().url())
      if (url.host === local || url.protocol === 'data:')
        return route.continue()
      outside.push(url.host)
      return route.abort('blockedbyclient')
    })
    await context.routeWebSocket(/.*/, (ws) => {
      outside.push(new URL(ws.url()).host)
      ws.close()
    })
    await use(outside)
  },
})

/** A wallet button in the connect list, by the name it shows. */
const walletButton = (mount: ReturnType<Page['locator']>, name: string) =>
  mount
    .locator('button.choose-connector')
    .filter({ hasText: new RegExp(`^\\s*${name}\\s*$`) })

const unresolved = (errors: string[]) =>
  errors.filter((e) => /Could not resolve/.test(e))

async function openAuth(
  page: Page,
  stub: DiscourseStub,
  opts: { walletConnect?: boolean } = {},
) {
  await page.goto(
    `${stub.origin}/discourse-siwe/auth${opts.walletConnect ? '?wc=1' : ''}`,
  )
  await page.waitForFunction(
    () => (window as unknown as { __siweMounted?: boolean }).__siweMounted,
  )
  // Loaded from the URL the controller uses, with the version query string.
  expect(stub.bundleRequests).toEqual([SIWE_BUNDLE_URL])
  return page.locator('#siwe-mount')
}

for (const [label, info] of [
  ['MetaMask (EIP-6963 io.metamask)', METAMASK],
  ['a generic injected wallet', GENERIC],
] as [string, WalletInfo][]) {
  for (const walletConnect of [false, true]) {
    test(`signs in with ${label}${walletConnect ? ', WalletConnect configured' : ''}`, async ({
      page,
      stub,
      errors,
      outside,
    }) => {
      const wallet = await installWallet(page, info)
      const mount = await openAuth(page, stub, { walletConnect })

      await walletButton(mount, info.name).click()

      // Either the form posts to the callback or the connect list shows its
      // error; check the console first so a failure names the cause.
      await expect(
        page
          .locator('#callback-result')
          .or(mount.getByText(/Failed to connect/)),
      ).toBeVisible()
      expect(unresolved(errors)).toEqual([])
      await expect(page.locator('#callback-result')).toHaveText('signed in')
      expect(wallet.calls.map((c) => c.method)).toEqual(
        expect.arrayContaining(['eth_requestAccounts', 'eth_signTypedData_v4']),
      )
      expect(stub.callbacks).toHaveLength(1)
      expect(stub.callbacks[0].failure).toBeNull()
      expect(stub.callbacks[0].owner).toBe(wallet.address)
      // Anything outside was refused; record it so a new dependency shows up.
      test
        .info()
        .annotations.push({
          type: 'refused hosts',
          description: [...new Set(outside)].join(', ') || 'none',
        })
    })
  }
}

test('lists MetaMask, WalletConnect and Safe once each', async ({
  page,
  stub,
}) => {
  await installWallet(page, METAMASK)
  const mount = await openAuth(page, stub, { walletConnect: true })
  const names = await mount.locator('button.choose-connector').allInnerTexts()
  expect(names.map((n) => n.trim().toLowerCase())).toEqual([
    'metamask',
    'walletconnect',
    'safe',
  ])
})

for (const button of ['WalletConnect', 'Safe']) {
  test(`the ${button} button starts WalletConnect without a missing-package error`, async ({
    page,
    stub,
    errors,
    outside,
  }) => {
    const mount = await openAuth(page, stub, { walletConnect: true })
    await walletButton(mount, button).click()

    // The WalletConnect SDK loads and tries to reach its relay or API (which
    // the test refuses). A missing SDK fails before any of that.
    await expect
      .poll(
        () =>
          unresolved(errors)[0] ??
          (outside.some((h) => /walletconnect|reown/.test(h))
            ? 'reached for the WalletConnect relay'
            : 'waiting'),
        { timeout: 20_000 },
      )
      .toBe('reached for the WalletConnect relay')
  })
}

// The bundle is served as immutable, so the controller loads it as
// siwe.iife.js?v=<content hash>; a stale hash would keep the old bundle in
// browsers and the CDN for a year.
test('the controller loads the bundle by its content hash', async () => {
  expect(SIWE_BUNDLE_URL).toBe(
    `/plugins/discourse-siwe-auth/javascripts/siwe.iife.js?v=${SIWE_BUNDLE_VERSION}`,
  )
  test.skip(
    BUNDLE !== BUNDLE_FILE,
    'SIWE_BUNDLE is not the committed bundle, so the committed hash is not for it',
  )
  expect(SIWE_BUNDLE_VERSION).toBe(bundleVersion(readFileSync(BUNDLE)))
})

// Guards the stand-in itself: a callback it accepts must be one the plugin
// would accept, so it has to turn down a signature from the wrong key.
test('the stand-in rejects a signature from a key that does not own the account', async ({
  stub,
}) => {
  const owner = privateKeyToAccount(generatePrivateKey())
  const other = privateKeyToAccount(generatePrivateKey())
  const account = lightAccountAddress(owner.address)
  const res = await fetch(
    `${stub.origin}/discourse-siwe/message?eth_account=${account}&chain_id=1`,
  )
  const { message } = (await res.json()) as { message: string }
  const req = lightAccountSignRequest(owner.address, message)
  const forged = await other.signTypedData({
    ...req,
    domain: { ...req.domain, chainId: 1 },
  })
  await fetch(`${stub.origin}/auth/siwe/callback`, {
    method: 'POST',
    body: new URLSearchParams({
      eth_message: message,
      eth_signature: wrapLightAccountSignature(owner.address, forged),
    }),
  })
  expect(stub.callbacks).toHaveLength(1)
  expect(stub.callbacks[0].failure).toMatch(/wrong signer/)
})
