import { createServer, type IncomingMessage, type Server } from 'node:http'
import { randomBytes } from 'node:crypto'
import { readFileSync } from 'node:fs'
import type { AddressInfo } from 'node:net'
import {
  type Address,
  type Hex,
  decodeAbiParameters,
  decodeFunctionData,
  getAddress,
  isAddressEqual,
  recoverTypedDataAddress,
  sliceHex,
} from 'viem'
import {
  lightAccountAddress,
  lightAccountSignRequest,
} from '../src/lightAccount'
// The module controllers/siwe-auth-index.js loads the bundle URL from.
import { SIWE_BUNDLE_URL } from '../../assets/javascripts/discourse/lib/siwe-bundle-version.js'
import { BUNDLE_URL_PATH } from '../scripts/bundle-version.mjs'

/**
 * A stand-in for the parts of Discourse the sign-in page talks to, so the
 * built bundle can be loaded and clicked through without a forum:
 *
 *   GET  /discourse-siwe/auth      the page from templates/siwe-auth-index.gjs,
 *                                   mounted as controllers/siwe-auth-index.js does
 *   GET  /plugins/discourse-siwe-auth/javascripts/siwe.iife.js   the bundle,
 *                                   whatever the query string (as Discourse
 *                                   serves it); the page asks for it as
 *                                   SIWE_BUNDLE_URL (siwe.iife.js?v=<hash>)
 *   GET  /discourse-siwe/message   AuthController#message (same checks, same
 *                                   EIP-4361 text, nonce kept per server)
 *   POST /auth/siwe/callback       the OmniAuth callback: checks domain and
 *                                   nonce like strategies/siwe.rb, and checks
 *                                   the EIP-6492 Light Account signature
 *                                   offline (the plugin does it with eth_call)
 *
 * Listens on 127.0.0.1 on a port the OS picks.
 */
export type Callback = {
  message: string
  signature: Hex
  /** Why the plugin would reject it, or null when it would accept it. */
  failure: string | null
  owner?: Address
}

export type DiscourseStub = {
  origin: string
  callbacks: Callback[]
  /** Path of the bundle being served. */
  bundlePath: string
  /** Paths with query string of every request for the bundle. */
  bundleRequests: string[]
  close: () => Promise<void>
}

const EIP6492_MAGIC =
  '0x6492649264926492649264926492649264926492649264926492649264926492'

export const STATEMENT = 'Sign in with Ethereum'
/** Not a real WalletConnect project id: the tests never reach the relay. */
export const FAKE_WC_PROJECT_ID = '00000000000000000000000000e2e000'

