import type { Page } from '@playwright/test'
import type { Hex } from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'

/**
 * A test wallet for the browser: an EIP-1193 provider in the page, announced
 * over EIP-6963, whose requests are answered in Node by a viem account. The
 * page never holds the key. Signing needs no funds and no RPC.
 */
export type WalletInfo = {
  /** EIP-6963 name, shown on the connect button. */
  name: string
  /** EIP-6963 rdns. MetaMask's extension announces io.metamask. */
  rdns: string
  /** Sets window.ethereum.isMetaMask, as the MetaMask extension does. */
  isMetaMask: boolean
}

export const METAMASK: WalletInfo = {
  name: 'MetaMask',
  rdns: 'io.metamask',
  isMetaMask: true,
}

export const GENERIC: WalletInfo = {
  name: 'E2E Test Wallet',
  rdns: 'org.example.e2e-wallet',
  isMetaMask: false,
}

export type WalletCall = { method: string; params?: unknown }

type BridgeResponse = {
  result?: unknown
  error?: { code: number; message: string }
}

/** Installs the wallet into every page of `page`'s context before any app script runs. */
export async function installWallet(
  page: Page,
  info: WalletInfo,
  privateKey: Hex = generatePrivateKey(),
) {
  const account = privateKeyToAccount(privateKey)
  const chainId = 1
  const calls: WalletCall[] = []
  let authorized = false

  await page.exposeFunction(
    '__e2eWalletRequest',
    async ({ method, params }: WalletCall): Promise<BridgeResponse> => {
      calls.push({ method, params })
      const p = (params ?? []) as unknown[]
      switch (method) {
        // Like a real extension, accounts are exposed only after the user
        // approves eth_requestAccounts; before that eth_accounts is empty,
        // so wagmi's reconnect on page load does not connect by itself.
        case 'eth_requestAccounts':
          authorized = true
          return { result: [account.address] }
        case 'eth_accounts':
          return { result: authorized ? [account.address] : [] }
        case 'eth_chainId':
          return { result: `0x${chainId.toString(16)}` }
        case 'net_version':
          return { result: String(chainId) }
        case 'wallet_switchEthereumChain':
          return { result: null }
        case 'wallet_requestPermissions':
        case 'wallet_getPermissions':
          return { result: [{ parentCapability: 'eth_accounts' }] }
        case 'eth_signTypedData_v4': {
          const typed = typeof p[1] === 'string' ? JSON.parse(p[1]) : p[1]
          const { EIP712Domain: _domain, ...types } = typed.types
          const signature = await account.signTypedData({
            domain: typed.domain,
            types,
            primaryType: typed.primaryType,
            message: typed.message,
          })
          return { result: signature }
        }
        case 'personal_sign':
          return {
            result: await account.signMessage({
              message: { raw: p[0] as Hex },
            }),
          }
        default:
          return {
            error: { code: 4200, message: `e2e wallet: ${method} unsupported` },
          }
      }
    },
  )

  await page.addInitScript(injectedProvider, info)
  return { address: account.address, calls }
}

/**
 * Runs in the page (Playwright serialises it), so it must be self-contained.
 */
function injectedProvider(info: WalletInfo) {
  type Listener = (...args: unknown[]) => void
  const listeners = new Map<string, Set<Listener>>()
  const bridge = (
    window as unknown as {
      __e2eWalletRequest: (r: {
        method: string
        params?: unknown
      }) => Promise<{
        result?: unknown
        error?: { code: number; message: string }
      }>
    }
  ).__e2eWalletRequest

  const provider = {
    isMetaMask: info.isMetaMask,
    async request({ method, params }: { method: string; params?: unknown }) {
      const res = await bridge({ method, params })
      if (res.error) {
        const err = new Error(res.error.message) as Error & { code?: number }
        err.code = res.error.code
        throw err
      }
      return res.result
    },
    isConnected: () => true,
    on(event: string, l: Listener) {
      if (!listeners.has(event)) listeners.set(event, new Set())
      listeners.get(event)!.add(l)
      return provider
    },
    removeListener(event: string, l: Listener) {
      listeners.get(event)?.delete(l)
      return provider
    },
  }

  Object.defineProperty(window, 'ethereum', {
    value: provider,
    configurable: true,
    writable: true,
  })

  const icon =
    'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxIiBoZWlnaHQ9IjEiLz4='
  const announce = () =>
    window.dispatchEvent(
      new CustomEvent('eip6963:announceProvider', {
        detail: Object.freeze({
          info: Object.freeze({
            uuid:
              '00000000-0000-4000-8000-' +
              info.rdns.length.toString().padStart(12, '0'),
            name: info.name,
            icon,
            rdns: info.rdns,
          }),
          provider,
        }),
      }),
    )
  window.addEventListener('eip6963:requestProvider', announce)
  announce()
}
