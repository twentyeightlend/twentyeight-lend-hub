import { createConfig, fallback, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { defineChain } from "viem";

export const hyperEVM = defineChain({
  id: 999,
  name: "HyperEVM",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.hyperliquid.xyz/evm"] } },
  blockExplorers: { default: { name: "Hyperscan", url: "https://www.hyperscan.com" } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

// Primary RPC. In production VITE_RPC_URL="/rpc" → a same-origin path that Caddy reverse-proxies
// to the keyed HyperPC endpoint server-side, so the key is NEVER in the browser bundle. A relative
// path is resolved against the current origin at runtime. (An absolute URL is also accepted, e.g.
// for local dev.) Falls back to verified free public RPCs (chainId 999).
const RAW_PRIMARY = import.meta.env.VITE_RPC_URL as string | undefined;
const PRIMARY = RAW_PRIMARY && RAW_PRIMARY.startsWith("/")
  ? (typeof window !== "undefined" ? window.location.origin + RAW_PRIMARY : undefined)
  : RAW_PRIMARY;
const PUBLIC_RPCS = [
  "https://rpc.hyperliquid.xyz/evm",
  "https://hyperliquid.drpc.org",
  "https://rpc.hypurrscan.io",
  "https://rpc.purroofgroup.com",
];
const RPC_URLS = [PRIMARY, ...PUBLIC_RPCS].filter(Boolean) as string[];

export const config = createConfig({
  chains: [hyperEVM],
  // EIP-6963 discovery (default on, set explicitly) surfaces each installed wallet — Rabby,
  // MetaMask, etc. — as its own connector so the user can pick the exact one. injected() stays as a
  // fallback for wallets that don't announce via EIP-6963.
  multiInjectedProviderDiscovery: true,
  connectors: [injected()],
  transports: { [hyperEVM.id]: fallback(RPC_URLS.map((u) => http(u))) },
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
