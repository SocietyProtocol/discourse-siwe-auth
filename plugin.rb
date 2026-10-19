# frozen_string_literal: true

# name: Web3 Outpost sign-in for Discourse
# about: Sign in with Ethereum and display your web3 identity (wallet, ENS, or Society Protocol outpost) in Discourse. Forked and extended from signinwithethereum/discourse-siwe-auth by Society Protocol.
# version: 1.5.0
# authors: Society Protocol
# url: https://github.com/SocietyProtocol/discourse-siwe-auth

enabled_site_setting :discourse_siwe_enabled
register_svg_icon 'fab-ethereum'
register_asset 'stylesheets/discourse-siwe-auth.scss'

%w[
  ../lib/omniauth/strategies/siwe.rb
].each { |path| load File.expand_path(path, __FILE__) }

# Discourse's plugin `gem` DSL signature is `gem(name, version, opts = {})` and
# it shells out to `gem install ... --ignore-dependencies`, so:
#   1) every gem MUST have an explicit version string as the 2nd positional arg
#      (passing `require: false` without a version makes Ruby treat the kwargs
#      hash as the version, breaking install with "Illformed requirement"),
#   2) every transitive dependency must be declared explicitly here in
#      install order (deps before dependents), since --ignore-dependencies
#      means Discourse will not auto-resolve them.
# `rubyzip` (a build-time dep of rbsecp256k1's extconf.rb) is installed
# system-wide via the `before_code` hook in app.yml; see README.

gem 'pkg-config',    '1.6.5',  require: false
gem 'mini_portile2', '2.8.9',  require: false
gem 'ffi',           '1.17.4', require: false
gem 'ffi-compiler',  '1.3.2',  require: false
gem 'konstructor',   '1.0.2',  require: false
gem 'scrypt',        '3.1.0',  require: false
gem 'keccak',        '1.3.3',  require: false

# rbsecp256k1 6.0.0 (and every published version since 5.0.0) declares a
# spurious runtime dependency on `rubyzip ~> 2.3`. It only uses rubyzip in
# its `extconf.rb` to unpack libsecp256k1's source archive at build time —
# it has zero runtime use of rubyzip. But Discourse's main bundle activates
# rubyzip 3.x at boot, so when Discourse's plugin DSL calls `spec.activate`
# on rbsecp256k1, RubyGems raises Gem::ConflictError.
#
# Workaround: pre-install rbsecp256k1 ourselves and strip the bogus rubyzip
# line from the installed gemspec on disk. Discourse's plugin loader then
# sees the gem already installed, loads the patched spec, and activates it
# without conflict. Idempotent across rebuilds.
RBSECP256K1_VERSION = '6.0.0'
rbsecp_gems_dir = File.expand_path("../gems/#{RUBY_VERSION}", __FILE__)
rbsecp_spec_file = "#{rbsecp_gems_dir}/specifications/rbsecp256k1-#{RBSECP256K1_VERSION}.gemspec"

unless File.exist?(rbsecp_spec_file)
  install_cmd = "gem install rbsecp256k1 -v #{RBSECP256K1_VERSION} " \
                "-i #{rbsecp_gems_dir} --no-document " \
                "--ignore-dependencies --no-user-install"
  Bundler.with_unbundled_env { system(install_cmd) } ||
    raise("rbsecp256k1 #{RBSECP256K1_VERSION} pre-install failed")
end

# Precise pattern: only the exact add_runtime_dependency line for rubyzip.
# Avoids accidentally stripping other lines if upstream changes formatting.
rbsecp_rubyzip_dep_re =
  /^\s*s\.add_runtime_dependency\(?\s*%q<rubyzip>.*?\)?\s*\n/
rbsecp_spec_content = File.read(rbsecp_spec_file)
if rbsecp_spec_content =~ rbsecp_rubyzip_dep_re
  patched = rbsecp_spec_content.sub(rbsecp_rubyzip_dep_re, '')
  # Atomic replace via tempfile + rename so a concurrent reader never sees a
  # half-written gemspec.
  tmp = "#{rbsecp_spec_file}.patching.#{Process.pid}"
  File.write(tmp, patched)
  File.rename(tmp, rbsecp_spec_file)
  Gem::Specification.reset
  Rails.logger.info(
    "[discourse-siwe-auth] Stripped spurious rubyzip runtime dep from " \
    "rbsecp256k1-#{RBSECP256K1_VERSION}.gemspec to avoid Gem::ConflictError " \
    "with Discourse's bundled rubyzip."
  ) if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
end

gem 'rbsecp256k1', RBSECP256K1_VERSION, require: false

# eth >= 0.5.16 is the first version that explicitly depends on `base64`,
# which Ruby 3.4 demoted from default-gem to bundled-gem. Its full transitive
# closure (bls12-381, httpx, etc.) must be declared since --ignore-dependencies
# prevents auto-install.
gem 'base64',        '0.3.0',  require: false
gem 'ecdsa',         '1.2.0',  require: false
gem 'h2c',           '0.2.1',  require: false
gem 'bls12-381',     '0.3.1',  require: false
gem 'http-2',        '1.1.3',  require: false
gem 'httpx',         '1.7.6',  require: false
gem 'eth',           '0.5.17', require: false
gem 'siwe',          '1.1.2',  require: false

