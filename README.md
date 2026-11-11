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
| **Siwe society subgraph token** | _Secret._ Bearer token for the query gateway (`GRAPH_QUERY_GATEWAY_TOKEN`). The gateway rejects requests without it, so profile names do not resolve while this is empty. Set via the `DISCOURSE_SIWE_SOCIETY_SUBGRAPH_TOKEN` env var or the admin UI. |
| **Siwe identity resolution mode** | Preferred resolution mode: `subgraph` (default, falls back to RPC) or `rpc` (direct contract calls only). |

### Refreshing Society names

Society profile lookups go through the query gateway with the bearer token
above. A lookup that cannot be completed (network error, gateway rejection, bad
response) is "unknown" and never overwrites a stored name or avatar. After
setting the token, `rake 'siwe:refresh_society'` shows which members' names
would change (dry run) and `rake 'siwe:refresh_society[false]'` applies it,
moving members who were defaulted to their wallet address onto their Society
name. A member's Light Account is looked up first; when it has no profile, the
owner wallet in `siwe_owner_address` is looked up as well.

## Groups follow badges

Forum groups can follow on-chain Society badges. `siwe_group_badge_mapping`
lists `badge_id:group` pairs separated by `|` (for example
`13:governors|14:vip|15:vip|16:vip`); a member holding any badge of a group
belongs to it. Membership is read from the badges contract with
`balanceOfBatch` (`siwe_society_badges_rpc_url`, `siwe_society_badges_contract`,
`siwe_society_badges_chain_id`) over every address on record for the member:
their `wallet_address` (the Light Account), the owner wallet the sign-in
proved (`siwe_owner_address`), and the pair from
`script/forum-address-map.json`. Badges that were never migrated stay on the
owner wallet, so both are checked. Without an owner or a map entry, a member
is checked on their wallet alone. Everything ships **off**
(`siwe_group_sync_mode` = `off`).

* **Modes:** `off`, `log` (report what would change, change nothing) and
  `enforce`.
* **Never touched:** automatic groups (`admins`, `moderators`, `staff`,
  `trust_level_*`) are refused as targets. Staff, group owners and
  `siwe_group_sync_exempt_usernames` are never removed.
* **Removals are slow on purpose:** a member must be seen without the badge
  `siwe_group_sync_removal_confirmations` runs in a row, and more than
  `max(siwe_group_sync_removal_floor, siwe_group_sync_removal_percent of the
  group)` removals in one run removes nobody from that group. A member whose
  balance could not be read is never removed, and a wrong chain, wrong
  contract or RPC error stops the run before anything changes.
* **Triggers:** a scheduled job (`Jobs::SiweGroupSync`, every 30 minutes) does
  the full reconcile and is the only place removals happen; a per-login job
  (`Jobs::SyncSiweUserGroups`) is add-only.

```bash
rake 'siwe:groups:bootstrap'            # dry run; [false] creates the closed groups
rake 'siwe:groups:sync[log]'            # report only (the default)
rake 'siwe:groups:sync[enforce]'        # apply
rake 'siwe:groups:report'               # the last full report
```

## Token-gated categories

