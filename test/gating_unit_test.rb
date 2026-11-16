#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for token-gated category provisioning: config parser, planner
# and the pre-enforcement audit. No Discourse or network needed.
#
# Run: ruby -r./test/support/pure_keccak -rtime test/gating_unit_test.rb

require 'minitest/autorun'
require_relative '../lib/discourse_siwe/gating_config'
require_relative '../lib/discourse_siwe/gating_planner'
require_relative '../lib/discourse_siwe/gating_audit'

Cfg = DiscourseSiwe::GatingConfig
Plan = DiscourseSiwe::GatingPlanner
Audit = DiscourseSiwe::GatingAudit

RESERVED = %w[admins moderators staff everyone trust_level_0 trust_level_1].freeze

VALID = <<~YAML
  groups:
    vip-gold:
      full_name: VIP Gold
    governors:
      visibility: staff
  categories:
    gold-lounge:
      name: Gold Lounge
      access:
        vip-gold: full
        governors: reply
    governors-only:
      parent: gold-lounge
      access:
        governors: full
YAML

class GatingConfigTest < Minitest::Test
  def parse(text)
    Cfg.parse(text, reserved: RESERVED)
  end

  def test_a_valid_config_parses_cleanly
    r = parse(VALID)
    assert_empty r.errors
    assert_equal %w[vip-gold governors], r.groups.keys
    assert_equal 'VIP Gold', r.groups['vip-gold'][:full_name]
    assert_equal 'members', r.groups['vip-gold'][:visibility]
    assert_equal({ 'vip-gold' => :full, 'governors' => :create_post }, r.categories['gold-lounge'][:access])
    assert_equal 'gold-lounge', r.categories['governors-only'][:parent]
  end

  def test_empty_and_malformed_yaml_are_errors_not_exceptions
    assert_includes parse('').errors.first, 'empty'
    assert_includes parse("groups: [unclosed\n  - x").errors.first, 'not valid YAML'
    assert_includes parse('- just a list').errors.first, 'mapping'
  end

  def test_aliases_and_arbitrary_classes_are_refused
    r = parse("groups: &a\n  x: 1\ncategories: *a\n")
    refute_empty r.errors
  end

  def test_automatic_groups_cannot_be_gated
    r = parse("groups:\n  admins: {}\n  staff: {}\n  trust_level_2: {}\n")
    assert_equal 3, r.errors.count { |e| e.include?('automatic') }
    assert_empty r.groups
  end

  def test_group_name_rules
    r = parse("groups:\n  ab: {}\n  Has-Caps: {}\n  ok-name: {}\n")
    assert_equal ['ok-name'], r.groups.keys
    assert_equal 2, r.errors.size
  end

  def test_everyone_is_refused_in_category_access
    r = parse("groups:\n  g1x: {}\ncategories:\n  c1:\n    access:\n      everyone: full\n      g1x: full\n")
    assert(r.errors.any? { |e| e.include?('everyone') })
    assert_empty r.categories
  end

  def test_access_must_name_defined_groups_with_valid_levels
    r = parse("groups:\n  g1x: {}\ncategories:\n  c1:\n    access:\n      nope: full\n  c2:\n    access:\n      g1x: admin\n")
    assert(r.errors.any? { |e| e.include?('nope is not defined') })
    assert(r.errors.any? { |e| e.include?('permission must be one of') })
    assert_empty r.categories
  end

  def test_a_category_with_no_access_is_refused
    r = parse("groups:\n  g1x: {}\ncategories:\n  c1:\n    name: X\n")
    assert(r.errors.any? { |e| e.include?('at least one group') })
  end

  def test_unknown_keys_and_bad_visibility_are_reported
    r = parse("groups:\n  g1x:\n    colour: red\n    visibility: everybody\nextra: 1\n")
    assert(r.errors.any? { |e| e.include?('visibility') })
    assert(r.errors.any? { |e| e.include?('unknown top-level') })
  end

  def test_a_category_cannot_be_its_own_parent
    r = parse("groups:\n  g1x: {}\ncategories:\n  c1:\n    parent: c1\n    access:\n      g1x: full\n")
    assert(r.errors.any? { |e| e.include?('itself') })
  end