class ::SiweAuthenticator < ::Auth::ManagedAuthenticator
  def name
    'siwe'
  end

  def register_middleware(omniauth)
    omniauth.provider :siwe,
                      setup: lambda { |env|
                        strategy = env['omniauth.strategy']
                      }
  end

  def enabled?
    SiteSetting.discourse_siwe_enabled
  end

  def primary_email_verified?
    false
  end

  def description_for_auth_hash(auth_token)
    auth_token&.provider_uid || super
  end

  def after_authenticate(auth_token, existing_account: nil)
    adopt_case_insensitive_uid(auth_token)
    result = super

    wallet = auth_token&.uid&.downcase
    return result unless wallet.present?

    owner = auth_token[:extra]&.[](:owner_address)&.downcase

    info = auth_token[:info] || {}
    ens_name   = info[:nickname].presence
    ens_name   = nil if ens_name&.downcase == wallet
    ens_avatar = info[:image].presence

    if result.user
      cf = result.user.custom_fields
      cf['wallet_address'] = wallet
      cf['siwe_owner_address'] = owner if owner
      cf['ens_name']   = ens_name   if ens_name
      cf['ens_avatar'] = ens_avatar if ens_avatar
      cf['preferred_identity'] ||= DiscourseSiwe::IdentityStore.default_preference(cf)
      result.user.save_custom_fields

      if SiteSetting.siwe_society_enabled && DiscourseSiwe::IdentityStore.society_stale?(result.user)
        Jobs.enqueue(:refresh_siwe_identity, user_id: result.user.id)
      end
    else
      result.extra_data = (result.extra_data || {}).merge(
        wallet_address: wallet,
        owner_address: owner,
        ens_name: ens_name,
        ens_avatar: ens_avatar,
      )
      result.name       = ens_name   if ens_name
      result.avatar_url = ens_avatar if ens_avatar
    end

    result
  end

  def after_create_account(user, auth_result)
    super
    return unless SiteSetting.siwe_society_enabled

    extra = auth_result[:extra_data] || {}
    wallet = extra['wallet_address'] || extra[:wallet_address]
    return unless wallet.present?

    user.custom_fields['wallet_address'] = wallet.downcase
    user.custom_fields['ens_name']       = extra['ens_name']   || extra[:ens_name]
    user.custom_fields['ens_avatar']     = extra['ens_avatar'] || extra[:ens_avatar]
    owner = extra['owner_address'] || extra[:owner_address]
    user.custom_fields['siwe_owner_address'] = owner if owner.present?

    society = DiscourseSiwe::IdentityResolver.resolve_with_owner(wallet, owner)
    DiscourseSiwe::IdentityStore.store_society(user, society)
    user.custom_fields['preferred_identity'] =
      DiscourseSiwe::IdentityStore.default_preference(user.custom_fields)
    user.save_custom_fields

    DiscourseSiwe::DisplayNameApplier.apply(user)
    user.save!
  end

  private

  # Discourse looks up provider_uid exactly and uid is now always EIP-55
  # checksummed. Adopt a single legacy row stored in another case (e.g. a
  # lowercase rewrite) so its owner signs in to the same user.
  def adopt_case_insensitive_uid(auth_token)
    uid = auth_token&.uid
    return if uid.blank?

    scope = UserAssociatedAccount.where(provider_name: name)
    return if scope.exists?(provider_uid: uid)

    rows = scope.where('lower(provider_uid) = ?', uid.downcase).limit(2).to_a
    rows.first.update!(provider_uid: uid) if rows.size == 1
  end
end

auth_provider authenticator: ::SiweAuthenticator.new,
              icon: 'fab-ethereum',
              title_setting: :siwe_statement,
              full_screen_login: true

after_initialize do
  load File.expand_path('../lib/discourse_siwe/eth_rpc.rb', __FILE__)
  load File.expand_path('../lib/discourse_siwe/light_account.rb', __FILE__)
  load File.expand_path('../lib/discourse_siwe/ens_resolver.rb', __FILE__)
  load File.expand_path('../lib/discourse_siwe/identity_resolver.rb', __FILE__)
  load File.expand_path('../lib/discourse_siwe/identity_store.rb', __FILE__)
  load File.expand_path('../lib/discourse_siwe/display_name_applier.rb', __FILE__)
  load File.expand_path('../app/controllers/discourse_siwe/auth_controller.rb', __FILE__)
  load File.expand_path('../app/jobs/regular/refresh_siwe_identity.rb', __FILE__)

  DiscourseSiwe::IdentityStore::FIELDS.each do |field|
    User.register_custom_field_type(field, :string)
  end

  # Expose web3 identities only to the owning user.
  add_to_serializer(:user, :web3_identities) do
    DiscourseSiwe::IdentityStore.web3_identities(object)
  end

  add_to_serializer(:user, :include_web3_identities?) do
    scope&.user == object
  end

  Discourse::Application.routes.prepend do
    get  '/discourse-siwe/auth'           => 'discourse_siwe/auth#index'
    get  '/discourse-siwe/message'        => 'discourse_siwe/auth#message'
    post '/discourse-siwe/update-identity' => 'discourse_siwe/auth#update_identity'
  end
end
