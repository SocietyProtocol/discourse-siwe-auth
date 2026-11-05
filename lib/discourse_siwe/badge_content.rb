# frozen_string_literal: true

require 'cgi'
require 'set'
require 'uri'

module DiscourseSiwe
  # Pure helpers for badge content that comes from the chain.
  #
  # Everything here is untrusted: a community badge's name, description and
  # image are chosen by whoever created it. Text is reduced to plain text with
  # hard length caps, images are reduced to a single https URL, and names are
  # made unique without renaming a badge on every run.
  module BadgeContent
    # Discourse validates name <= 100, description <= 500, long_description <=
    # 1000. Names are held to 50 so a suffixed name still reads well in the UI.
    NAME_MAX = 50
    DESCRIPTION_MAX = 500
    LONG_DESCRIPTION_MAX = 1000

    IPFS_GATEWAY = 'https://ipfs.filebase.io/ipfs/'
    URL_MAX = 2048
    IMAGE_TYPES = %i[png jpeg gif webp svg].freeze
    IMAGE_MAX_BYTES = 2 * 1024 * 1024

    CID = /\A(?:Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{58,})\z/
    # Zero width, bidi override and BOM characters: used to spoof names.
    INVISIBLE = /[​-‏‪-‮⁠-⁩﻿]/
    CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u2028\u2029]/

    module_function

    # "13" / 13 -> 13. Anything that is not plain decimal digits -> nil.
    def token_id(value)
      text = value.to_s.strip
      text.match?(/\A\d{1,18}\z/) ? text.to_i : nil
    end

    # Reduces chain text to plain text: no HTML, no markdown, no links, no
    # invisible characters, single spaces. Returns '' for blank input.
    def plain_text(value, max)
      text = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub('')
      text = text.gsub(INVISIBLE, '').gsub(CONTROL, ' ')
      text = text.gsub(%r{<!--.*?-->}m, ' ')
      text = text.gsub(%r{<(script|style)\b.*?</\1\s*>}mi, ' ')
      text = text.gsub(%r{</?(?:p|br|div|li|ul|ol|h[1-6]|tr|td|table|blockquote)\b[^>]*>}i, ' ')
      text = text.gsub(/<[^>]*>/m, '')
      text = CGI.unescapeHTML(text)
      text = text.gsub(/[<>]/, ' ')                             # anything an entity decoded into a tag
      text = text.gsub(/!\[[^\]]*\]\([^)]*\)/, ' ')              # markdown images
      text = text.gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')            # markdown links keep their label
      text = text.gsub(/\[([^\]]*)\]\[[^\]]*\]/, '\1')           # reference links
      text = text.gsub(%r{\b(?:https?|ftp|ipfs)://\S+}i, ' ')    # bare URLs
      text = text.gsub(/\bwww\.\S+/i, ' ')
      text = text.gsub(/\b\S+@\S+\.\S+\b/, ' ')                  # emails
      text = text.gsub(/^[ \t]*(?:\#{1,6}|[>*+-]|\d+\.)[ \t]+/, '') # heading, quote and list markers
      text = text.gsub(/[`*~|\[\]]/, '')                         # emphasis, code, table, leftover brackets
      text = text.gsub(/\s+/, ' ').strip
      truncate(text, max)
    end

    def truncate(text, max)
      return text if text.length <= max

      "#{text[0, max - 1].rstrip}…"
    end

    # Plain text for a name, or nil when nothing usable is left.
    def name(value)
      cleaned = plain_text(value, NAME_MAX)
      cleaned.empty? ? nil : cleaned
    end

    # The key Discourse resolves names by: Badge.i18n_name (also used for
    # translation lookups, so "welcome" would pick up the system badge text).
    def name_key(value)
      value.to_s.downcase.tr(' ', '_')
    end

    def suffix(token_id)
      " (##{token_id})"
    end

    # Picks the forum name for a badge.
    #
    #   chain_name  the badge name on chain (sanitised here)
    #   current     the name the badge has now, or nil for a new badge
    #   taken       Set of name_key values used by OTHER badges
    #
    # Stability: a badge keeps its current name as long as it is still the
    # chain name or the chain name plus the id suffix, even if the collision
    # that caused the suffix has since gone away. Only a real change of the
    # chain name (or a manual edit, which the sync overwrites) renames it.
    # Returns nil when every candidate is taken (caller keeps what it has).
    def choose_name(chain_name, token_id, current: nil, taken: Set.new)
      base = name(chain_name) || "Society badge ##{token_id}"
      suffixed = "#{truncate(base, NAME_MAX - suffix(token_id).length)}#{suffix(token_id)}"

      if current
        return current if [base, suffixed].include?(current) && !taken.include?(name_key(current))
      end

      [base, suffixed, "Society badge ##{token_id}"].each do |candidate|
        return candidate unless taken.include?(name_key(candidate))
      end
      nil
    end

    # One https URL for an image, or nil. Accepts ipfs://, /ipfs/, bare CIDs,
    # path-style gateway URLs and https URLs. Everything else (data:, http:,
    # file:, userinfo, odd schemes, overlong) is rejected.
    def image_url(value)
      text = value.to_s.strip
      return nil if text.empty? || text.length > URL_MAX || text.match?(/[\s\u0000-\u001F]/)
      return nil if text.start_with?('data:')

      path = ipfs_path(text)
      return(path.empty? ? nil : "#{IPFS_GATEWAY}#{path}") if path

      uri = URI.parse(text)
      return nil unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty?
      return nil if uri.userinfo

      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    # "<cid>[/rest]" for the IPFS forms, nil when the value is not IPFS.
    def ipfs_path(text)
      return text if text.match?(CID)
      return text.sub(%r{\Aipfs://(?:ipfs/)?}i, '') if text.match?(%r{\Aipfs://}i)

      match = text.match(%r{\A(?:https?://[^/]+)?/ipfs/([^?#]+)}i)
      match && match[1]
    end

    # Whether a downloaded image is acceptable, from what FastImage reported.
    def image_type_allowed?(type)
      IMAGE_TYPES.include?(type)
    end

    # Plain text for a badge's long description. The app link is ours (built
    # from a setting), never chain content.
    def long_description(description, token_id, app_url: '')
      link = app_url.to_s.strip.sub(%r{/+\z}, '')
      parts = []
      parts << description unless description.to_s.empty?
      parts << "Mirrored from the Society Protocol outpost (token ##{token_id}) and granted automatically to " \
               'forum members whose linked wallet holds it. Edits made here are overwritten.'
      parts << "[View this badge in the outpost](#{link}/badges/#{token_id})" if link.match?(%r{\Ahttps://[^\s)]+\z})
      truncate(parts.join("\n\n"), LONG_DESCRIPTION_MAX)
    end
  end
end
