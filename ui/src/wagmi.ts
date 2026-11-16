import { http, createConfig, type CreateConnectorFn } from '@wagmi/core'
import { mainnet } from 'viem/chains'
import { injected, walletConnect } from '@wagmi/connectors'

export interface WagmiOptions {
  walletConnectProjectId?: string
}

const configCache = new Map<string, ReturnType<typeof createConfig>>()

// Connectors, and why only these:
// - injected(): browser wallets. Extensions that announce themselves over
//   EIP-6963 (MetaMask, Rabby, Rainbow, ...) are added by wagmi on their own.
// - walletConnect(): mobile wallets, and the "Safe" button (a WalletConnect
//   deep link into app.safe.global). Needs @walletconnect/ethereum-provider,
//   an optional peer of @wagmi/connectors that must be installed here.
// Not used:
// - metaMask(): its rdns (io.metamask) makes wagmi drop the MetaMask
//   extension's EIP-6963 entry, so every MetaMask click went through the SDK
//   connector, which needs @metamask/connect-evm. The extension is covered by
//   EIP-6963 and MetaMask mobile by WalletConnect.
// - safe(): only works inside a Safe App iframe, and the forum refuses to be
//   framed (X-Frame-Options SAMEORIGIN, frame-ancestors 'self').
// Optional peers that are not installed become runtime "Could not resolve"
// stubs in the bundle; scripts/check-bundle.mjs fails the build on those.
export function createWagmiConfig(options: WagmiOptions) {
  const key = options.walletConnectProjectId ?? ''
  const cached = configCache.get(key)
  if (cached) return cached

  const connectors: CreateConnectorFn[] = [injected()]

  if (options.walletConnectProjectId) {
    connectors.push(
      walletConnect({
        projectId: options.walletConnectProjectId,
        showQrModal: false,
      }),
    )
  }

  const config = createConfig({
    chains: [mainnet],
    batch: { multicall: true },
    connectors,
    transports: {
      [mainnet.id]: http(),
    },
  })

  configCache.set(key, config)
  return config
}
