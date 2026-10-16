# Coldtill: self-hosted crypto payment gateway

**Coldtill is a self-hosted crypto payment gateway that accepts 200+ coins on 35+ chains.** Take Bitcoin, Ethereum,
USDT, USDC, Solana, Tron, Base, Polygon and BNB Chain directly on your own Linux server, and XRP, TON, Sui, Cardano,
Zcash, memecoins and more through auto-convert, settled to you as USDC or USDT. Every payment goes to your own cold
wallet. There's no sign-up, no KYC or KYB, no approval queue and no custody.

This repository hosts the **Free edition**: the install script, Docker image files, static binaries and checksums.
Install it with one command:

```bash
curl -fsSL https://coldtill.com/install.sh | sudo bash -s -- --edition free
```

[Website](https://coldtill.com) · [Docs](https://coldtill.com/docs/) · [Live demo dashboard](https://demo.coldtill.com/) ·
[Download](https://coldtill.com/download/) · [Pricing](https://coldtill.com/pricing/) · [Ownership](https://coldtill.com/ownership)

![The Coldtill dashboard: confirmed volume, deposits by asset and recent payments](https://coldtill.com/img/dashboard-overview.webp)

## Why run your own crypto payment gateway?

Hosted crypto processors decide who gets in, hold your money until they pay you out and take a cut of every sale.
A self-hosted crypto payment gateway removes the middleman:

- **Nobody to ask.** No application, no identity checks, no approval. Install it and take payments the same day.
- **Nobody to switch you off.** There's no licence server and no kill switch. Coldtill keeps running if coldtill.com goes offline.
- **Nobody in the middle.** Customers pay straight into addresses that only send to your wallet. No processor balance, no payout schedule, no account to freeze.
- **Your customer data stays on your server.**

## Features

- **Hosted checkout** with QR codes, exact amounts, live confirmation progress and your branding, on your own domain if you like.
- **Chains:** Ethereum, Base, Polygon, BNB Chain, Tron, Solana and Bitcoin, with native coins plus USDC and USDT.
- **Auto-convert:** take 200+ tokens on 35+ chains through NEAR Intents and receive USDC or USDT. Optional and off by default.
- **Automatic sweeps** to your cold wallet when the value justifies the gas, with per-network rules and fee caps. Tron sweeps can rent energy instead of burning TRX.
- **Payouts and refunds** from a small hot wallet, with an address book, limits and two-factor approval for anything large.
- **Many shops on one server:** each project has its own wallets, API keys, webhooks, branding and checkout domain.
- **For developers:** a small REST API, signed webhooks, OpenAPI 3.1, a TypeScript SDK and a [WooCommerce plugin](https://github.com/Coldtill/woocommerce-crypto-payment-gateway).

![Checkout: choose a network and coin, then scan the QR code](https://coldtill.com/img/checkout-pay.webp)

## How a payment works

1. Your shop calls `POST /api/v1/payment` and gets a checkout link.
2. The customer picks a coin and network and pays to their own deposit address.
3. Coldtill's watcher waits for confirmations, handles reorgs and sends your shop a signed webhook.
4. Coldtill sweeps the money to your cold wallet. The server never holds the keys to it.

On Ethereum-style chains, Tron and Solana, every deposit address is a contract or program address that can only send
to your cold wallet. Bitcoin addresses come from your own wallet's public key. Even someone who breaks into the server
can't redirect a payment. Read the [security model](https://coldtill.com/docs/security/) and
[threat model](https://coldtill.com/docs/threat-model/).

## Install

You need a Linux server with Docker: 2 vCPU and 4 GB of memory is plenty, on amd64 or arm64.

```bash
# Ubuntu, Debian or Linux Mint
sudo apt install docker.io docker-compose-v2 curl
curl -fsSL https://coldtill.com/install.sh | sudo bash -s -- --edition free
```

The script downloads the latest Free release from this repository and checks its SHA-256 against `SHA256SUMS`. It then
generates your secrets and starts the stack in `/opt/coldtill`. Run it again to upgrade; it backs up the database
first. Useful options:

| Option | What it does |
| --- | --- |
| `--mode mainnet --site-url https://pay.example.com` | Go live on mainnet at your own domain (testnet is the default) |
| `--version v1.2.0` | Install a specific release |
| `--download-only` | Just download and verify the file, without installing |

The [self-hosting guide](https://coldtill.com/docs/self-hosting/) covers choosing a server, DNS, keeping the
dashboard off the internet, backups and a go-live checklist.

### Without the script

Each [release](https://github.com/Coldtill/self-hosted-crypto-payment-gateway/releases/latest) has:

- `coldtill-VERSION-free-linux-ARCH-image.tar.gz`: the Docker image. Load it with `docker load -i`, and start it with the files in [`deploy/`](deploy/).
- `coldtill-VERSION-free-linux-ARCH`: a static binary.
- `SHA256SUMS`: checksums for every file. Check them with `sha256sum -c SHA256SUMS --ignore-missing`.

## Editions

Every edition is the same software, with unlimited projects and servers for your own business. They differ only in the sweep fee.

| | Free | Standard | Pro |
| --- | --- | --- | --- |
| Price | $0 | $499 one-time | $999 one-time |
| Sweep fee | 2% | 1% | 0% |
| Download | This repository, no account | [coldtill.com](https://coldtill.com/pricing/) | [coldtill.com](https://coldtill.com/pricing/) |

The fee is taken on chain, in the same transaction that sweeps a payment to your cold wallet, and it's fixed in each
deposit wallet when you create it. It goes to the Coldtill fee shares contracts rather than a company account; see
[Ownership](https://coldtill.com/ownership).

## Security

Report vulnerabilities privately to security@coldtill.com. See [SECURITY.md](SECURITY.md). Security fixes are free for every edition.

## Licence

The Free edition is free to download and run for your own business under the
[Coldtill end-user licence agreement](https://coldtill.com/eula/). The source code isn't published. See [LICENSE.md](LICENSE.md).