Groups that follow badge holders are described in [Groups follow badges](#groups-follow-badges) (`siwe_group_badge_mapping`). Token-gated **categories** add the missing half: which groups can see which categories. It is configuration, applied by a rake task, never by a background job.

Put the YAML in the `siwe_gating_config` site setting (it lives in the database, so the production layout is not in this public repo), or point `SIWE_GATING_FILE` at a file for one run.

```yaml
groups:
  vip-gold:
    full_name: VIP Gold          # optional
    visibility: members          # members (default) | staff | owners
  governors: {}
categories:
  gold-lounge:                   # category slug
    name: Gold Lounge            # used only if the category is created
    parent: community            # optional parent slug
    confirm_restrict: true       # needed to restrict a category that is public today
    access:                      # group: full | reply | read
      vip-gold: full
      governors: read            # higher tiers: just list several groups
```

* `siwe:gating:provision` shows the plan. `siwe:gating:provision[apply]` applies it. It is idempotent: a second run changes nothing.
* It only touches the groups and categories named in the YAML, and only a category's permissions (never its name, description, topics or order). Staff always keep full access. `everyone` is never listed: a gated category is gated by leaving it out.
* New groups are closed (no public join, no requests). Automatic groups (`admins`, `moderators`, `staff`, `trust_level_*`) are refused.
* Restricting a category that is public today is **blocked** until `confirm_restrict: true` is set, so it cannot happen by accident.
* `siwe:gating:status` shows drift between the YAML and the forum and what the badge sync would add or remove.
* `siwe:gating:audit` is the mandatory check before restricting anything. It lists members of a gated group who hold no badge (they would lose access), members with no wallet (they would keep access forever), and gated groups no badge feeds. It exits non-zero until each item is resolved: remove them, grandfather them with `siwe_group_sync_exempt_usernames`, or give them the badge.
* If an admin edits a gated category's permissions in the admin UI, `status` reports it as drift and `provision[apply]` puts it back. The YAML wins.
* Group lists and flair reveal who holds a badge by wallet. Choose each group's `visibility` accordingly.

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
ruby -r./test/support/pure_keccak -rtime test/ens_unit_test.rb
ruby -r./test/support/pure_keccak -rtime test/society_unit_test.rb
ruby -r./test/support/pure_keccak -rtime test/society_lookup_unit_test.rb
ruby -r./test/support/pure_keccak -rtime test/light_account_unit_test.rb
ruby -r./test/support/pure_keccak -rtime test/smart_account_transfer_unit_test.rb
ruby -r./test/support/pure_keccak -rtime test/smart_account_sync_state_unit_test.rb
ruby -r./test/support/pure_keccak -rtime test/group_sync_unit_test.rb
ruby -r./test/support/pure_keccak -rtime test/gating_unit_test.rb
ruby -r./test/support/pure_keccak -rtime test/badge_mirror_unit_test.rb
```

`test/support/pure_keccak.rb` and `test/support/lib/digest/keccak.rb` are a
test-only pure-Ruby Keccak-256 shim. Requiring `pure_keccak` lets these suites
run on a machine that does not have the `keccak` gem installed (the plugin
itself still uses the real gem in Discourse); without it a bare Ruby stops
with `LoadError: cannot load such file -- digest/keccak`. `-rtime` loads
`Time.iso8601` for older Rubies.

`test/light_account_unit_test.rb` checks the Light Account derivation against
every pair in `script/forum-address-map.json` and the rewrite planner.
`test/smart_account_transfer_unit_test.rb` runs the whole transfer (plan,
backup, writes, merges, usernames, verification, re-runs after a failure)
against an in-memory forum; see
[Transferring users to smart accounts](#transferring-users-to-smart-accounts).

### Integration tests (require an Ethereum RPC endpoint)

```bash
ruby -r./test/support/pure_keccak -rtime test/ens_integration_test.rb
ruby -r./test/support/pure_keccak -rtime test/society_integration_test.rb
```

By default, integration tests use a public RPC. Set `RPC_URL` for a dedicated
provider:

```bash
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY \
  ruby -r./test/support/pure_keccak -rtime test/society_integration_test.rb
```

To test the positive Society resolution path, set an address that holds a
profile badge:

```bash
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY \
SOCIETY_ADDRESS=0x... \
  ruby -r./test/support/pure_keccak -rtime test/society_integration_test.rb
```

### Run all unit tests

```bash
for f in test/*_unit_test.rb; do ruby -r./test/support/pure_keccak -rtime "$f"; done
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

### Transferring users to smart accounts

Members sign in as their Light Account `S` (owned by their wallet `E`), not
as `E`. The SIWE `uid` is the EIP-55 checksummed address and Discourse matches
it exactly, so a forum user who was created for `E` has to be transferred to
`S`. Otherwise the same wallet's next sign-in creates a new, empty user.

The transfer does that for every `siwe` account on the forum (not only
Outpost members). After it, a member who signs in with the same wallet lands
on their original user, with all of its posts, likes, groups, badges,
notifications and settings. It is one tool with two entry points:

```bash
# the forum already runs this plugin version
rake siwe:smart_accounts:transfer            # dry run: prints the plan, writes nothing
rake 'siwe:smart_accounts:transfer[apply]'   # backup, write, verify
rake siwe:smart_accounts:verify              # read-only check, exit 1 on failure

# the forum still runs an older version: same code, loaded from a checkout
rails runner /path/discourse-siwe-auth/script/rewrite_smart_account_users.rb            # dry run
APPLY=1 rails runner /path/discourse-siwe-auth/script/rewrite_smart_account_users.rb
VERIFY=1 rails runner /path/discourse-siwe-auth/script/rewrite_smart_account_users.rb
```

#### What it moves

For each account it derives `S = LightAccountFactory.getAddress(E, 0)` in Ruby
and writes only what is still different:

| What | Where | After the transfer |
| --- | --- | --- |
| Sign-in identity | `user_associated_accounts.provider_uid` | checksummed `S` |
| Wallet | `wallet_address` custom field | `S`, lowercase (what the login writes) |
| Owner | `siwe_owner_address` custom field | `E`, lowercase |
| Display name | `users.name` | `E` in full (any case) becomes checksummed `S`, or `S`'s short form when **siwe society enabled** is on; a wallet-style name (`0x9ba7…7c3c`) becomes `S`'s short form |
| Username | `users.username` | a username Discourse cut from `E` (`0x` plus at least 8 hex digits that are a prefix of `E`) becomes the one Discourse suggests for `S`, through `UsernameChanger`, so mentions and quotes follow. `KEEP_USERNAMES=1` leaves usernames alone |
| Account info | `nickname` / `name` in the row's `info` json | `S` when they held `E` |
| Society cache | `society_resolved_at` custom field | deleted for accounts moved in this run, so the next sign-in looks the profile up again for `S` (with `E` as fallback) |
| A duplicate user | a second user who already signed in as `S` | merged into the original with Discourse's `UserMerger` (`MERGE_DUPLICATES=1`): posts, likes, groups, badges, notifications, bookmarks and emails end on one user |
| A leftover row | a `siwe` row holding `S` with no user | deleted, because it blocks the unique index. `UserMerger` leaves such a row when both merged users had a `siwe` row, for example after a merge in the admin UI (Discourse's own daily cleanup removes it later) |
| Sync counters | plugin store rows `group_sync_pending` and `badge_mirror_pending` (how many runs a user was seen without a badge) | dropped for the users moved or merged in this run, so nobody leaves a group or loses a mirrored badge on counts gathered for the old address: the full number of confirmations applies again |
| Badge sync debounce | `siwe_badges_synced_at` custom field | deleted for the same users: their next sign-in mirrors badges at once |

Accounts that an earlier run already moved (`already`, `adopt`, `recase`) are
checked for the same fields, so a re-run finishes whatever an older version or
a failed run left on `E`.

It deliberately leaves:

- a name the user chose, a Society or ENS name, another wallet's address;
- `ens_name`, `ens_avatar`, the `society_*` values and `preferred_identity`:
  they are names and pictures, not addresses, and the login resolves them for
  `S` with `E` as fallback. Avatars need nothing: letter avatars follow the
  username, uploaded ones belong to the user;
- group memberships and mirrored badges: they are keyed by user id and follow
  a merge through `UserMerger`. The group sync and the badge mirror judge a
  member by `wallet_address`, `siwe_owner_address` and the address map, so a
  badge that is still on `E` keeps counting after the transfer. The badge
  records (`badge_mirror:token:<id>`), the mirror's meta and hold rows and the
  last reports hold no member address;
- contract wallets (`contract`), rows whose uid is not an address (`invalid`),
  rows with no user (`orphan`) and deployed Light Accounts whose owner is not
  known yet (`light_account`; recorded at their next sign-in). These are the
  recognised skips. A contract wallet keeps its own address as uid. The
  sign-in page always signs in as the Light Account of the connected address,
  so such a member does not reach that account through it: decide separately
  how they sign in.

#### How it decides

The dry run prints one line per `siwe` row with a status:

| Status | Meaning | Written |
| --- | --- | --- |
| `rewrite` | uid is an EOA | everything above |
| `duplicate` | uid is an EOA and another user already signed in as its `S`; or two users hold the same address in different case (the first rewrite stored `S` lowercase, and a later sign-in created a second user on the checksummed `S`) | with `MERGE_DUPLICATES=1`: the newer user is merged into the older one, then as `rewrite`. Without it: nothing, and verification fails |
| `conflict` | three or more users on one address, or two with no proven owner | nothing; verification fails. Merge them in the admin UI until at most two are left, then run again |
| `smart_of` | the `S` row of such a pair, owner not recorded | handled with its `duplicate` |
| `already` | uid is `S` and `siwe_owner_address` proves it | only fields or names that are still off |
| `adopt` | uid is `S`; the owner is proven by the row's sign-in record (`extra.owner_address`), the address map, or an orphan row for `E` | the owner, plus fields and names |
| `recase` | as above, but the uid is not checksummed | the checksummed uid as well |
| `review` | a uid in another case that is not in the map, or (with `SUSPECT_AFTER`) a row created after that time with no proof of its owner | nothing; verification fails until you list the row id in `REVIEWED_ROWS` |
| `unknown_code` | `eth_getCode` failed | nothing; verification fails, run again |
| `contract`, `invalid`, `orphan`, `light_account` | recognised skips | nothing |

An owner is only ever accepted when CREATE2 binds it to the uid, so a wrong
custom field or map entry cannot move an account. The tool refuses to run
unless its derivation matches every pair in `script/forum-address-map.json`
(flat or chain-keyed).

#### Safety

- **Dry run by default.** It prints the table, a per-user plan (every value
  with its old and new content), a summary, and what verification would say
  after an apply.
- **Backup first.** An apply that has something to write starts by copying,
  inside the same transaction, every `siwe` row
  (`siwe_backup_<run>_accounts`), every custom field of the users behind them
  (`siwe_backup_<run>_fields`) and their id, username, name and creation time
  (`siwe_backup_<run>_users`). `<run>` is the UTC start time
  (`20261111153000`). When users are merged it also copies their group
  memberships and badges (`siwe_backup_<run>_group_users`,
  `siwe_backup_<run>_user_badges`) as a record of who had what. The two
  counter rows of the plugin store go to `siwe_backup_<run>_plugin_store`.
- **Transactions.** The backup and every account that is not part of a merge
  are one transaction: if anything fails, nothing is written and no backup
  table is left. A merge cannot be part of it: `UserMerger` is run the way
  Discourse runs it, outside a wrapping transaction (it moves posts topic by
  topic and deletes a user). Each merge is followed by one transaction for the
  surviving account. Usernames change last, through `UsernameChanger`, which
  rewrites mentions in a background job.
- **Idempotent.** Every step writes only what is still different. A second
  apply writes nothing and takes no backup. After a failure, run the same
  command again: it continues where it stopped, also after a merge that died
  half way (the detached `S` row is replaced). If `UserMerger` died before it
  deleted the duplicate, that user still exists without a wallet: merge it
  again from its admin page. No later run and no verification can see such a
  user (it has no `siwe` row any more); the failed run prints its id.
- **A re-run takes a new backup of a forum that is already partly
  transferred.** The rollback point of the whole transfer is the backup of
  the first apply, not of the last one. An apply lists the earlier backups it
  finds (`Earlier backups exist: ...`) and says so.
- **Verification.** An apply ends by planning again from the database. It
  exits 1, with `VERIFICATION FAILED` and one `UNRESOLVED` line per account,
  if any `siwe` account is still on an old wallet without being a recognised
  skip, or still has a value to write. `rake siwe:smart_accounts:verify` runs
  only this check.

#### Options (environment variables)

| Variable | Effect |
| --- | --- |
| `MERGE_DUPLICATES=1` | merge duplicate users. The older user (by creation time, then id) survives. A survivor whose username was cut from `E` gets the plain username for `S`, also when its duplicate held that name |
| `FULL_BACKUP_TAKEN=1` | confirms a full backup exists; an apply that would merge is refused without it |
| `SUSPECT_AFTER=<ISO time>` | a time with `Z` or an offset (`2026-10-15T16:00:00Z`); without a zone it is read as UTC. Rows created later with no proof of their owner are left as `review`. Set it to the first deploy of a build with the Light Account login (`8a4f838` or later): `8a4f838` signed in as `S` without recording the owner, and an `S` that is not in the map would otherwise be taken for an EOA and moved to the Light Account of `S` |
| `NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1` | instead of `SUSPECT_AFTER`: nobody ever signed in through such a build here. An apply is refused with neither |
| `REVIEWED_ROWS=12,15` | `review` rows you checked and accept as they are |
| `KEEP_USERNAMES=1` | do not rename usernames |
| `RPC_URL=<json-rpc>` | used only to tell contract wallets from EOAs (`eth_getCode`); default **siwe ethereum rpc url**. It is never printed |
| `SKIP_CODE_CHECK=1` | run without an RPC; contract wallets would be rewritten too |
| `FORUM_ADDRESS_MAP=<path>` | another address map for the self-test |

`SUSPECT_AFTER`, `REVIEWED_ROWS`, `KEEP_USERNAMES`, `MERGE_DUPLICATES` and
`SKIP_CODE_CHECK` change the plan. A dry run, an apply and a verify only
agree when they get the same ones: a `verify` without the `SUSPECT_AFTER` or
`REVIEWED_ROWS` of the apply reports rows as unresolved or still to write
that the apply left on purpose. Every run prints the ones it was given, ready
to copy to the next command.

#### Production procedure

Do staging first, then production. Light Account addresses are the same on
every chain. Run the commands in the Discourse container, in
`/var/www/discourse`, as the `discourse` user (`sudo -E -u discourse bundle
exec ...`). A rake or runner process needs about 1 GB on top of the running
app: raise the container's memory limit first if it has one.

1. **Stop wallet sign-ins.** Turn off **Discourse siwe enabled** (if an
   environment variable sets it, change the variable). Existing sessions keep
   working; nobody can create a duplicate user while you work. The hourly
   badge mirror pauses while the setting is off and the group sync keeps
   running; neither has to be stopped for the transfer.
2. **Deploy this plugin version** (rebuild or roll out the image). Sign-ins
   stay off. If you cannot deploy first, clone the plugin where the container
   can read it and use the script instead of the rake task in the steps below.
3. **Take a full backup** (`discourse backup`, the admin Backups page, or a
   dump of the database) and keep it. It is the only way back from a merge.
4. **Dry run** with the options you will apply with, and read all of it:

   ```bash
   # production: nobody has signed in through the Light Account login yet
   sudo -E -u discourse bundle exec rake siwe:smart_accounts:transfer

   # staging, or any forum where that login was already live
   SUSPECT_AFTER=<first deploy time, with Z> \
     sudo -E -u discourse bundle exec rake siwe:smart_accounts:transfer
   ```

   Add `MERGE_DUPLICATES=1` if the table has `duplicate` rows. No `rewrite`
   row may have a `from` that is a Light Account (the tool aborts if it is one
   from the map). Check each `review` row by hand: compare its `from` with the
   map and the user's history, then either fix it or list its id in
   `REVIEWED_ROWS` and dry-run again. `AFTER AN APPLY` must end with
   `0 unresolved`.
5. **Apply**, with exactly the options of the last dry run plus the
   confirmations:

   ```bash
   NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1 \
     sudo -E -u discourse bundle exec rake 'siwe:smart_accounts:transfer[apply]'
   ```

   Use `SUSPECT_AFTER=<first deploy time>` instead of
   `NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1` if members could already sign in through
   the Light Account login (a staging forum, or a production forum where step
   1 was skipped), and add `MERGE_DUPLICATES=1 FULL_BACKUP_TAKEN=1` to merge.
   It must end with `VERIFICATION: ... 0 unresolved` and exit 0. Note the
   backup run id it prints.
6. **Check**, again with the options of the apply (`SUSPECT_AFTER`,
   `REVIEWED_ROWS`, `KEEP_USERNAMES`, `MERGE_DUPLICATES`; the apply prints
   them on its last line). `rake siwe:smart_accounts:verify` exits 0, and a
   second dry run says `PLAN: nothing to write.`:

   ```bash
   SUSPECT_AFTER=<same> REVIEWED_ROWS=<same> \
     sudo -E -u discourse bundle exec rake siwe:smart_accounts:verify
   ```
7. **Turn Discourse siwe enabled back on** and sign in once with a
   transferred wallet: it must land on the existing user, with its posts.
8. Drop the `siwe_backup_<run>_*` tables once the switch is settled.

#### Rollback

Turn off **Discourse siwe enabled** first, and roll the plugin back to the
previous version afterwards.

Roll back right after the apply, while sign-ins are still off. The restore
resets every `siwe` user in the backup, not only the ones the run changed: run
days later, it also reverts display names and usernames that members changed
themselves since, and removes an owner address the login recorded since.

`<run>` is the run id of the **first** apply of this transfer. If an apply
failed and was run again, the later run's backup already holds what the first
one wrote, and the SQL the later run printed only goes back to that state:
use the same SQL with the first run id (the re-run names it in `Earlier
backups exist`).

*No merge happened.* Run the SQL the apply printed (it is also what
`DiscourseSiwe::SmartAccountRewrite.restore_sql('<run>')` returns). With a
database outside the container, paste it into `bundle exec rails dbconsole -p`
instead of `psql`:

```bash
sudo -u postgres psql discourse <<'SQL'
BEGIN;
UPDATE user_associated_accounts a SET provider_uid = b.provider_uid, info = b.info
  FROM siwe_backup_<run>_accounts b WHERE a.id = b.id;
DELETE FROM user_custom_fields f USING siwe_backup_<run>_users u
  WHERE f.user_id = u.id AND f.name IN ('wallet_address', 'siwe_owner_address', 'society_resolved_at');
INSERT INTO user_custom_fields (user_id, name, value, created_at, updated_at)
  SELECT b.user_id, b.name, b.value, b.created_at, b.updated_at
  FROM siwe_backup_<run>_fields b JOIN users u ON u.id = b.user_id
  WHERE b.name IN ('wallet_address', 'siwe_owner_address', 'society_resolved_at');
UPDATE users u SET name = b.name FROM siwe_backup_<run>_users b WHERE u.id = b.id;
COMMIT;
SQL
```

Then put the usernames back, which also rewrites mentions and quotes:

```bash
sudo -E -u discourse bundle exec rails runner '
  DB.query("SELECT id, username FROM siwe_backup_<run>_users").each do |b|
    user = User.find_by(id: b.id)
    next if user.nil? || user.username == b.username
    UsernameChanger.change(user, b.username, Discourse.system_user)
  end'
```

What this restore does and does not undo:

- It restores `provider_uid` and `info` of every `siwe` row that still exists,
  the three custom fields the transfer writes, and display names; the runner
  line restores usernames.
- It does **not** undo a merge. The merged user is deleted and its posts,
  likes, groups and badges are on the survivor; no table here can split them
  again. After a merge the SQL above still puts the survivor back on `E`, but
  nobody is left on `S`. The only full undo of a merge is restoring the full
  backup from step 3, which also loses everything posted since.
- It does not bring back a deleted `siwe` row (an orphan row, or a merged
  user's row). Nothing depends on them.
- It does not put the dropped sync counters or the badge debounce back. They
  rebuild on the next runs, and a missing counter can only delay a removal.
- Users who signed in as `S` after the transfer and are not in the backup keep
  their `S` account.

## On-chain badges (F1)

The plugin mirrors Society Protocol badges into native Discourse badges, so
`/badges`, badge pages, user cards, featured badges and notifications keep
working unchanged. Two things are mirrored:

1. **The catalog.** Every official on-chain badge (and the community badges you
   allow) becomes a `Badge` row in a "Society Protocol" badge grouping. Name,
   description and image come from the badge metadata. Badges that disappear
   from the chain are archived (`enabled = false`), never deleted.
2. **The holders.** A member gets the native badge when the wallets linked to
   their account hold it on chain, and loses it when they no longer do.

Everything ships **off** (`siwe_badges_sync_mode` = `off`).

### How it decides

* **Catalog source:** the query gateway's registered `Badges` operation with
  `where: {isProfile: false}`, sent with the bearer token in
  `siwe_society_subgraph_token` to `siwe_society_subgraph_url`. The document
  in `lib/discourse_siwe/badge_catalog.rb` is a copy of the gateway registry
  entry and must change together with it (a unit test compares them when the
  subgraph repo sits next to this one). The subgraph always returns
  `imageUrl` and `description` as null at the top level; the real values are
  in `metadata`. A null `metadata` means "unknown, keep what we have", never
  "clear".
* **Holdings source:** the badges contract, via `balanceOfBatch`
  (`siwe_society_badges_rpc_url`, `siwe_society_badges_contract`,
  `siwe_society_badges_chain_id`), over the member's wallet and proven owner
  EOA, and only for mirrored badge ids. The subgraph's holder set is never
  used to decide who holds a badge. A balance that could not be read is
  "unknown" and never revokes.
* **Scope:** official badges, plus the community badge token ids in
  `siwe_badges_community_allowlist`. Community names, descriptions and images
  are chosen by their creators: the input is cut to 4096 characters first,
  HTML entities are decoded to a fixed point (so a double-encoded tag cannot
  survive), and the text is reduced to plain text: no HTML, markdown, links or
  e-mail addresses, Unicode NFKC, every invisible, bidi, control and format
  character removed by category, every kind of space collapsed, `%` and `&`
  neutralised (Discourse interpolates `%{...}` in descriptions and unescapes
  entities after sanitising). Lengths are capped (name 50, description 500,
  long description 1000). The long description is sanitised HTML (that is how
  Discourse renders it) whose only link is ours, built from
  `siwe_badges_app_url` after validation (https, plain host, no userinfo,
  query or fragment). Images must be https (IPFS forms are rewritten to one
  gateway), at most 2 MB, and actually a PNG, JPEG, GIF, WebP or SVG;
  downloads go through `FileHelper.download`, which refuses private and
  loopback addresses and re-checks redirects. A whole download is cut off
  after 25 seconds, and a source that failed is not tried again for 24 hours
  (unless the badge points at another URL).
* **Names:** Discourse badge names are unique and double as translation keys.
  A name that is taken (case, spaces, invisible characters and Unicode
  compatibility forms ignored) gets the suffix ` (#<token id>)`.
  A chosen name is kept until the chain name really changes.
* **State:** the badge-to-token mapping lives in the plugin store (key
  `badge_mirror:token:<id>`: badge id, uri, image source and hash, upload id,
  last seen, archived). There is no table and no migration. `Badge.query` is
  NULL, `system` false, `multiple_grant` false; official badges are Gold,
  community badges Silver (constants in `badge_catalog.rb`).
* **Duplicates:** accounts that share any address (the Light Account rewrite
  can leave duplicates) are one person; the lowest user id keeps the badges.
  This does not depend on which address is the account's wallet today. The
  person is judged by the holdings of ALL the group's addresses, so a badge
  that sits only on a duplicate's Light Account still counts, even when the
  address map is missing or stale. A duplicate's badge is never revoked on an
  unreadable balance.
* **Who is evaluated:** active, not staged, not anonymous, not suspended, not
  silenced, with a wallet on record. Everyone else is left exactly as is.

### Safety

* Any source problem blocks every revoke of that run: gateway error or bad
  response, a catalog that is empty or less than half the size of the last
  one (or that would archive most mirrored badges), an RPC error, a wrong
  chain or contract, a blank RPC URL, or no balance readable at all.
* A member must be seen without the badge `siwe_badges_revoke_confirmations`
  runs in a row (default 2, so about two hours) before it is revoked.
* Brake: more than `max(siwe_badges_revoke_floor, siwe_badges_revoke_percent
  of current grants)` revokes in one run revokes nobody, per badge and across
  the whole run. A brake, or a blocked run, raises a revoke hold, shown in
  the report and cleared by the next clean full run.
  After checking the report, `rake 'siwe:badges:sync[enforce,force]'` skips
  the counters and the brakes once.
* Only the hourly full run revokes. The per-login job is add-only: it never
  revokes and never reads, advances or writes the counters or the hold, so it
  cannot race the full run or confirm an absence on its own.
* A badge whose Badge row was deleted is rebuilt as a fresh badge: its first
  pass over the holders is silent again (no notification for every holder).
* Mode `log` reads and reports; it writes no badge, grant, upload, setting or
  counter. Only the report is stored.

### Settings

| Setting | Meaning |
| --- | --- |
| `siwe_badges_sync_mode` | `off` (default), `log` (report only), `enforce`. |
| `siwe_badges_community_allowlist` | Community badge token ids to mirror (pipe separated). |
| `siwe_badges_revoke_floor`, `siwe_badges_revoke_percent` | The revoke brake (5 and 20 by default). |
| `siwe_badges_revoke_confirmations` | Runs in a row before a revoke or an archive (2). |
| `siwe_badges_notify_on_grant` | Notify members of new grants (true). The first pass over each badge is always silent. |
| `siwe_badges_app_url` | Base URL of the Society app for the link on each badge page (blank: no link). Used only when it is an https URL with a plain host, no userinfo, query, fragment or special characters; anything else means no link. |
| `siwe_badges_disable_system` | Keep Discourse's built-in badges disabled (see below). |

### Triggers

* An hourly scheduled job (`Jobs::SiweBadgeMirror`) does the full reconcile
  under a `DistributedMutex`. Only it archives badges and decides revokes for
  everyone (after `siwe_badges_revoke_confirmations` runs in a row).
* A per-login job (`Jobs::SyncSiweUserBadges`, enqueued from
  `after_authenticate` and `after_create_account`, never calling the network
  inline) grants that member what they hold, add-only, at most once an hour,
  in `enforce` mode.

### Rake tasks

```bash
rake 'siwe:badges:sync[log]'              # report only (the default)
rake 'siwe:badges:sync[enforce]'          # apply
rake 'siwe:badges:sync[enforce,force]'    # apply, skipping counters and brakes
rake 'siwe:badges:report'                 # the last full report
rake 'siwe:badges:disable_system[false]'  # disable the built-in badges (dry run without [false])
rake 'siwe:badges:purge_system_grants[false]' # DESTRUCTIVE, opt-in (dry run without [false])
```

Grants and revokes are written to the staff action log as `siwe_badge_sync`.

### Rollout order

1. Deploy with `siwe_badges_sync_mode` = `off`. Set the subgraph URL and token
   and the badges RPC URL, chain id and contract; set `siwe_badges_app_url`.
2. Turn the mode to `log`. Read `rake siwe:badges:report`: the badges that
   would be created, their names (collisions), and who would get what.
   Check the member list and the duplicate accounts it skipped.
3. Turn the mode to `enforce`. The first run creates the badges and grants
   silently (the backfill). From the next run on, new holders are notified
   (`siwe_badges_notify_on_grant`).
4. Disable the built-in badges: `rake 'siwe:badges:disable_system'` shows what
   it would do, then `rake 'siwe:badges:disable_system[false]'`. This only
   disables; it keeps `enable_badges` on (turning that off makes grants
   return early and `/badges` 404) and deletes nothing. Set
   `siwe_badges_disable_system` so new built-in badges added by a Discourse
   upgrade are disabled again by the hourly job. (Discourse's own seed does
   not set `enabled` on existing badges, so an upgrade does not re-enable the
   ones already disabled.)
5. Optional and destructive: after a database backup, look at
   `rake siwe:badges:purge_system_grants` (counts only), then
   `rake 'siwe:badges:purge_system_grants[false]'` to delete the built-in
   badges' user grants and their notifications. Check titles and featured
   badges first.

### Caveats

* The native badge page lists forum users only. Wallet holders who never
  joined the forum do not appear, so the on-chain holder count and the
  outpost are the source of truth.
* Manual edits to a synced badge (name, description, enabled, type) are
  overwritten on the next run, and manual grants of a synced badge to members
  with a wallet are revoked by the reconcile.
* Members without a wallet on record (staff or legacy accounts) get no badges
  and are never touched. `granted_at` is the sync time: the subgraph has no
  mint timestamp.
* Badge images are fetched once per source URL (at most 25 per run, so the
  first import of a large catalog takes a few runs). A failed fetch keeps the
  old image and is retried.
* Badges held on an owner EOA are only found for members whose owner address
  is proven (`siwe_owner_address`, or the committed address map).
* The on-chain holder count is not shown: the `Badges` operation does not
  select `holdersCount`.

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
