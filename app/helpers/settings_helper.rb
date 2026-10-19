module SettingsHelper
  SETTINGS_ORDER = [
    # General section
    { name: -> { t("settings.settings_nav.accounts_label") }, path: :accounts_path },
    { name: -> { t("settings.settings_nav.bank_sync_label") }, path: :settings_providers_path, condition: :admin_user? },
    { name: -> { t("settings.settings_nav.preferences_label") }, path: :settings_preferences_path },
    { name: -> { t("settings.settings_nav.appearance_label") }, path: :settings_appearance_path },
    { name: -> { t("settings.settings_nav.profile_label") }, path: :settings_profile_path },
    { name: -> { t("settings.settings_nav.security_label") }, path: :settings_security_path },
    { name: -> { t("settings.settings_nav.payment_label") }, path: :settings_payment_path, condition: :not_self_hosted? },
    # Transactions section
    { name: -> { t("settings.settings_nav.categories_label") }, path: :categories_path },
    { name: -> { t("settings.settings_nav.tags_label") }, path: :tags_path },
    { name: -> { t("settings.settings_nav.rules_label") }, path: :rules_path },
    { name: -> { t("settings.settings_nav.merchants_label") }, path: :family_merchants_path },
    { name: -> { t("settings.settings_nav.recurring_transactions_label") }, path: :recurring_transactions_path },
    { name: -> { t("settings.settings_nav.documents_label") }, path: :documents_path },
    # Advanced section
    { name: -> { t("settings.settings_nav.ai_prompts_label") }, path: :settings_ai_prompts_path, condition: :admin_user? },
    { name: -> { t("settings.settings_nav.llm_usage_label") }, path: :settings_llm_usage_path, condition: :admin_user? },
    { name: -> { t("settings.settings_nav.api_key_label") }, path: :settings_api_keys_path, condition: :admin_user? },
    { name: -> { t("settings.settings_nav.self_hosting_label") }, path: :settings_hosting_path, condition: :self_hosted_and_admin? },
    { name: -> { t("settings.settings_nav.imports_label") }, path: :imports_path, condition: :admin_user? },
    { name: -> { t("settings.settings_nav.exports_label") }, path: :family_exports_path, condition: :admin_user? },
    # More section
    { name: -> { t("settings.settings_nav.guides_label") }, path: :settings_guides_path },
    { name: -> { t("settings.settings_nav.whats_new_label") }, path: :changelog_path },
    { name: -> { t("settings.settings_nav.feedback_label") }, path: :feedback_path }
  ]

  # The Settings list's groups, in order (the iOS Settings redesign,
  # 2026-10-17; regrouped in the Settings audit, 2026-10-19). Each row has a
  # tint for its icon tile, as iOS colours its settings, and where it helps a
  # short summary of what is set ("Dark", "3 people", "Two-factor off").
  # Accounts and Documents are tabs of their own, not settings.
  def settings_nav_sections
    admin = Current.user&.admin?
    super_admin = Current.user&.super_admin?
    family = Current.family
    nav = ->(key) { t("settings.settings_nav.#{key}") }
    [
      { header: nav.("account_section_title"), items: [
        { label: nav.("household_label"), path: settings_household_path, icon: "users", tint: "cyan",
          detail: (t("settings.settings_nav.people", count: family.users.count) if family) },
        { label: nav.("security_label"), path: settings_security_path, icon: "shield-check", tint: "blue",
          detail: nav.(Current.user&.otp_required? ? "two_factor_on" : "two_factor_off") },
        { label: nav.("payment_label"), path: settings_payment_path, icon: "circle-dollar-sign", tint: "yellow", if: !self_hosted? && family&.can_manage_subscription? }
      ] },
      { header: nav.("app_section_title"), items: [
        { label: nav.("preferences_label"), path: settings_preferences_path, icon: "bolt", tint: "gray", detail: family&.currency },
        { label: nav.("appearance_label"), path: settings_appearance_path, icon: "palette", tint: "brand",
          detail: t("settings.appearances.show.theme_#{Current.user&.theme.presence || "system"}", default: "") }
      ] },
      { header: nav.("money_section_title"), items: [
        { label: nav.("bank_sync_label"), path: settings_providers_path, icon: "banknote", tint: "green", if: admin },
        { label: nav.("categories_label"), path: categories_path, icon: "shapes", tint: "orange", detail: family&.categories&.count },
        { label: nav.("tags_label"), path: tags_path, icon: "tags", tint: "fuchsia", detail: family&.tags&.count },
        { label: nav.("rules_label"), path: rules_path, icon: "git-branch", tint: "indigo", detail: family&.rules&.count },
        { label: nav.("merchants_label"), path: family_merchants_path, icon: "store", tint: "cyan" },
        { label: nav.("recurring_transactions_label"), path: recurring_transactions_path, icon: "repeat", tint: "green" }
      ] },
      (admin ? { header: nav.("data_section_title"), items: [
        { label: nav.("imports_label"), path: imports_path, icon: "download", tint: "blue" },
        { label: nav.("exports_label"), path: family_exports_path, icon: "upload", tint: "green" }
      ] } : nil),
      (admin ? { header: nav.("ai_section_title"), items: [
        { label: nav.("ai_label"), path: settings_ai_path, icon: "sparkles", tint: "violet", if: self_hosted? },
        { label: nav.("ai_prompts_label"), path: settings_ai_prompts_path, icon: "bot", tint: "violet" },
        { label: nav.("llm_usage_label"), path: settings_llm_usage_path, icon: "activity", tint: "pink" },
        { label: nav.("data_providers_label"), path: settings_data_providers_path, icon: "chart-line", tint: "cyan", if: self_hosted? },
        { label: nav.("api_keys_label"), path: settings_api_keys_path, icon: "key", tint: "yellow" },
        { label: nav.("mcp_label"), path: settings_mcp_path, icon: "plug", tint: "indigo" }
      ] } : nil),
      (admin && (self_hosted? || super_admin) ? { header: nav.("system_section_title"), items: [
        { label: nav.("self_hosting_label"), path: settings_hosting_path, icon: "server", tint: "gray", if: self_hosted? },
        { label: t("settings.settings_nav.debug_label", default: "Debug"), path: settings_debug_path, icon: "bug", tint: "red", if: super_admin },
        { label: nav.("background_jobs_label"), path: settings_background_jobs_path, icon: "list-checks", tint: "gray", if: super_admin },
        { label: nav.("sso_providers_label"), path: admin_sso_providers_path, icon: "key-round", tint: "orange", if: super_admin },
        { label: nav.("users_label"), path: admin_users_path, icon: "users", tint: "cyan", if: super_admin },
        { label: nav.("system_health_label"), path: admin_system_health_path, icon: "heart-pulse", tint: "red", if: super_admin }
      ] } : nil),
      { header: nav.("other_section_title"), items: [
        { label: nav.("guides_label"), path: settings_guides_path, icon: "book-open", tint: "yellow" },
        { label: nav.("whats_new_label"), path: changelog_path, icon: "box", tint: "indigo" },
        { label: nav.("feedback_label"), path: feedback_path, icon: "megaphone", tint: "orange" }
      ] }
    ].compact
     .map { |section| section.merge(items: section[:items].reject { |item| item[:if] == false }) }
     .reject { |section| section[:items].empty? }
  end

  def adjacent_setting(current_path, offset)
    visible_settings = SETTINGS_ORDER.select { |setting| setting[:condition].nil? || send(setting[:condition]) }
    current_index = visible_settings.index { |setting| send(setting[:path]) == current_path }
    return nil unless current_index

    adjacent_index = current_index + offset
    return nil if adjacent_index < 0 || adjacent_index >= visible_settings.size

    adjacent = visible_settings[adjacent_index]

    render partial: "settings/settings_nav_link_large", locals: {
      path: send(adjacent[:path]),
      direction: offset > 0 ? "next" : "previous",
      title: setting_name(adjacent)
    }
  end

  def settings_section(title: nil, subtitle: nil, collapsible: false, open: true, auto_open_param: nil, status: nil, meta: nil, actions: nil, badge: nil, &block)
    content = capture(&block)
    render partial: "settings/section", locals: { title: title, subtitle: subtitle, content: content, collapsible: collapsible, open: open, auto_open_param: auto_open_param, status: status, meta: meta, actions: actions, badge: badge }
  end

  def provider_summary(provider_key)
    key = provider_key.to_s.downcase

    case key
    when "plaid", "plaid_eu"
      configured = @provider_configurations&.find { |c| c.provider_key.to_s.casecmp(key).zero? }&.configured?
      configured ? { status: :ok } : { status: :off }
    when "akahu"
      return { status: :off } unless @akahu_items&.any?
      sync_based_summary(key)
    when "up"
      return { status: :off } unless @up_items&.any?
      sync_based_summary(key)
    when "monobank"
      return { status: :off } unless @monobank_items&.any?
      sync_based_summary(key)
    when "fio"
      return { status: :off } unless @fio_items&.any?
      sync_based_summary(key)
    when "simplefin"
      return { status: :off } unless @simplefin_items&.any?
      sync_based_summary(key)
    when "lunchflow"
      return { status: :off } unless @lunchflow_items&.any?
      sync_based_summary(key)
    when "enable_banking"
      return { status: :off } unless @enable_banking_items&.any?
      enable_banking_summary
    when "coinstats"
      return { status: :off } unless @coinstats_items&.any?
      sync_based_summary(key)
    when "wise"
      return { status: :off } unless @wise_items&.any?
      sync_based_summary(key)
    when "mercury"
      return { status: :off } unless @mercury_items&.any?
      sync_based_summary(key)
    when "redbark"
      return { status: :off } unless @redbark_items&.any?
      sync_based_summary(key)
    when "brex"
      return { status: :off } unless @brex_items&.any?
      sync_based_summary(key)
    when "coinbase"
      return { status: :off } unless @coinbase_items&.any?
      sync_based_summary(key)
    when "binance"
      return { status: :off } unless @binance_items&.any?
      sync_based_summary(key)
    when "kraken"
      return { status: :off } unless @kraken_items&.any?
      sync_based_summary(key)
    when "coinspot"
      return { status: :off } unless @coinspot_items&.any?
      sync_based_summary(key)
    when "onchain_wallet"
      return { status: :off } unless @onchain_wallet_items&.any?
      sync_based_summary(key)
    when "trading212"
      return { status: :off } unless @trading212_items&.any?
      sync_based_summary(key)
    when "snaptrade"
      configured_item = @snaptrade_items&.find(&:oauth_configured?)
      return { status: :off } unless configured_item
      sync_based_summary(key)
    when "ibkr"
      return { status: :off } unless @ibkr_items&.any?
      sync_based_summary(key)
    when "trade_republic"
      return { status: :off } unless @trade_republic_items&.any?
      sync_based_summary(key)
    when "indexa_capital"
      return { status: :off } unless @indexa_capital_items&.any?
      sync_based_summary(key)
    when "sophtron"
      return { status: :off } unless @sophtron_items&.any?
      sync_based_summary(key)
    when "questrade"
      return { status: :off } unless @questrade_items&.any?
      sync_based_summary(key)
    else
      { status: :off }
    end
  end

  def financekit_provider_summary(connections)
    return { status: :off } if connections.empty?

    items = connections.map { |connection| connection[:item] }
    count = connections.flat_map { |connection| connection[:accounts].map(&:id) }.uniq.size
    {
      status: items.any? { |item| item.status == "repair_required" } ? :warn : :ok,
      meta: t("settings.providers.financekit.linked_accounts", count: count),
      last_synced_at: items.filter_map(&:last_imported_at).max
    }
  end

  def settings_nav_footer
    previous_setting = adjacent_setting(request.path, -1)
    next_setting = adjacent_setting(request.path, 1)

    content_tag :div, class: "hidden md:flex flex-row justify-between gap-4" do
      concat(previous_setting)
      concat(next_setting)
    end
  end

  def settings_nav_footer_mobile
    previous_setting = adjacent_setting(request.path, -1)
    next_setting = adjacent_setting(request.path, 1)

    content_tag :div, class: "md:hidden flex flex-col gap-4 pb-[env(safe-area-inset-bottom)]" do
      concat(previous_setting)
      concat(next_setting)
    end
  end

  def yahoo_finance_health_presentation(status)
    status = status.to_sym if status.respond_to?(:to_sym)
    status = :unknown unless %i[healthy rate_limited unavailable unknown].include?(status)

    presentation = {
      status_class: {
        healthy: "bg-success",
        rate_limited: "bg-warning",
        unavailable: "bg-destructive",
        unknown: "bg-surface-inset"
      }.fetch(status),
      status_text: t("settings.hostings.yahoo_finance_settings.status_#{status}")
    }

    presentation[:alert] = case status
    when :rate_limited
      {
        title: t("settings.hostings.yahoo_finance_settings.rate_limited_title"),
        message: t("settings.hostings.yahoo_finance_settings.rate_limited_message"),
        variant: :warning
      }
    when :unavailable
      {
        title: t("settings.hostings.yahoo_finance_settings.unavailable_title"),
        message: t("settings.hostings.yahoo_finance_settings.unavailable_message"),
        variant: :warning
      }
    end

    presentation
  end

  # Below this many synced accounts, the per-row pills already give the user
  # enough at-a-glance signal and the strip is redundant chrome.
  HEALTH_STRIP_MIN_ACCOUNTS = 10

  # Slim health-strip data for the providers index. Pulls counts from the
  # already-resolved entry summaries plus the family's distinct synced-account
  # count for the trailing stat. Returns a hash consumed by the
  # `settings/providers/_health_strip` partial, or nil when the family has
  # fewer than HEALTH_STRIP_MIN_ACCOUNTS connected accounts.
  def provider_health_strip(connected:, needs_attention:)
    accounts_count = Current.family.accounts.joins(:account_providers).distinct.count
    return nil if accounts_count < HEALTH_STRIP_MIN_ACCOUNTS

    active_entries = connected + needs_attention
    last_synced_at = active_entries.map { |e| e[:summary][:last_synced_at] }.compact.max

    {
      connected:        active_entries.size,
      needs_attention:  needs_attention.size,
      accounts_syncing: accounts_count,
      last_synced_at:   last_synced_at
    }
  end

  # Strips the leading "about " from `time_ago_in_words` so copy reads as
  # "Synced 6 hours ago" instead of "Synced about 6 hours ago".
  def concise_time_ago(time)
    time_ago_in_words(time).sub(/\Aabout /, "")
  end

  private
    def sync_based_summary(provider_key)
      health = @provider_sync_health&.dig(provider_key) || {}
      last_synced_at = health[:last_synced_at]

      base = if health[:error]
        { status: :err, meta: t("settings.providers.meta.sync_error") }
      elsif health[:stale]
        { status: :warn, meta: t("settings.providers.meta.no_recent_sync") }
      elsif last_synced_at.present?
        { status: :ok, meta: t("settings.providers.meta.last_synced", time: concise_time_ago(last_synced_at)) }
      else
        { status: :ok }
      end

      base.merge(last_synced_at: last_synced_at)
    end

    def enable_banking_summary
      health = @provider_sync_health&.dig("enable_banking") || {}
      last_synced_at = health[:last_synced_at]

      return { status: :err, meta: t("settings.providers.meta.sync_error"), last_synced_at: nil } if health[:error]

      valid_items = @enable_banking_items&.reject(&:needs_authorization?) || []

      # All items have expired, missing or rejected sessions — need re-authorization
      if valid_items.empty?
        return { status: :warn, meta: t("settings.providers.meta.reconsent_required"), last_synced_at: last_synced_at }
      end

      expiring = valid_items.find do |item|
        item.session_expires_at.present? && item.session_expires_at < 7.days.from_now
      end

      if expiring
        days = [ ((expiring.session_expires_at - Time.current) / 1.day).ceil, 1 ].max
        return { status: :warn, meta: t("settings.providers.meta.reconsent_needed", count: days), last_synced_at: last_synced_at }
      end

      return { status: :warn, meta: t("settings.providers.meta.no_recent_sync"), last_synced_at: last_synced_at } if health[:stale]

      if last_synced_at.present?
        { status: :ok, meta: t("settings.providers.meta.last_synced", time: concise_time_ago(last_synced_at)), last_synced_at: last_synced_at }
      else
        { status: :ok, last_synced_at: nil }
      end
    end

    def not_self_hosted?
      !self_hosted?
    end

    def setting_name(setting)
      name = setting[:name]
      name.respond_to?(:call) ? instance_exec(&name) : name
    end

    # Helper used by SETTINGS_ORDER conditions
    def admin_user?
      Current.user&.admin?
    end

    def self_hosted_and_admin?
      self_hosted? && admin_user?
    end
end
