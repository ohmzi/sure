class Settings::HostingsController < ApplicationController
  layout "settings"

  # Minimum accepted value for each configurable numeric LLM field. Mirrors the
  # `min:` attribute on the form inputs in `_openai_settings.html.erb` so the
  # controller rejects what the browser-side validator would reject.
  LLM_NUMERIC_MINIMUMS = {
    llm_context_window: 256,
    llm_max_response_tokens: 64,
    llm_max_items_per_call: 1,
    openai_request_timeout: Provider::Openai::MIN_REQUEST_TIMEOUT,
    ai_response_timeout: Chat::MIN_RESPONSE_TIMEOUT.to_i,
    ai_health_probe_timeout: 1
  }.freeze

  guard_feature unless: -> { self_hosted? }

  before_action :ensure_admin, only: [ :update, :clear_cache, :disconnect_external_assistant, :detect_local_models, :persist_local_model ]
  before_action :ensure_super_admin_for_onboarding, only: :update

  # The three pages this controller serves (2026-10-17): AI, data providers,
  # and what is left of self-hosting proper.
  SECTIONS = %w[ai data hosting].freeze

  def show
    @section = SECTIONS.include?(params[:section]) ? params[:section] : "hosting"

    # Determine which providers are currently selected
    exchange_rate_provider = ENV["EXCHANGE_RATE_PROVIDER"].presence || Setting.exchange_rate_provider
    enabled_securities = Setting.enabled_securities_providers

    # Show provider settings if used for FX or enabled for securities
    @show_twelve_data_settings = exchange_rate_provider == "twelve_data" || enabled_securities.include?("twelve_data")
    @show_yahoo_finance_settings = exchange_rate_provider == "yahoo_finance" || enabled_securities.include?("yahoo_finance")
    @show_tiingo_settings = enabled_securities.include?("tiingo")
    @show_eodhd_settings = enabled_securities.include?("eodhd")
    @show_alpha_vantage_settings = enabled_securities.include?("alpha_vantage")
    @show_mansa_settings = enabled_securities.include?("mansa")
    tinkoff_invest_checked = enabled_securities.include?("tinkoff_invest")
    tinkoff_invest_configured = ENV["TINKOFF_INVEST_API_KEY"].present? || Setting.tinkoff_invest_api_key.present?
    @show_tinkoff_invest_settings = tinkoff_invest_checked || enabled_securities.include?("moex_public") || tinkoff_invest_configured
    @tinkoff_invest_moex_only = @show_tinkoff_invest_settings && !tinkoff_invest_checked

    # Only fetch provider data if we're showing the section
    if @show_twelve_data_settings
      twelve_data_provider = Provider::Registry.get_provider(:twelve_data)
      @twelve_data_usage = twelve_data_provider&.usage
      @plan_restricted_securities = Current.family.securities_with_plan_restrictions(provider: "TwelveData")
    end

    if @show_yahoo_finance_settings
      @yahoo_finance_provider = Provider::Registry.get_provider(:yahoo_finance)
      @yahoo_finance_health_status = @yahoo_finance_provider&.health_status || :unknown
    end

    # Property valuation (AVM) providers — usage is shown against their tight
    # monthly request caps when a key is configured
    @rentcast_usage = Provider::Registry.get_provider(:rentcast)&.usage
    @realie_usage = Provider::Registry.get_provider(:realie)&.usage
    @chimnie_usage = Provider::Registry.get_provider(:chimnie)&.usage

    load_external_assistant_models
  end

  def update
    if hosting_params.key?(:onboarding_state)
      onboarding_state = hosting_params[:onboarding_state].to_s
      Setting.onboarding_state = onboarding_state
    end

    if hosting_params.key?(:demo_family_refresh_enabled) || hosting_params.key?(:demo_family_refresh_family_id)
      unless Current.user.super_admin?
        return redirect_to section_return_path, alert: t(".not_authorized")
      end
      if hosting_params.key?(:demo_family_refresh_family_id)
        family_id = hosting_params[:demo_family_refresh_family_id].presence
        demo_email = Rails.application.config_for(:demo).with_indifferent_access.fetch(:email)
        unless family_id.nil? || User.admin.exists?(family_id: family_id, email: demo_email) && !User.super_admin.exists?(family_id: family_id)
          raise Setting::ValidationError, t(".invalid_demo_family")
        end
        if family_id.nil? && Setting.demo_family_refresh_enabled && hosting_params[:demo_family_refresh_enabled] != "0"
          raise Setting::ValidationError, t(".select_demo_family")
        end
        Setting.demo_family_refresh_family_id = family_id
      end
      if hosting_params.key?(:demo_family_refresh_enabled)
        if hosting_params[:demo_family_refresh_enabled] == "1" && Setting.demo_family_refresh_family_id.blank?
          raise Setting::ValidationError, t(".select_demo_family")
        end
        Setting.demo_family_refresh_enabled = hosting_params[:demo_family_refresh_enabled] == "1"
      end
    end

    if hosting_params.key?(:require_email_confirmation)
      Setting.require_email_confirmation = hosting_params[:require_email_confirmation]
    end

    if hosting_params.key?(:invite_only_default_family_id)
      value = hosting_params[:invite_only_default_family_id].presence
      Setting.invite_only_default_family_id = value
    end

    if hosting_params.key?(:brand_fetch_client_id)
      Setting.brand_fetch_client_id = hosting_params[:brand_fetch_client_id]
    end

    if hosting_params.key?(:brand_fetch_high_res_logos)
      Setting.brand_fetch_high_res_logos = hosting_params[:brand_fetch_high_res_logos] == "1"
    end

    update_encrypted_setting(:twelve_data_api_key)

    if hosting_params.key?(:exchange_rate_provider)
      Setting.exchange_rate_provider = hosting_params[:exchange_rate_provider]
    end

    if hosting_params.key?(:securities_provider)
      Setting.securities_provider = hosting_params[:securities_provider]
    end

    if hosting_params.key?(:securities_providers)
      new_providers = Array(hosting_params[:securities_providers]).reject(&:blank?) & Security.valid_price_providers
      old_providers = Setting.enabled_securities_providers

      Setting.securities_providers = new_providers.join(",")

      Setting.securities_provider = "" if new_providers.empty?

      # Mark securities linked to removed providers as offline so they aren't
      # silently queried against an incompatible fallback provider (e.g. MFAPI
      # scheme codes sent to TwelveData). The price_provider is preserved so
      # provider_status can report :provider_unavailable.
      removed = old_providers - new_providers
      removed.each do |removed_provider|
        Security.where(price_provider: removed_provider, offline: false)
                .in_batches.update_all(offline: true, offline_reason: "provider_disabled")
      end

      # Bring securities back online when their provider is re-enabled — but only
      # those that were taken offline by a provider toggle, not by health checks.
      added = new_providers - old_providers
      added.each do |added_provider|
        Security.where(price_provider: added_provider, offline: true, offline_reason: "provider_disabled")
                .in_batches.update_all(offline: false, offline_reason: nil, failed_fetch_count: 0, failed_fetch_at: nil)
      end
    end

    update_encrypted_setting(:tiingo_api_key)
    update_encrypted_setting(:eodhd_api_key)
    update_encrypted_setting(:alpha_vantage_api_key)
    update_encrypted_setting(:tinkoff_invest_api_key)
    update_encrypted_setting(:mansa_api_key)
    update_encrypted_setting(:rentcast_api_key)
    update_encrypted_setting(:realie_api_key)
    update_encrypted_setting(:chimnie_api_key)

    if hosting_params.key?(:syncs_include_pending)
      Setting.syncs_include_pending = hosting_params[:syncs_include_pending] == "1"
    end

    sync_settings_changed = false

    if hosting_params.key?(:auto_sync_enabled)
      Setting.auto_sync_enabled = hosting_params[:auto_sync_enabled] == "1"
      sync_settings_changed = true
    end

    if hosting_params.key?(:auto_sync_time)
      time_value = hosting_params[:auto_sync_time]
      unless Setting.valid_auto_sync_time?(time_value)
        flash[:alert] = t(".invalid_sync_time")
        return redirect_to section_return_path
      end

      Setting.auto_sync_time = time_value
      Setting.auto_sync_timezone = current_user_timezone
      sync_settings_changed = true
    end

    if sync_settings_changed
      sync_auto_sync_scheduler!
    end

    update_encrypted_setting(:openai_access_token)

    # Validate OpenAI configuration before updating
    if hosting_params.key?(:openai_uri_base) || hosting_params.key?(:openai_model)
      Setting.validate_openai_config!(
        uri_base: hosting_params[:openai_uri_base],
        model: hosting_params[:openai_model]
      )
    end

    if hosting_params.key?(:openai_uri_base)
      Setting.openai_uri_base = hosting_params[:openai_uri_base]
    end

    if hosting_params.key?(:openai_model)
      Setting.openai_model = hosting_params[:openai_model]
    end

    if hosting_params.key?(:openai_json_mode)
      Setting.openai_json_mode = hosting_params[:openai_json_mode].presence
    end

    update_encrypted_setting(:anthropic_access_token)

    if hosting_params.key?(:anthropic_base_url)
      raw_base_url = hosting_params[:anthropic_base_url].to_s.strip
      if raw_base_url.blank?
        Setting.anthropic_base_url = nil
      else
        parsed = URI.parse(raw_base_url) rescue nil
        unless parsed.is_a?(URI::HTTP)
          raise Setting::ValidationError, t(".invalid_anthropic_base_url")
        end
        # A custom Anthropic-compatible endpoint requires a model — Provider::Anthropic
        # raises without one. Validate the pair together (mirrors the OpenAI branch), using
        # the submitted model when present so a blanked model field is caught too.
        effective_model =
          if hosting_params.key?(:anthropic_model)
            hosting_params[:anthropic_model].to_s.strip
          else
            Setting.anthropic_model.to_s.strip
          end
        if effective_model.blank?
          raise Setting::ValidationError, t(".anthropic_model_required_for_base_url")
        end
        Setting.anthropic_base_url = raw_base_url
      end
    end

    if hosting_params.key?(:anthropic_model)
      Setting.anthropic_model = hosting_params[:anthropic_model].presence
    end

    if hosting_params.key?(:llm_provider)
      provider = hosting_params[:llm_provider].to_s
      if Setting::LLM_PROVIDERS.include?(provider)
        Setting.llm_provider = provider
      end
    end

    # The "Local" preset (spec N5) lives entirely in its own Settings; the
    # OpenAI-compatible client reads them at build time (Provider::Registry), so
    # a provider switch never rewrites the cloud fields and the cloud key is
    # never sent to the local endpoint.
    persist_local_llm_settings!
    update_encrypted_setting(:local_llm_token)

    # The cloud document readers: each key is masked/cleared like every other
    # key; a blank model means "use the default", so it is stored as nil.
    update_encrypted_setting(:deepseek_api_key)
    update_encrypted_setting(:gemini_api_key)
    if hosting_params.key?(:cloud_document_fallback)
      Setting.cloud_document_fallback = hosting_params[:cloud_document_fallback] == "1"
    end
    %i[deepseek_model gemini_model].each do |key|
      Setting.public_send(:"#{key}=", hosting_params[key].to_s.strip.presence) if hosting_params.key?(key)
    end

    update_encrypted_setting(:jev_api_key)

    if hosting_params.key?(:jev_endpoint)
      raw_endpoint = hosting_params[:jev_endpoint].to_s.strip
      if raw_endpoint.blank?
        Setting.jev_endpoint = nil
      else
        # Provider::Jev owns the rule so settings, JEV_ENDPOINT and eval-time
        # construction cannot drift apart; the controller's job is only to turn
        # a rejection into a message instead of a 500.
        unless Provider::Jev.endpoint_allowed?(raw_endpoint)
          raise Setting::ValidationError, t(".invalid_jev_endpoint")
        end
        Setting.jev_endpoint = raw_endpoint
      end
    end

    if hosting_params.key?(:jev_model)
      Setting.jev_model = hosting_params[:jev_model].presence
    end

    LLM_NUMERIC_MINIMUMS.each do |key, minimum|
      next unless hosting_params.key?(key)
      raw = hosting_params[key].to_s.strip
      if raw.blank?
        Setting.public_send("#{key}=", nil)
        next
      end
      parsed = Integer(raw, 10) rescue nil
      if parsed.nil? || parsed < minimum
        label = t("settings.hostings.openai_settings.#{key}_label")
        raise Setting::ValidationError, t(".invalid_llm_budget", field: label, minimum: minimum)
      end
      Setting.public_send("#{key}=", parsed)
    end

    reselect_external_agent = update_external_assistant_settings!

    update_assistant_type
    update_categorization_provider
    update_categorization_tuning

    if reselect_external_agent
      redirect_to section_return_path, alert: t("settings.hostings.assistant_settings.external_agent_reselect")
    else
      redirect_to section_return_path, notice: t(".success")
    end
  rescue Setting::ValidationError => error
    # Preserve user-submitted OpenAI config so the form re-renders with their
    # input intact (issue #1824). The form auto-submits on blur, so a partial
    # entry (e.g. URI base before model) hits validation and would otherwise
    # be wiped because the view reads from the unchanged Setting.* values.
    @openai_uri_base_input = hosting_params[:openai_uri_base] if hosting_params.key?(:openai_uri_base)
    @openai_model_input = hosting_params[:openai_model] if hosting_params.key?(:openai_model)
    @anthropic_base_url_input = hosting_params[:anthropic_base_url] if hosting_params.key?(:anthropic_base_url)
    @anthropic_model_input = hosting_params[:anthropic_model] if hosting_params.key?(:anthropic_model)
    @jev_endpoint_input = hosting_params[:jev_endpoint] if hosting_params.key?(:jev_endpoint)
    @jev_model_input = hosting_params[:jev_model] if hosting_params.key?(:jev_model)
    @local_llm_base_url_input = hosting_params[:local_llm_base_url] if hosting_params.key?(:local_llm_base_url)
    @local_llm_model_input = hosting_params[:local_llm_model] if hosting_params.key?(:local_llm_model)
    flash.now[:alert] = error.message
    # Nothing was saved, so reload the agent options from the stored config;
    # otherwise the 422 page shows an empty, disabled agent dropdown.
    load_external_assistant_models
    @section = section_from_referer
    render :show, status: :unprocessable_entity
  end

  def clear_cache
    DataCacheClearJob.perform_later(Current.family)
    redirect_to section_return_path, notice: t(".cache_cleared")
  end

  def disconnect_external_assistant
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil
    Setting.external_assistant_model = nil
    Setting.external_assistant_agent_id = nil
    Current.family.update!(assistant_type: "builtin") unless ENV["ASSISTANT_TYPE"].present?
    redirect_to section_return_path, notice: t(".external_assistant_disconnected")
  rescue => e
    Rails.logger.error("[External Assistant] Disconnect failed: #{e.message}")
    redirect_to section_return_path, alert: t("settings.hostings.update.failure")
  end

  # Probes the user's own hardware for a running OpenAI-compatible server and
  # returns its installed models plus a recommendation for the document read.
  # Runs ON DEMAND (the Detect button), never on page load: the Docker-to-host
  # hop can be firewalled, and a synchronous probe in `show` would stall the
  # settings page. All logic lives in LocalLlm; this stays thin and returns 200
  # for every business outcome so the client renders a message rather than
  # treating "no server" as a crash.
  def detect_local_models
    # Probe whatever the user has typed (the advanced field) first, else the
    # stored base URL — so a previously-saved working address is checked before
    # the defaults.
    submitted = hosting_params[:local_llm_base_url].to_s.strip.presence
    base_url = submitted || Setting.local_llm_base_url.presence
    # The local endpoint's OWN token only — the cloud key is never sent to a
    # probe of an attacker-influenceable URL (see LocalLlm::Discovery).
    token = Setting.local_llm_token.presence || Setting::LOCAL_LLM_PLACEHOLDER_TOKEN

    result = LocalLlm::Discovery.new(base_url: base_url, token: token).call

    if result.models.empty?
      render json: { status: "empty", base_url: result.base_url, server: result.server.to_s }
    else
      recommender = LocalLlm::Recommender.new(result.models)
      recommendation = recommender.recommendation

      render json: {
        status: "ok",
        base_url: result.base_url,
        server: result.server.to_s,
        recommended_model: recommendation&.dig(:top_pick),
        recommendation: recommendation && {
          model: recommendation[:top_pick],
          tier: recommendation[:tier].to_s,
          reason: recommendation[:reason]
        },
        models: result.models.map { |model|
          {
            id: model[:id],
            label: model[:label],
            suitability: recommender.suitability_for(model[:id]),
            recommended: recommendation&.dig(:top_pick) == model[:id]
          }
        }
      }
    end
  rescue LocalLlm::Discovery::NotFound => e
    render json: { status: "not_found", attempts: e.attempts }, status: :ok
  rescue => e
    Rails.logger.error("Local model detection failed: #{e.class}: #{e.message}")
    render json: { status: "error", message: t("settings.hostings.local_settings.detect_error") }, status: :ok
  end

  # Persists the model + base URL Detect found, without a page reload — so a
  # user who clicks Detect and walks away ends up with a working Local
  # configuration, and the full detected list stays on screen. A blank model is
  # ignored (never clears a saved one); a blank base URL is ignored likewise.
  def persist_local_model
    model = hosting_params[:local_llm_model].to_s.strip
    base_url = hosting_params[:local_llm_base_url].to_s.strip

    Setting.local_llm_model = model if model.present?
    Setting.local_llm_base_url = base_url if base_url.present?

    render json: { status: "ok", model: Setting.local_llm_model, base_url: Setting.local_llm_base_url }
  rescue => e
    Rails.logger.error("Local model persist failed: #{e.class}: #{e.message}")
    render json: { status: "error", message: t("settings.hostings.local_settings.save_error") }, status: :ok
  end

  private
    # A form on any of the three pages posts here; send it back to its page.
    def section_return_path
      { "ai" => settings_ai_path, "data" => settings_data_providers_path }.fetch(section_from_referer, settings_hosting_path)
    end

    def section_from_referer
      path = begin
        URI.parse(request.referer.to_s).path
      rescue URI::InvalidURIError
        nil
      end
      from_page = { settings_ai_path => "ai", settings_data_providers_path => "data" }[path]
      from_page || section_from_fields
    end

    # Without a referring page (an API client, a test), the submitted fields
    # say which page they belong to.
    AI_FIELDS = /\A(openai|anthropic|local_llm|llm_|ai_|jev|assistant|deepseek|gemini|cloud_reader|external_assistant|categorization)/
    DATA_FIELDS = /\A(twelve_data|tiingo|eodhd|alpha_vantage|tinkoff|mansa|yahoo|exchange_rate|securities|brand_fetch|rentcast|realie|chimnie)/
    def section_from_fields
      keys = params.fetch(:setting, {}).keys.map(&:to_s) + params.keys.map(&:to_s)
      return "ai" if keys.any? { |key| key.match?(AI_FIELDS) }
      return "data" if keys.any? { |key| key.match?(DATA_FIELDS) }

      "hosting"
    end

    # Strong parameters for the self-hosting settings form.
    def hosting_params
      return ActionController::Parameters.new unless params.key?(:setting)
      params.require(:setting).permit(:onboarding_state, :require_email_confirmation, :invite_only_default_family_id, :demo_family_refresh_enabled, :demo_family_refresh_family_id, :brand_fetch_client_id, :brand_fetch_high_res_logos, :twelve_data_api_key, :tiingo_api_key, :eodhd_api_key, :alpha_vantage_api_key, :tinkoff_invest_api_key, :mansa_api_key, :rentcast_api_key, :realie_api_key, :chimnie_api_key, :openai_access_token, :openai_uri_base, :openai_model, :openai_json_mode, :anthropic_access_token, :anthropic_base_url, :anthropic_model, :jev_api_key, :jev_endpoint, :jev_model, :llm_provider, :local_llm_base_url, :local_llm_model, :local_llm_token, :deepseek_api_key, :deepseek_model, :gemini_api_key, :gemini_model, :cloud_document_fallback, :llm_context_window, :llm_max_response_tokens, :llm_max_items_per_call, :openai_request_timeout, :ai_response_timeout, :ai_health_probe_timeout, :exchange_rate_provider, :securities_provider, :syncs_include_pending, :auto_sync_enabled, :auto_sync_time, :external_assistant_url, :external_assistant_token, :external_assistant_model, securities_providers: [])
    end

    def load_external_assistant_models
      @external_assistant_models = []
      @external_assistant_catalog_error = nil
      return unless Current.family.effective_assistant_type == "external"

      config = Assistant::External.config
      return unless config.url.present? && config.token.present?

      # Rendered synchronously, so keep a stalled gateway from holding the page.
      @external_assistant_models = Assistant::External::ModelCatalog.new(
        url: config.url,
        token: config.token,
        open_timeout: 3,
        read_timeout: 5
      ).models
    rescue Assistant::External::ModelCatalog::Error => error
      @external_assistant_catalog_error = error.message
    end

    # Validates the submitted endpoint, token and agent together before any of
    # them is written, so a rejected change leaves the stored config untouched.
    # Returns true when the connection changed and the old agent must be reselected.
    def update_external_assistant_settings!
      keys = %i[external_assistant_url external_assistant_token external_assistant_model]
      return false unless keys.any? { |key| hosting_params.key?(key) }

      current = Assistant::External.config
      url = ENV["EXTERNAL_ASSISTANT_URL"].presence || submitted_external_assistant_url(current.url)
      token = ENV["EXTERNAL_ASSISTANT_TOKEN"].presence || submitted_external_assistant_token(current.token)
      connection_changed = url != current.url || token != current.token

      model_submitted = hosting_params.key?(:external_assistant_model)
      model = model_submitted ? hosting_params[:external_assistant_model].presence : Setting.external_assistant_model.presence
      raise Setting::ValidationError, t("settings.hostings.assistant_settings.external_agent_required") if model_submitted && model.blank?

      reselect = false
      if model_submitted
        unless external_assistant_model_ids(url, token).include?(model)
          raise Setting::ValidationError, t("settings.hostings.assistant_settings.external_agent_invalid") unless connection_changed

          # The agent list on the page came from the previous connection. Save
          # the new connection, but never pair it with an agent it does not offer.
          model = nil
          reselect = true
        end
      elsif connection_changed && model.present? && ENV["EXTERNAL_ASSISTANT_MODEL"].blank?
        available = begin
          external_assistant_model_ids(url, token)
        rescue Setting::ValidationError
          []
        end
        unless available.include?(model)
          model = nil
          reselect = true
        end
      end

      Setting.transaction do
        Setting.external_assistant_url = hosting_params[:external_assistant_url] if hosting_params.key?(:external_assistant_url)
        update_encrypted_setting(:external_assistant_token)
        if model_submitted || reselect
          Setting.external_assistant_model = model
          Setting.external_assistant_agent_id = nil
        end
      end

      reselect
    end

    def submitted_external_assistant_url(current_url)
      return current_url unless hosting_params.key?(:external_assistant_url)

      hosting_params[:external_assistant_url].presence
    end

    def submitted_external_assistant_token(current_token)
      return current_token unless hosting_params.key?(:external_assistant_token)

      value = hosting_params[:external_assistant_token].to_s.strip
      value == "********" ? current_token : value.presence
    end

    def external_assistant_model_ids(url, token)
      Assistant::External::ModelCatalog.new(url: url, token: token).models.pluck(:id)
    rescue Assistant::External::ModelCatalog::Error => error
      raise Setting::ValidationError, t("settings.hostings.assistant_settings.agent_discovery_error", error: error.message)
    end

    # Family-scoped, like assistant_type: it decides whose transaction data is
    # sent to Jev. Guarded by the preview gate because the selector that submits
    # it is only rendered for opted-in users.
    def update_categorization_provider
      return unless params[:family].present? && params[:family][:categorization_provider].present?
      return if ENV["CATEGORIZATION_PROVIDER"].present?
      return unless preview_features_enabled?

      provider = params[:family][:categorization_provider]
      return unless Family::CATEGORIZATION_PROVIDERS.include?(provider)

      Current.family.update!(categorization_provider: provider)
    end

    # Family-scoped like categorization_provider. Validated here rather than
    # leaning on the DB check constraint, which would surface as a 500 instead
    # of the inline error the rest of this form gives.
    def update_categorization_tuning
      return unless params[:family].present?
      return unless preview_features_enabled?

      updates = {}

      if params[:family][:categorization_confidence_threshold].present? && ENV["CATEGORIZATION_CONFIDENCE_THRESHOLD"].blank?
        updates[:categorization_confidence_threshold] = unit_interval!(
          params[:family][:categorization_confidence_threshold],
          t("settings.hostings.categorization_provider_selector.confidence_threshold_label")
        )
      end

      if params[:family][:categorization_shadow_rate].present? && ENV["CATEGORIZATION_SHADOW_RATE"].blank?
        updates[:categorization_shadow_rate] = unit_interval!(
          params[:family][:categorization_shadow_rate],
          t("settings.hostings.categorization_provider_selector.shadow_rate_label")
        )
      end

      Current.family.update!(updates) if updates.any?
    end

    def unit_interval!(raw, field_label)
      value = Float(raw.to_s.strip) rescue nil

      if value.nil? || value.negative? || value > 1
        raise Setting::ValidationError,
              t("settings.hostings.update.invalid_categorization_rate", field: field_label)
      end

      value
    end

    def update_assistant_type
      return unless params[:family].present? && params[:family][:assistant_type].present?
      return if ENV["ASSISTANT_TYPE"].present?

      assistant_type = params[:family][:assistant_type]
      Current.family.update!(assistant_type: assistant_type) if Family::ASSISTANT_TYPES.include?(assistant_type)
    end

    def ensure_admin
      redirect_to section_return_path, alert: t(".not_authorized") unless Current.user.admin?
    end

    def ensure_super_admin_for_onboarding
      onboarding_params = %i[onboarding_state invite_only_default_family_id]
      return unless onboarding_params.any? { |p| hosting_params.key?(p) }
      redirect_to section_return_path, alert: t(".not_authorized") unless Current.user.super_admin?
    end

    def sync_auto_sync_scheduler!
      AutoSyncScheduler.sync!
    rescue StandardError => error
      Rails.logger.error("[AutoSyncScheduler] Failed to sync scheduler: #{error.message}")
      Rails.logger.error(error.backtrace.join("\n"))
      flash[:alert] = t(".scheduler_sync_failed")
    end

    def update_encrypted_setting(param_key)
      return unless hosting_params.key?(param_key)
      value = hosting_params[param_key].to_s.strip

      # "********" is the masked placeholder rendered for an existing key; it
      # means "leave the stored value untouched". A blank submission, however,
      # is an explicit request to clear the key, so persist nil in that case.
      return if value == "********"

      Setting.public_send(:"#{param_key}=", value.presence)
    end

    def current_user_timezone
      Current.family&.timezone.presence || "UTC"
    end

    # Persists the "Local" preset (spec N5) under its own Settings. A blank
    # submission clears it so the base URL falls back to the constant default.
    # The token is handled by update_encrypted_setting (masked-placeholder aware).
    def persist_local_llm_settings!
      if hosting_params.key?(:local_llm_base_url)
        Setting.local_llm_base_url = hosting_params[:local_llm_base_url].to_s.strip.presence
      end
      if hosting_params.key?(:local_llm_model)
        Setting.local_llm_model = hosting_params[:local_llm_model].to_s.strip.presence
      end
    end
end