end

class GatingPlannerTest < Minitest::Test
  def config(text = VALID)
    Cfg.parse(text, reserved: RESERVED)
  end

  def empty_state
    { groups: {}, categories: {} }
  end

  def converged_state(cfg)
    groups = cfg.groups.each_with_object({}) do |(name, g), out|
      out[name] = Plan.desired_group_attrs(g).merge(exists: true, automatic: false)
    end
    categories = cfg.categories.each_with_object({}) do |(slug, c), out|
      out[slug] = { permissions: c[:access].merge('staff' => :full), public: false }
    end
    { groups: groups, categories: categories }
  end

  def test_a_fresh_forum_creates_groups_then_categories_parent_first
    plan = Plan.plan(config, empty_state)
    types = plan.actions.map { |a| [a.type, a.target] }
    assert_equal [%i[create_group vip-gold], %i[create_group governors]].map { |t, n| [t, n.to_s] }, types.first(2)
    cat = types.select { |t, _| %i[create_category set_permissions].include?(t) }.map(&:last)
    assert_equal %w[gold-lounge gold-lounge governors-only governors-only], cat
    assert_empty plan.blocked
  end

  def test_staff_always_get_full_access
    plan = Plan.plan(config, empty_state)
    perms = plan.actions.find { |a| a.type == :set_permissions && a.target == 'gold-lounge' }
    assert_equal :full, perms.details[:desired]['staff']
  end

  def test_group_attributes_are_closed_by_default
    attrs = Plan.plan(config, empty_state).actions.first.details[:attrs]
    assert_equal false, attrs[:public_admission]
    assert_equal false, attrs[:public_exit]
    assert_equal false, attrs[:allow_membership_requests]
    assert_equal :staff, attrs[:members_visibility]
  end

  def test_a_converged_forum_needs_no_actions
    cfg = config
    assert_empty Plan.plan(cfg, converged_state(cfg), mapped_groups: %w[vip-gold governors]).actions
  end

  def test_a_second_run_after_applying_is_a_noop
    cfg = config
    first = Plan.plan(cfg, empty_state)
    refute_empty first.actions
    assert_empty Plan.plan(cfg, converged_state(cfg)).actions
  end

  def test_drift_in_a_group_attribute_is_corrected
    cfg = config
    state = converged_state(cfg)
    state[:groups]['vip-gold'][:public_admission] = true
    plan = Plan.plan(cfg, state)
    assert_equal [:update_group], plan.actions.map(&:type)
    assert_equal [true, false], plan.actions.first.details[:changes][:public_admission]
  end

  def test_drift_in_category_permissions_is_corrected
    cfg = config
    state = converged_state(cfg)
    state[:categories]['gold-lounge'][:permissions]['vip-gold'] = :readonly
    plan = Plan.plan(cfg, state)
    assert_equal [:set_permissions], plan.actions.map(&:type)
  end

  def test_an_existing_group_spelled_in_another_case_is_not_drift
    cfg = config
    state = converged_state(cfg)
    perms = state[:categories]['governors-only'][:permissions]
    perms['Governors'] = perms.delete('governors')
    assert_empty Plan.plan(cfg, state).actions

    perms['Governors'] = :readonly
    assert_equal [:set_permissions], Plan.plan(cfg, state).actions.map(&:type)
  end

  def test_a_stray_extra_group_on_a_gated_category_is_removed
    cfg = config
    state = converged_state(cfg)
    state[:categories]['gold-lounge'][:permissions]['friends'] = :full
    assert_equal [:set_permissions], Plan.plan(cfg, state).actions.map(&:type)
  end

  def test_restricting_an_existing_public_category_needs_explicit_confirmation
    cfg = config
    state = converged_state(cfg)
    state[:categories]['gold-lounge'] = { permissions: { 'everyone' => :full }, public: true }
    plan = Plan.plan(cfg, state)
    assert_equal [:blocked], plan.actions.map(&:type)
    assert_includes plan.blocked.first.details[:reason], 'confirm_restrict'

    confirmed = config(VALID.sub("name: Gold Lounge\n", "name: Gold Lounge\n    confirm_restrict: true\n"))
    assert_empty confirmed.errors
    assert_equal [:set_permissions], Plan.plan(confirmed, state).actions.map(&:type)
  end

  def test_an_automatic_group_in_the_forum_is_never_modified
    cfg = config
    state = converged_state(cfg)
    state[:groups]['governors'][:automatic] = true
    plan = Plan.plan(cfg, state)
    assert_equal [:blocked], plan.actions.map(&:type)
  end

  def test_a_missing_parent_blocks_only_that_category
    cfg = config("groups:\n  g1x: {}\ncategories:\n  child:\n    parent: ghost\n    access:\n      g1x: full\n")
    plan = Plan.plan(cfg, empty_state)
    assert_equal 1, plan.blocked.size
    assert plan.actions.none? { |a| a.type == :create_category }
  end

  def test_an_existing_parent_outside_the_config_is_accepted
    cfg = config("groups:\n  g1x: {}\ncategories:\n  child:\n    parent: community\n    access:\n      g1x: full\n")
    state = empty_state.merge(categories: { 'community' => { permissions: {}, public: true } })
    assert_empty Plan.plan(cfg, state).blocked
  end

  def test_unlisted_categories_and_groups_are_never_touched
    cfg = config
    state = converged_state(cfg)
    state[:categories]['general'] = { permissions: { 'everyone' => :full }, public: true }
    state[:groups]['somebody-else'] = { exists: true, public_admission: true }
    assert_empty Plan.plan(cfg, state).actions
  end

  def test_groups_that_no_badge_feeds_are_warned_about
    plan = Plan.plan(config, empty_state, mapped_groups: %w[vip-gold])
    assert_equal 1, plan.warnings.size
    assert_includes plan.warnings.first, 'governors'
  end

  def test_owner_only_groups_hide_membership_from_staff_too
    cfg = config("groups:\n  g1x:\n    visibility: owners\ncategories:\n  c1:\n    access:\n      g1x: full\n")
    attrs = Plan.plan(cfg, empty_state).actions.first.details[:attrs]
    assert_equal :owners, attrs[:visibility]
    assert_equal :owners, attrs[:members_visibility]
  end
