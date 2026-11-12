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
    APP_URL_MAX = 200
    BREAK = '<br><br>'
    IMAGE_TYPES = %i[png jpeg gif webp svg].freeze
    IMAGE_MAX_BYTES = 2 * 1024 * 1024

    CID = /\A(?:Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{58,})\z/
    # Chain text is cut to this many characters before any pattern runs, and
    # again after every normalisation step (NFKC can expand a character), so
    # no regex ever sees more than this much hostile input.
    INPUT_MAX = 4096
    DECODE_PASSES = 5

    # Whitespace-like separators (category Zs, tab, form feed...) become a
    # plain space; line separators become a newline.
    SPACES = /[\p{Zs}\t\v\f]/
    LINE_BREAKS = /[\u0085\u2028\u2029\r]/
    # Controls other than the newline.
    CONTROLS = /(?!\n)\p{Cc}/
    # Removed without a trace: format characters (zero width, bidi, soft
    # hyphen, Arabic letter mark, BOM, tag characters...), variation selectors,
    # private use and surrogates, the combining grapheme joiner and the fillers
    # and blanks that render as nothing (Hangul fillers, Khmer inherent
    # vowels, braille blank).
    INVISIBLE = /[\p{Cf}\p{Co}\p{Cs}\u{E0000}-\u{E007F}\uFE00-\uFE0F\u{E0100}-\u{E01EF}\u034F\u115F\u1160\u17B4\u17B5\u3164\uFFA0\u2800]/

    # The fullwidth ampersand stands in for every '&': Discourse unescapes
    # HTML entities in a description AFTER sanitising it, so a surviving
    # entity (even a legacy one without ';') would become markup.
    AMPERSAND = "\uFF06"

    module_function

    # "13" / 13 -> 13. Anything that is not plain decimal digits -> nil.
    def token_id(value)
      text = value.to_s.strip
      text.match?(/\A\d{1,18}\z/) ? text.to_i : nil
    end

    # Reduces chain text to plain text: no HTML, no markdown, no links, no
    # invisible characters, single spaces. Returns '' for blank input.
    #
    # Order matters. Entities are decoded to a fixed point (with NFKC, so
    # fullwidth forms cannot hide a tag or an entity) BEFORE anything is
    # stripped, and the invisible-character removal runs on the final text, so
    # nothing an entity decodes into survives. Every pattern is linear on the
    # (length capped) input.
    def plain_text(value, max)
      text = decode(value)
      text = text.gsub(%r{<!--.*?-->}m, ' ')
      text = text.gsub(%r{<(script|style)\b.*?</\1\s*>}mi, ' ')
      text = text.gsub(%r{</?(?:p|br|div|li|ul|ol|h[1-6]|tr|td|table|blockquote)\b[^>]*>}i, ' ')
      text = text.gsub(/<[^>]*>/m, '')
      text = text.gsub(/[<>]/, ' ')
      text = text.gsub(/!\[[^\]]*\]\([^)]*\)/, ' ')              # markdown images
      text = text.gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')            # markdown links keep their label
      text = text.gsub(/\[([^\]]*)\]\[[^\]]*\]/, '\1')           # reference links
      text = drop_links(text)
      text = text.gsub(/^[ \t]*(?:\#{1,6}|[>*+-]|\d+\.)[ \t]+/, '') # heading, quote and list markers
      text = text.gsub(/[`*~|\[\]]/, '')                         # emphasis, code, table, leftover brackets
      text = text.gsub('%', ' percent ')                         # I18n would interpolate '%{...}' in a description
      text = text.gsub('&', AMPERSAND)
      text = text.gsub(/\s+/, ' ').strip
      truncate(text, max)
    end

    # Input -> a valid UTF-8 string of at most INPUT_MAX characters whose HTML
    # entities are decoded to a fixed point (at most DECODE_PASSES passes; an
    # entity that is still left is neutralised by the '&' replacement).
    def decode(value)
      text = cut(value.to_s.byteslice(0, INPUT_MAX * 4).to_s)
      DECODE_PASSES.times do
        decoded = cut(clean_characters(normalize(unescape(text))))
        break if decoded == text

        text = decoded
      end
      text
    end

    def cut(text)
      text.dup.force_encoding(Encoding::UTF_8).scrub('')[0, INPUT_MAX]
    end

    def normalize(text)
      text.unicode_normalize(:nfkc)
    rescue ArgumentError, Encoding::CompatibilityError
      text
    end

    def unescape(text)
      CGI.unescapeHTML(text.gsub(/&nbsp;/i, ' ')).scrub('')
    rescue ArgumentError, RangeError
      text.gsub('&', ' ')
    end

    # Spaces, line breaks, controls and invisible characters.
    def clean_characters(text)
      text.gsub(INVISIBLE, '').gsub(SPACES, ' ').gsub(LINE_BREAKS, "\n").gsub(CONTROLS, ' ')
    end

    # URLs, www. hosts and e-mail addresses. Token based so that no pattern
    # backtracks across the whole input.
    def drop_links(text)
      text = text.gsub(%r{\b(?:https?|ftp|ipfs)://\S+}i, ' ')
      text = text.gsub(/\bwww\.\S+/i, ' ')
      text.gsub(/\S+/) { |token| email_like?(token) ? ' ' : token }
    end

    def email_like?(token)
      at = token.index('@')
      return false unless at && at.positive?

      dot = token.index('.', at + 2)
      !dot.nil? && dot < token.length - 1
    end

    def truncate(text, max)
      return text if text.length <= max
      return '' if max < 2

      "#{text[0, max - 1].rstrip}…"
    end

    # Plain text for a name, or nil when nothing usable is left.
    def name(value)
      cleaned = plain_text(value, NAME_MAX)
      cleaned.empty? ? nil : cleaned
    end

    # The key names are compared by: Discourse resolves a name through
    # Badge.i18n_name (downcase, spaces to underscores) and also uses it for
    # translation lookups, so "welcome" would pick up the system badge text.
    # Ours is stricter: NFKC, case folding, invisible characters dropped and
    # every kind of space collapsed, so a lookalike never counts as free.
    def name_key(value)
      text = normalize(value.to_s.dup.force_encoding(Encoding::UTF_8).scrub('')[0, INPUT_MAX])
      text = text.gsub(INVISIBLE, '').gsub(SPACES, ' ').gsub(/\s+/, ' ').strip
      text.downcase(:fold).tr(' ', '_')
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

    # HTML, because Discourse renders a long description as sanitised HTML
    # (the badge card shows it through its sanitizer, no markdown step). Every
    # piece is plain text (no '<', '>' or '&'), and the one link is ours, built
    # from a validated setting and escaped. The link goes last and the text is
    # cut to leave room for it, so truncation never splits the markup.
    def long_description(description, token_id, app_url: '')
      notice = "Mirrored from the Society Protocol outpost (token ##{token_id.to_i}) and granted automatically to " \
               'forum members whose linked wallet holds it. Edits made here are overwritten.'
      base = app_url(app_url)
      anchor = base.empty? ? '' : %(<a href="#{CGI.escapeHTML("#{base}/badges/#{token_id.to_i}")}">View this badge in the outpost</a>)

      fixed = [notice, anchor].reject(&:empty?)
      room = LONG_DESCRIPTION_MAX - fixed.sum(&:length) - (fixed.size * BREAK.length)
      text = room >= 20 ? plain_text(description, [DESCRIPTION_MAX, room].min) : ''
      ([text] + fixed).reject(&:empty?).join(BREAK)
    end

    # The siwe_badges_app_url setting, trusted for nothing: https, a plain host
    # (letters, digits, dots, hyphens), optional port, no userinfo, query or
    # fragment, no characters that I18n or HTML treat specially. => the URL
    # without a trailing slash, or '' when it is not usable.
    def app_url(value)
      text = value.to_s.strip.sub(%r{/+\z}, '')
      return '' if text.empty? || text.length > APP_URL_MAX || text.match?(/[^\x21-\x7E]/) || text.match?(/[%"'<>&\\{}|^`]/)

      uri = URI.parse(text)
      return '' unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      return '' unless uri.host.to_s.match?(/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/i)

      uri.to_s.sub(%r{/+\z}, '')
    rescue URI::InvalidURIError
      ''
    end
  end
end
