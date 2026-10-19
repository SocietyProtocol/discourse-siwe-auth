# Web3 Outpost sign-in for Discourse

A Discourse plugin by [Society Protocol](https://societyprotocol.io/) that lets
forum members sign in with their Ethereum wallet and show up in the community
with their **web3 identity** — their wallet address, their ENS name, or their
Society Protocol outpost profile.

## What this plugin is

This project started as a fork of
[`signinwithethereum/discourse-siwe-auth`](https://github.com/signinwithethereum/discourse-siwe-auth),
the reference [Sign-In with Ethereum (SIWE)](https://login.xyz) plugin for
Discourse. We turned it into Society Protocol's own plugin by extending it in
three directions:

1. **Web3 identities, not just authentication.** Beyond logging users in, the
   plugin resolves every identity attached to the signing wallet — ENS name and
   avatar (resolved server-side) and the wallet's Society Protocol outpost
   profile (name, bio, avatar, badge) — and stores them on the Discourse
   account.
2. **A display-identity toggle.** Users choose, from **Preferences > Profile**,
   which identity represents them in the forum: wallet, ENS, or Society
   Protocol outpost. The choice updates their visible name and avatar across
   the site. The selector is shown at the top of the profile section.
3. **Production-grade robustness.** Smart contract wallet support
   (EIP-1271 / EIP-6492, e.g. Safe and Coinbase Smart Wallet), a throttled
   background refresh so logins never block on external APIs, a backfill rake
   task for existing users, and fixes for installing on current Discourse
   with Ruby 3.4 (see [Compatibility notes](#compatibility-notes-discourse--ruby-34)).

What users experience:

- Injected wallets (MetaMask, Safe, etc.) work out of the box.
- WalletConnect / Reown works when a project ID is configured.
- If an Ethereum RPC URL is supplied, the plugin resolves ENS names and avatars
  server-side and suggests the ENS name as the default username for new sign-ups.
- If Society Protocol resolution is enabled, the plugin also resolves the user's
  Society outpost profile and lets the user pick their display identity:
  **wallet**, **ENS**, or **Society Protocol**.

The chosen display identity updates the user's visible name and avatar in
Discourse; the underlying username is never changed by this feature.

> **Fork note.** This repo tracks the fixes we contributed back upstream
> ([signinwithethereum/discourse-siwe-auth#2](https://github.com/signinwithethereum/discourse-siwe-auth/issues/2))
> for installing on current Discourse, which ships Ruby 3.4 inside the official
> `discourse/base` Docker image. See
> [Compatibility notes](#compatibility-notes-discourse--ruby-34) below.

## Requirements

- A Discourse forum that is self-hosted or hosted with a provider that supports
  third-party plugins, like [Communiteq](https://www.communiteq.com/).

## Installation

Access your container's `app.yml` file:

```bash
cd /var/discourse
nano containers/app.yml
```

Add a `before_code` hook to install `rubyzip` and an `after_code` hook to
clone the plugin:

```yml
hooks:
  before_code:
    - exec:
        cmd:
          - gem install rubyzip
  after_code:
    - exec:
      cd: $home/plugins
      cmd:
        - sudo -E -u discourse git clone https://github.com/discourse/docker_manager.git
        - sudo -E -u discourse git clone https://github.com/SocietyProtocol/discourse-siwe-auth.git # <-- added
```

### Why both hooks are needed

**`before_code` → `gem install rubyzip`**: the `rbsecp256k1` native crypto gem
this plugin depends on uses `rubyzip` inside its own `extconf.rb` to fetch and
unpack the libsecp256k1 C source during build. That happens at `bundle install`
time, *before* Discourse processes the `gem` directives in `plugin.rb`, so the
plugin's own gem block can't supply it in time. Installing `rubyzip`
system-wide in `before_code` guarantees it's on disk when the native
extension's build script runs.

**`after_code` → `sudo -E -u discourse git clone`**: always run the clone as
the unprivileged `discourse` user. On Ubuntu 24.04 a plain `git clone` runs as
`root` inside the container and produces files the Rails build cannot read,
which surfaces as a confusing failure during `./launcher rebuild app`. The
`-E` flag preserves the environment; `-u discourse` runs the command as the
user the rest of the Discourse build expects to own the plugin tree. Match the
exact form of the existing `docker_manager.git` line in your `app.yml`; if
that line is missing the prefix, your container is using an older layout —
add the prefix to both lines rather than dropping it from the new one.

Rebuild the container:

```bash
cd /var/discourse
./launcher rebuild app
```

## Configuration

After installation, find the plugin under **Admin > Plugins** and make sure it
is enabled:

![Installed plugins](/installed-plugins.png 'Installed plugins')

Click **Settings** to configure the plugin:

![Plugin settings](/settings.png 'Plugin settings')

From here you can customize the sign-in statement and optionally add a
WalletConnect / Reown project ID. Without a project ID, only injected wallets
(MetaMask, Safe, etc.) are available.

### Settings

| Setting | Description |
| --- | --- |
| **Discourse siwe enabled** | Enable or disable Sign-In with Ethereum authentication. |
| **Siwe ethereum rpc url** | _Optional._ An Ethereum JSON-RPC endpoint used for ENS name/avatar resolution and EIP-1271 signature verification (required for smart contract wallets like SAFE). A dedicated provider (Alchemy, Infura) is recommended. Example: `https://mainnet.infura.io/v3/YOUR_KEY`. |
| **Siwe project ID** | _Optional._ A WalletConnect / Reown project ID. Without it, only injected wallets (MetaMask, Safe, etc.) are available. To enable WalletConnect, create a free project ID at [dashboard.reown.com](https://dashboard.reown.com). |
| **Siwe statement** | The human-readable statement shown in the SIWE message. Defaults to "Sign in with Ethereum". |
| **Siwe society enabled** | Enable Society Protocol identity resolution and the display-identity toggle. |
| **Siwe society subgraph url** | _Optional._ The Society Protocol subgraph endpoint. Defaults to the live mainnet endpoint; leave blank to force direct RPC resolution. |
| **Siwe society badges contract** | Society Protocol Badges (ERC-1155) contract address. Defaults to the current mainnet proxy; update only if the contract is redeployed. |
| **Siwe identity resolution mode** | Preferred resolution mode: `subgraph` (default, falls back to RPC) or `rpc` (direct contract calls only). |

## Compatibility notes (Discourse + Ruby 3.4)

Recent versions of Discourse ship Ruby 3.4 inside the official
`discourse/base` Docker image and pin `rubyzip` to the 3.x line. That
combination broke the install of upstream
[`signinwithethereum/discourse-siwe-auth`](https://github.com/signinwithethereum/discourse-siwe-auth)
(see issue [#2](https://github.com/signinwithethereum/discourse-siwe-auth/issues/2)).
This fork fixes three distinct issues in `plugin.rb` so that `./launcher
rebuild app` completes cleanly. They are documented here so the changes
make sense to anyone reading the diff.

### 1. Discourse's plugin `gem` DSL needs an explicit version string

Discourse's plugin loader exposes a `gem` DSL whose signature is
`gem(name, version, opts = {})`, and it shells out to
`gem install ... --ignore-dependencies` under the hood. The original
plugin used short forms like `gem 'eth', require: false` (no version
arg). On Ruby 3.x that makes RubyGems treat the keyword-arguments hash
as the `version` argument, producing:

```
ERROR:  While executing gem ... (Gem::Requirement::BadRequirementError)
    Illformed requirement ["{"]
```

Every gem line in `plugin.rb` therefore now carries an explicit version
string as its second positional argument, e.g.
`gem 'eth', '0.5.17', require: false`.

### 2. Every transitive dependency must be declared explicitly

Because Discourse passes `--ignore-dependencies` to `gem install`,
RubyGems will not pull in transitive deps automatically. Two consequences
on Ruby 3.4:

- **`base64` is no longer a default gem** in Ruby 3.4 (it was demoted to
  a bundled gem). `eth >= 0.5.16` is the first version that explicitly
  depends on `base64`, so it must be listed in `plugin.rb`.
- The `eth` / `siwe` gems also need their full subgraph listed in
  install order: `ecdsa`, `h2c`, `bls12-381`, `http-2`, `httpx`. Same
  reasoning applies to lower-level build deps (`pkg-config`,
  `mini_portile2`, `ffi`, `ffi-compiler`, `konstructor`).

### 3. `rbsecp256k1`'s spurious `rubyzip ~> 2.3` runtime dep

The `rbsecp256k1` gem (which `eth` uses for ECDSA signature
recovery/verification) declares a runtime dependency on
`rubyzip ~> 2.3` in its `.gemspec`. In reality, `rubyzip` is only used
inside `rbsecp256k1`'s `extconf.rb` to download and unpack the
libsecp256k1 C source archive at **build time** — it has zero runtime
use of rubyzip. This is an upstream bug in `rbsecp256k1`'s gemspec and
every published version since 5.0.0 carries it.

Discourse's main bundle now pins `rubyzip 3.2.2`. So when Discourse's
plugin loader calls `Gem::Specification#activate` on `rbsecp256k1`
during boot, RubyGems sees the active rubyzip 3.x and the
`~> 2.3` constraint refuses to resolve, raising:

```
Gem::ConflictError: Unable to activate rbsecp256k1-6.0.0,
because rubyzip-3.2.2 conflicts with rubyzip (~> 2.3)
```

(`--ignore-dependencies` skips install-time resolution but RubyGems
still validates deps at activation time, so we can't simply ignore it.)

The workaround in `plugin.rb` does three things, all idempotent across
container rebuilds:

1. Pre-install `rbsecp256k1` ourselves into the plugin's gem dir using
   `Bundler.with_unbundled_env { system('gem install ...') }`.
2. Open the installed `.gemspec` on disk and strip exactly the line
   `s.add_runtime_dependency(%q<rubyzip>.freeze, ["~> 2.3".freeze])`
   using a precise regex (atomic temp-file + rename so a concurrent
   reader can never see a half-written file).
3. Call `Gem::Specification.reset` to invalidate the cached spec, then
   declare `gem 'rbsecp256k1', '6.0.0', require: false` normally.
   Discourse's plugin loader sees the gem already installed, reads the
   patched spec, and activates it without conflict. A
   `Rails.logger.info` line is emitted when the patch is applied so the
   shim is visible in production logs.

`rubyzip` still needs to be on the system gem path for
`rbsecp256k1`'s `extconf.rb` to succeed at build time, which is why
the `before_code: gem install rubyzip` hook in `app.yml` is still
required (see [Installation](#installation) above).

> **Local development note:** the `before_code` hook only runs during
> `./launcher rebuild app`. If you run Discourse locally outside the Docker
> bootstrap (e.g. `d/rails s` in a dev setup), install rubyzip once by hand
> (`gem install rubyzip`) so `rbsecp256k1`'s native build can find it.
> Do **not** work around this by declaring `gem 'rubyzip', ...` in
> `plugin.rb` — that reintroduces the activation conflict with Discourse's
> bundled rubyzip 3.x described above.

## Tests

The plugin includes standalone minitest unit and integration scripts for ENS
resolution and Society Protocol resolution. These run outside the full Discourse
suite.

### Unit tests (no network needed)

```bash
ruby test/ens_unit_test.rb
ruby test/society_unit_test.rb
ruby test/light_account_unit_test.rb
```

`test/light_account_unit_test.rb` checks the Light Account derivation against
every pair in `script/forum-address-map.json` and the rewrite planner. Without
the `keccak` gem it falls back to a pure-Ruby Keccak (`test/support/`); the
other scripts can use it too: `ruby -rtime -r ./test/support/pure_keccak test/society_unit_test.rb`.

### Integration tests (require an Ethereum RPC endpoint)

```bash
ruby test/ens_integration_test.rb
ruby test/society_integration_test.rb
```

By default, integration tests use a public RPC. Set `RPC_URL` for a dedicated
provider:

```bash
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY ruby test/society_integration_test.rb
```

To test the positive Society resolution path, set an address that holds a
profile badge:

```bash
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY \
SOCIETY_ADDRESS=0x... \
ruby test/society_integration_test.rb
```

### Run all tests

```bash
for f in test/*_test.rb; do ruby "$f"; done
```

## How it works

When a user clicks the Ethereum login button, the plugin opens a dedicated
authentication page. The user connects their wallet, signs a SIWE message,
and is authenticated via the OmniAuth strategy on the server side.

### Sign-up path

For a brand-new account, the plugin resolves available identities and stores
them in user custom fields:

- `wallet_address` — the verified Ethereum address.
- `ens_name` / `ens_avatar` — resolved server-side if an RPC URL is configured.
  The ENS name is suggested as the default username; the ENS avatar is fetched
  from the ENS metadata service.
- `society_badge_id` / `society_name` / `society_avatar` / `society_bio` —
  resolved from Society Protocol using the configured subgraph (default) or
  direct RPC fallback. When the Light Account has no profile yet, the owner
  EOA's profile is used.
- `siwe_owner_address` — the EOA that owns the Light Account, read from the
  EIP-6492 signature (only when CREATE2 ties it to the signing address).

A default `preferred_identity` is chosen automatically: Society if available,
otherwise ENS, otherwise wallet. `DisplayNameApplier` then applies it to
`user.name` and enqueues an avatar download if an avatar URL is present. The
Discourse username itself is never rewritten after account creation.

### Existing-user login path

For returning users, the login path does not block on network calls. It only
cheaply refreshes ENS from the already-resolved `auth_token.info` and queues a
throttled `RefreshSiweIdentity` background job to update Society data at most
once every 24 hours. This keeps logins fast even if Society Protocol's
subgraph or RPC is slow or unavailable.

### Display-identity toggle

Users with more than one available identity can switch at any time from
**Preferences > Profile**. The `update_identity` endpoint validates the choice
(e.g. rejecting Society if no badge exists), persists the new preference, and
re-applies `DisplayNameApplier`. On failure, the UI reverts the selection.

Because the profile page's plugin outlet is at the bottom of the form, a small
initializer (`assets/javascripts/discourse/initializers/siwe-identity-reposition.js.es6`)
moves the selector to the top of the profile section after render.

### Backfilling existing users

After deploying the plugin, run the rake task to backfill custom fields for
existing SIWE users:

```bash
bundle exec rake siwe:migrate_identities
```

Dry-run first:

```bash
bundle exec rake siwe:migrate_identities[true]
```

The task resolves ENS and Society identities, sets the default preference, and
stores the result in user custom fields. Existing display names are left
untouched unless the user toggles their preferred identity.

### Moving forum users to Light Accounts

Members sign in as their Light Account `S` (owned by their wallet `E`), not
as `E`. The SIWE `uid` is always the EIP-55 checksummed address, and Discourse
matches it exactly. Existing users must be moved from `E` to `S` **before**
the Light Account login goes live, otherwise their next sign-in creates a new,
empty forum user for `S`. That login is in every build of this branch from
`8a4f838` on, not only the final one: check step 0 before assuming it has not
shipped.

`script/rewrite_smart_account_users.rb` covers every `siwe` account on the
forum (not only Outpost members). For each one it derives `S` in Ruby, then:

- sets `provider_uid` to checksummed `S`, and `nickname` / `name` in the
  account's `info` when they held `E`;
- sets the `wallet_address` custom field to `S` and `siwe_owner_address` to `E`;
- renames a wallet-style display name (`0x9ba7…7c3c`) to `S`'s short form.

It refuses to run unless its derivation matches every pair in
`script/forum-address-map.json` (flat or chain-keyed). It skips rows that are
already Light Accounts (re-runs are no-ops), contract wallets (`eth_getCode`),
and, with `SUSPECT_AFTER`, rows created after a given time. A row whose uid is
a Light Account from the map is never rewritten, even with no
`siwe_owner_address`: it is `adopt` (records `E`) or `recase` (fixes the case
and records `E`). A uid that is not checksummed and is not in the map is left
as `review`, since only a script or a hand edit writes another case. If someone
already signed in as `S` (a duplicate user), it changes neither row and
prints both user ids and usernames; merge them in the admin UI, or pass
`MERGE_DUPLICATES=1` to merge the newer user into the original with
Discourse's `UserMerger`. Writes happen in one transaction.

Do staging (Sepolia) first, then production (mainnet). Light Account
addresses are the same on both chains; `RPC_URL` only feeds the contract
wallet check and should point at the forum's chain.

0. Find out whether the forum ever ran a build with the Light Account login
   (`8a4f838` or later; check the plugin commit in the admin panel or in
   `app.yml` and the rebuild history). If it did, users who signed in since
   then are rows for `S` with no recorded owner, and an `S` missing from the
   map would be rewritten to the Light Account of `S`. Set `SUSPECT_AFTER` to
   that first deploy time (ISO 8601) in steps 3 and 5. If it never did, pass
   `NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1` with `APPLY=1` instead; the script
   refuses to apply with neither.

1. Put the new plugin checkout where the container can read it, without
   rebuilding yet:

   ```bash
   cd /var/discourse
   git clone -b smart-account-login https://github.com/SocietyProtocol/discourse-siwe-auth.git \
     shared/standalone/tmp/discourse-siwe-auth
   ./launcher enter app
   cd /var/www/discourse
   ```

2. Back up what the rewrite touches (needed for rollback):

   ```bash
   sudo -u postgres psql discourse -c "
     CREATE TABLE siwe_backup_accounts AS
       SELECT * FROM user_associated_accounts WHERE provider_name = 'siwe';
     CREATE TABLE siwe_backup_fields AS
       SELECT * FROM user_custom_fields
       WHERE name IN ('wallet_address', 'siwe_owner_address');
     CREATE TABLE siwe_backup_names AS
       SELECT id, name FROM users
       WHERE id IN (SELECT user_id FROM siwe_backup_accounts);"
   ```

   With `MERGE_DUPLICATES=1`, also take a full backup (`discourse backup`):
   merges cannot be undone from these tables.

3. Dry run, and read the table (`rewrite`, `duplicate`, `adopt`, `review`,
   `contract`, ...):

   ```bash
   RPC_URL=https://ethereum-rpc.publicnode.com \
   SUSPECT_AFTER=2026-10-15T16:00:00Z \
     sudo -E -u discourse bundle exec rails runner \
     /shared/tmp/discourse-siwe-auth/script/rewrite_smart_account_users.rb
   ```

   (`SUSPECT_AFTER` per step 0; the value above is an example.) No
   `rewrite` row may have a `from` that is a known Light Account (the
   script aborts if one does). Check every `review` row by hand: compare
   its `from` with the map and the user's history before changing it.

4. Turn off **Discourse siwe enabled**, so nobody signs in with the old page
   between the rewrite and the rebuild.

5. Apply (same command with `APPLY=1`, the same `SUSPECT_AFTER` or
   `NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1`, plus `MERGE_DUPLICATES=1` if wanted).
   Re-run the dry run: every row should now be `already`, apart from the
   `review` rows you chose to leave.

6. Deploy the plugin (new `siwe.iife.js`, strategy and lookups):
   `./launcher rebuild app`. Turn **Discourse siwe enabled** back on and sign
   in once with a migrated wallet: it must land on the existing user.

Rollback (before any merge): turn off **Discourse siwe enabled**, restore the
backup, then rebuild with the previous plugin commit.

```bash
sudo -u postgres psql discourse -c "
  UPDATE user_associated_accounts a SET provider_uid = b.provider_uid, info = b.info
    FROM siwe_backup_accounts b WHERE a.id = b.id;
  DELETE FROM user_custom_fields WHERE name = 'siwe_owner_address'
    AND id NOT IN (SELECT id FROM siwe_backup_fields);
  UPDATE user_custom_fields f SET value = b.value
    FROM siwe_backup_fields b WHERE f.id = b.id;
  UPDATE users u SET name = b.name FROM siwe_backup_names b WHERE u.id = b.id;"
```

Users who signed in as `S` after the deploy and have no row in the backup keep
their `S` account. Drop the `siwe_backup_*` tables once the switch is settled.

## Troubleshooting and engineering notes

This section captures the issues hit during the first deployment and the
information needed to debug or resume work on another machine.

### Boot-time issues encountered

1. **Missing `rubyzip` during C-extension build**
   - Symptom: `rbsecp256k1` fails to compile, complaining that `zip` or
     `rubyzip` is missing.
   - Fix: the `before_code: gem install rubyzip` hook in `app.yml` handles this
     during `./launcher rebuild app`. When running Discourse outside that flow
     (e.g. `d/rails s` in a dev environment), install it once by hand:
     `gem install rubyzip`.
   - Do **not** add `gem 'rubyzip', '2.3.2'` to `plugin.rb` — Discourse's main
     bundle activates rubyzip 3.x and that declaration would cause a
     `Gem::ConflictError` at boot.

2. **`uninitialized constant IdentityStore` in `plugin.rb`**
   - Symptom: `NameError: uninitialized constant IdentityStore` during Discourse
     boot.
   - Fix (already applied): reference the namespaced constant:
     `DiscourseSiwe::IdentityStore::FIELDS.each { ... }`.

3. **`DiscourseSIWE` vs `DiscourseSiwe` namespace mismatch**
   - The repo is consistent and uses `DiscourseSiwe`. If you see this error in a
     local copy, check that every file uses the same PascalCase (`DiscourseSiwe`)
     and not an all-caps `SIWE` variant.

4. **Calling `.each` on the module instead of the constant array**
   - Same root cause as #2: `IdentityStore::FIELDS` was missing the module
     prefix, so Ruby resolved `IdentityStore` to the module object. Fixing the
     namespace also fixes this.

### Wallet sign-in error: "... does not match current domain"

If the wallet (e.g. MetaMask) refuses to sign and shows a message like
`https://localhost:3000 does not match current domain`, it is MetaMask's SIWE
anti-phishing protection ([MetaMask issue #18191](https://github.com/MetaMask/metamask-extension/issues/18191)).
MetaMask verifies that the EIP-4361 message's `domain` and `URI` exactly match
the page origin that requested the signature.

The server builds the SIWE message from `Discourse.base_url`
(`app/controllers/discourse_siwe/auth_controller.rb`). The mismatch means the
browser origin does not equal Discourse's configured base URL. Common causes:

- Browsing `https://localhost:3000` while Discourse is configured as
  `http://localhost:3000` (or `force_https` is off).
- A port mismatch — e.g. an Ember CLI proxy on `:4200` while the backend base
  URL is `:3000`.
- Hostname mismatch — `127.0.0.1` vs `localhost`, or a tunnel/domain not listed
  in `DISCOURSE_HOSTNAME`.

Fix: browse Discourse at the exact URL it is configured for, or adjust
`DISCOURSE_HOSTNAME` / `force_https` to match the real access URL.

### Information to collect when debugging sign-in

To continue debugging on a different machine, gather:

1. The SIWE message text (copy it from the wallet prompt or fetch it with
   `curl "https://HOST/discourse-siwe/message?eth_account=0x...&chain_id=1"`).
   Look at the `domain` and `URI:` lines.
2. The exact URL in the browser's address bar when the sign-in button is clicked.
3. How Discourse is being run (`d/rails s`, `./launcher`, port, HTTPS on/off) and
   the values of `DISCOURSE_HOSTNAME` and `force_https`.
4. The browser console output (full error) and the Network tab entries for
   `/discourse-siwe/message` and the final OmniAuth callback POST.
5. The relevant `log/development.log` lines around the callback — the strategy
   logs failure reasons such as `invalid_nonce`, `expired_message`, or
   `invalid_signature`.

With #1 and #2 the exact mismatch can usually be identified immediately.

## License

MIT / Apache-2.0, same as upstream. See `LICENSE-MIT` and `LICENSE-APACHE`.