function authPage(walletConnectProjectId: string | undefined) {
  // Mirrors the template (hidden form + mount point) and the controller
  // (loadScript(SIWE_BUNDLE_URL), which adds a script tag with that src, then
  // window.mountSiwe with the same options).
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="csrf-token" content="e2e-csrf-token">
<title>siwe e2e</title>
</head>
<body class="siwe-login-page">
<form id="siwe-sign" method="POST" action="/auth/siwe/callback" style="display: none;">
  <textarea id="eth_message" name="eth_message"></textarea>
  <textarea id="eth_signature" name="eth_signature"></textarea>
</form>
<div id="siwe-mount" class="siwe-mount"></div>
<script>
  const settings = ${JSON.stringify({ projectId: walletConnectProjectId ?? '', statement: STATEMENT })};
  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
  const s = document.createElement('script');
  s.src = ${JSON.stringify(SIWE_BUNDLE_URL)};
  s.onload = () => {
    if (window.mountSiwe) {
      window.mountSiwe('#siwe-mount', {
        csrfToken,
        callbackUrl: '/auth/siwe/callback',
        messageUrl: '/discourse-siwe/message',
        walletConnectProjectId: settings.projectId,
        statement: settings.statement,
      });
      window.__siweMounted = true;
    }
  };
  document.head.appendChild(s);
</script>
</body>
</html>`
}

function siweMessage(
  host: string,
  origin: string,
  address: string,
  chainId: string,
  nonce: string,
) {
  const now = new Date()
  const iso = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, 'Z')
  return [
    `${host} wants you to sign in with your Ethereum account:`,
    address,
    '',
    STATEMENT,
    '',
    `URI: ${origin}`,
    'Version: 1',
    `Chain ID: ${chainId}`,
    `Nonce: ${nonce}`,
    `Issued At: ${iso(now)}`,
    `Expiration Time: ${iso(new Date(now.getTime() + 300_000))}`,
  ].join('\n')
}

const field = (message: string, name: string) =>
  message.match(new RegExp(`^${name}: (.*)$`, 'm'))?.[1]

/** The plugin's checks, with the EIP-6492 eth_call replaced by offline decoding. */
async function verify(
  message: string,
  signature: Hex,
  host: string,
  nonce: string | undefined,
) {
  const domain = message.split(' wants you to sign in')[0]
  if (domain !== host) return { failure: 'Invalid domain' }
  if (!nonce || field(message, 'Nonce') !== nonce)
    return { failure: 'Invalid nonce' }
  const address = message.split('\n')[1] as Address
  const chainId = Number(field(message, 'Chain ID'))

  if (!signature.toLowerCase().endsWith(EIP6492_MAGIC.slice(2))) {
    return {
      failure: 'invalid_signature (not an EIP-6492 Light Account signature)',
    }
  }
  const [factory, factoryData, inner] = decodeAbiParameters(
    [{ type: 'address' }, { type: 'bytes' }, { type: 'bytes' }],
    sliceHex(signature, 0, (signature.length - 2) / 2 - 32),
  )
  const { args } = decodeFunctionData({
    abi: [
      {
        type: 'function',
        name: 'createAccount',
        stateMutability: 'nonpayable',
        inputs: [
          { name: 'owner', type: 'address' },
          { name: 'salt', type: 'uint256' },
        ],
        outputs: [{ name: 'account', type: 'address' }],
      },
    ],
    data: factoryData,
  })
  const owner = getAddress(args[0])
  if (!isAddressEqual(lightAccountAddress(owner), address)) {
    return {
      failure: "invalid_signature (account is not the owner's Light Account)",
    }
  }
  if (!isAddressEqual(factory, '0x0000000000400CdFef5E2714E63d8040b700BC24')) {
    return { failure: 'invalid_signature (unknown factory)' }
  }
  if (sliceHex(inner, 0, 1) !== '0x00') {
    return { failure: 'invalid_signature (not an EOA owner signature)' }
  }
  const req = lightAccountSignRequest(owner, message)
  const signer = await recoverTypedDataAddress({
    domain: { ...req.domain, chainId },
    types: req.types,
    primaryType: req.primaryType,
    message: req.message,
    signature: sliceHex(inner, 1),
  })
  if (!isAddressEqual(signer, owner))
    return { failure: 'invalid_signature (wrong signer)', owner }
  return { failure: null, owner }
}

const readBody = (req: IncomingMessage) =>
  new Promise<string>((resolve, reject) => {
    let body = ''
    req.on('data', (c) => (body += c))
    req.on('end', () => resolve(body))
    req.on('error', reject)
  })

export async function startDiscourseStub(
  bundlePath: string,
): Promise<DiscourseStub> {
  const bundle = readFileSync(bundlePath)
  const callbacks: Callback[] = []
  const bundleRequests: string[] = []
  // One "session": the tests run one page at a time against a stub.
  let sessionNonce: string | undefined

  const server: Server = createServer(async (req, res) => {
    const host = req.headers.host ?? ''
    const origin = `http://${host}`
    const url = new URL(req.url ?? '/', origin)
    try {
      if (req.method === 'GET' && url.pathname === '/discourse-siwe/auth') {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
        return res.end(
          authPage(url.searchParams.get('wc') ? FAKE_WC_PROJECT_ID : undefined),
        )
      }
      if (req.method === 'GET' && url.pathname === BUNDLE_URL_PATH) {
        bundleRequests.push(url.pathname + url.search)
        res.writeHead(200, { 'content-type': 'application/javascript' })
        return res.end(bundle)
      }
      if (req.method === 'GET' && url.pathname === '/discourse-siwe/message') {
        const account = url.searchParams.get('eth_account') ?? ''
        const chainId = url.searchParams.get('chain_id') ?? ''
        res.setHeader('content-type', 'application/json')
        if (!/^0x[0-9a-fA-F]{40}$/.test(account)) {
          res.writeHead(400)
          return res.end(JSON.stringify({ error: 'Invalid Ethereum address' }))
        }
        if (!/^[1-9][0-9]*$/.test(chainId)) {
          res.writeHead(400)
          return res.end(JSON.stringify({ error: 'Invalid chain ID' }))
        }
        sessionNonce = randomBytes(8).toString('hex')
        return res.end(
          JSON.stringify({
            message: siweMessage(host, origin, account, chainId, sessionNonce),
          }),
        )
      }
      if (req.method === 'POST' && url.pathname === '/auth/siwe/callback') {
        const form = new URLSearchParams(await readBody(req))
        // A form post sends textarea newlines as CRLF; the plugin turns them back.
        const message = (form.get('eth_message') ?? '').replace(/\r\n/g, '\n')
        const signature = (form.get('eth_signature') ?? '0x') as Hex
        const nonce = sessionNonce
        sessionNonce = undefined
        const result = await verify(message, signature, host, nonce).catch(
          (e: Error) => ({
            failure: `invalid_signature (${e.message.split('\n')[0]})`,
            owner: undefined,
          }),
        )
        callbacks.push({ message, signature, ...result })
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
        return res.end(
          `<!doctype html><title>callback</title><p id="callback-result">${result.failure ? 'failure: ' + result.failure : 'signed in'}</p>`,
        )
      }
      if (url.pathname === '/favicon.ico') {
        res.writeHead(204)
        return res.end()
      }
      res.writeHead(404)
      res.end('not found')
    } catch (e) {
      res.writeHead(500)
      res.end(String(e))
    }
  })

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address() as AddressInfo
  return {
    origin: `http://127.0.0.1:${port}`,
    callbacks,
    bundlePath,
    bundleRequests,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  }
}