end

class GatingAuditTest < Minitest::Test
  def ok_sync(groups)
    { status: :ok, mode: 'log', groups: groups }
  end

  def test_a_clean_group_passes
    r = Audit.report(ok_sync('vip-gold' => { add: ['a'], remove: [], deferred: [], kept: ['fritz'] }), gated: ['vip-gold'])
    assert r[:ok]
    assert_equal ['fritz'], r[:groups]['vip-gold'][:kept]
  end

  def test_members_without_the_badge_block_enforcement
    r = Audit.report(ok_sync('vip-gold' => { add: [], remove: ['bob'], deferred: ['carol'], kept: [] }), gated: ['vip-gold'])
    refute r[:ok]
    assert_equal %w[bob carol], r[:groups]['vip-gold'][:lose_access]
    assert(r[:blockers].any? { |b| b.include?('would lose access') })
  end

  def test_walletless_members_are_flagged_because_they_keep_access_forever
    r = Audit.report(ok_sync('vip-gold' => { add: [], remove: [], deferred: [], kept: [] }), gated: ['vip-gold'], walletless: { 'vip-gold' => ['dave'] })
    refute r[:ok]
    assert(r[:blockers].any? { |b| b.include?('no wallet') })
  end

  def test_a_hand_managed_group_with_members_is_flagged
    r = Audit.report(ok_sync({}), gated: ['vip-gold'], unmapped: ['vip-gold'], manual: { 'vip-gold' => %w[x y] })
    refute r[:ok]
    assert(r[:blockers].any? { |b| b.include?('no badge feeds') })
  end

  def test_a_chain_failure_is_never_a_pass
    r = Audit.report({ status: :source_error, groups: nil }, gated: ['vip-gold'])
    refute r[:ok]
    assert(r[:blockers].first.include?('could not read the chain'))
  end

  def test_a_missing_group_is_a_blocker
    r = Audit.report(ok_sync('vip-gold' => { missing: true }), gated: ['vip-gold'])
    refute r[:ok]
  end
end
