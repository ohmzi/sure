class Provider::Registry
  include ActiveModel::Validations

  Error = Class.new(StandardError)

  CONCEPTS = %i[exchange_rates securities llm property_valuations classification]

  validates :concept, inclusion: { in: CONCEPTS }

  class << self
    def for_concept(concept)
      new(concept.to_sym)
    end

    def get_provider(name)
      send(name)
    rescue NoMethodError
      raise Error.new("Provider '#{name}' not found in registry")
    end

    # Resolves the LLM provider for batch/PDF flows, honoring Setting.llm_provider
    # the way chat does: prefer the configured provider, but fall back to whichever
    # one actually has credentials so an install that swaps providers (or has only
    # one configured) keeps working. Returns nil when neither is configured —
    # callers guard on that.
    #
    # "Local" (spec N5) is a no-egress choice: it resolves ONLY to the local
    # endpoint. With no local model named there is nothing to read with, so it
    # resolves to nil — the document is held and the reason shown — and never
    # silently falls back to a cloud provider.
    def preferred_llm_provider
      return openai if Setting.llm_provider == "local"

      order = llm_provider_order
      order.each do |name|
        provider = get_provider(name)
        return provider if provider
      end
      nil
    end

    # The LLM providers in the order they are tried: the selected one first,
    # then OpenAI and Anthropic, then DeepSeek and Gemini. DeepSeek and Gemini
    # accept any model name, so unselected they must come last or they would
    # claim another provider's models.
    def llm_provider_order
      selected = Setting.llm_provider.to_s.to_sym
      base = %i[openai anthropic deepseek gemini]
      base.include?(selected) ? [ selected, *(base - [ selected ]) ] : base
    end

    # The cloud services a document can be read with, in the order they are
    # tried: the configured ones only, so an empty list means "no cloud reader".
    def cloud_document_readers
      %i[deepseek gemini].filter_map { |name| get_provider(name) }
    end

    # The local model as a document reader, whichever provider is selected —
    # what "Retry with local model" reads with. Bounded per call so one page can
    # never hold the GPU past Setting.local_llm_call_timeout.
    def local_document_reader
      model = Setting.local_llm_model.presence
      return nil if model.blank?

      Provider::Openai.new(Setting.local_llm_token.presence || Setting::LOCAL_LLM_PLACEHOLDER_TOKEN,
                           uri_base: Setting.local_llm_base_url.presence || Setting::LOCAL_LLM_DEFAULT_BASE_URL,
                           model: model, request_timeout: Setting.local_llm_call_timeout)
    end

    def plaid_provider_for_region(region)
      region.to_sym == :us ? plaid_us : plaid_eu
    end

    private
      def stripe
        secret_key = ENV["STRIPE_SECRET_KEY"]
        webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"]

        return nil unless secret_key.present? && webhook_secret.present?

        Provider::Stripe.new(secret_key:, webhook_secret:)
      end

      def twelve_data
        api_key = ENV["TWELVE_DATA_API_KEY"].presence || Setting.twelve_data_api_key

        return nil unless api_key.present?

        Provider::TwelveData.new(api_key)
      end

      def plaid_us
        Provider::PlaidAdapter.ensure_configuration_loaded
        config = Rails.application.config.plaid

        return nil unless config.present?

        Provider::Plaid.new(config, region: :us)
      end

      def plaid_eu
        Provider::PlaidEuAdapter.ensure_configuration_loaded
        config = Rails.application.config.plaid_eu

        return nil unless config.present?

        Provider::Plaid.new(config, region: :eu)
      end

      def github
        Provider::Github.new
      end

      def openai
        # The "Local" selection (spec N5) is the OpenAI-compatible protocol
        # pointed at the user's own hardware, with its OWN credentials — built
        # here, from the local settings, so the cloud key in Setting.openai_* is
        # never sent to the local URL and a provider switch never rewrites it.
        return local_openai if Setting.llm_provider == "local"

        access_token = ENV["OPENAI_ACCESS_TOKEN"].presence || Setting.openai_access_token

        return nil unless access_token.present?

        uri_base = ENV["OPENAI_URI_BASE"].presence || Setting.openai_uri_base
        model = ENV["OPENAI_MODEL"].presence || Setting.openai_model

        if uri_base.present? && model.blank?
          Rails.logger.error("Custom OpenAI provider configured without a model; please set OPENAI_MODEL or Setting.openai_model")
          return nil
        end

        Provider::Openai.new(access_token, uri_base: uri_base, model: model)
      end

      # The local endpoint's client. Reads Setting.local_llm_base_url / model /
      # token only. With no model named it returns nil (unconfigured) rather than
      # building a half-client, so the "no AI provider is configured" hold stands
      # until the user names a vision model.
      def local_openai
        model = Setting.local_llm_model.presence
        return nil if model.blank?

        uri_base = Setting.local_llm_base_url.presence || Setting::LOCAL_LLM_DEFAULT_BASE_URL
        access_token = Setting.local_llm_token.presence || Setting::LOCAL_LLM_PLACEHOLDER_TOKEN

        Provider::Openai.new(access_token, uri_base: uri_base, model: model)
      end

      # DeepSeek and Gemini both speak the OpenAI chat protocol, so each is the
      # OpenAI-compatible client pointed at its own endpoint with its own key.
      def deepseek
        api_key = Setting.deepseek_api_key.presence
        return nil unless api_key

        Provider::Openai.new(api_key, uri_base: "https://api.deepseek.com",
                                      model: Setting.deepseek_model.presence || Setting::DEEPSEEK_DEFAULT_MODEL,
                                      cap_document_reads: false)
      end

      def gemini
        api_key = Setting.gemini_api_key.presence
        return nil unless api_key

        Provider::Openai.new(api_key, uri_base: "https://generativelanguage.googleapis.com/v1beta/openai",
                                      model: Setting.gemini_model.presence || Setting::GEMINI_DEFAULT_MODEL,
                                      cap_document_reads: false)
      end

      # Gemini's lighter model as its own rung — absent when it is already the
      # configured model.
      def gemini_lite
        api_key = Setting.gemini_api_key.presence
        return nil unless api_key
        return nil if (Setting.gemini_model.presence || Setting::GEMINI_DEFAULT_MODEL) == Setting::GEMINI_FALLBACK_MODEL

        Provider::Openai.new(api_key, uri_base: "https://generativelanguage.googleapis.com/v1beta/openai",
                                      model: Setting::GEMINI_FALLBACK_MODEL, cap_document_reads: false)
      end

      def anthropic
        access_token = ENV["ANTHROPIC_ACCESS_TOKEN"].presence ||
                       ENV["ANTHROPIC_API_KEY"].presence ||
                       Setting.anthropic_access_token

        return nil unless access_token.present?

        base_url = ENV["ANTHROPIC_BASE_URL"].presence || Setting.anthropic_base_url
        model = ENV["ANTHROPIC_MODEL"].presence || Setting.anthropic_model

        Provider::Anthropic.new(access_token, base_url: base_url, model: model)
      end

      def jev
        api_key = Provider::Jev.api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::Jev.new(
          api_key,
          endpoint: Provider::Jev.effective_endpoint,
          model: Provider::Jev.effective_model
        )
      end

      def yahoo_finance
        Provider::YahooFinance.new
      end

      def tiingo
        api_key = ENV["TIINGO_API_KEY"].presence || Setting.tiingo_api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::Tiingo.new(api_key)
      end

      def eodhd
        api_key = ENV["EODHD_API_KEY"].presence || Setting.eodhd_api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::Eodhd.new(api_key)
      end

      def alpha_vantage
        api_key = ENV["ALPHA_VANTAGE_API_KEY"].presence || Setting.alpha_vantage_api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::AlphaVantage.new(api_key)
      end

      def mansa
        api_key = ENV["MANSA_API_KEY"].presence || Setting.mansa_api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::Mansa.new(api_key)
      end

      def mfapi
        Provider::Mfapi.new
      end

      def binance_public
        Provider::BinancePublic.new
      end

      def moex_public
        Provider::MoexPublic.new
      end

      def frankfurter
        Provider::Frankfurter.new
      end

      def tinkoff_invest
        api_key = ENV["TINKOFF_INVEST_API_KEY"].presence || Setting.tinkoff_invest_api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::TinkoffInvest.new(api_key)
      end

      def rentcast
        api_key = ENV["RENTCAST_API_KEY"].presence || Setting.rentcast_api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::Rentcast.new(api_key)
      end

      def realie
        api_key = ENV["REALIE_API_KEY"].presence || Setting.realie_api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::Realie.new(api_key)
      end

      def chimnie
        api_key = ENV["CHIMNIE_API_KEY"].presence || Setting.chimnie_api_key # pipelock:ignore

        return nil unless api_key.present?

        Provider::Chimnie.new(api_key)
      end
  end

  def initialize(concept)
    @concept = concept
    validate!
  end

  def providers
    available_providers.map { |p| self.class.send(p) }.compact
  end

  # Returns the list of provider key names (symbols) registered for this concept.
  def provider_keys
    available_providers
  end

  def get_provider(name)
    provider_method = available_providers.find { |p| p == name.to_sym }

    raise Error.new("Provider '#{name}' not found for concept: #{concept}") unless provider_method.present?

    self.class.send(provider_method)
  end

  private
    attr_reader :concept

    def available_providers
      case concept
      when :exchange_rates
        %i[twelve_data yahoo_finance moex_public frankfurter]
      when :securities
        %i[twelve_data yahoo_finance tiingo eodhd alpha_vantage mfapi binance_public moex_public tinkoff_invest mansa]
      when :llm
        self.class.llm_provider_order
      when :classification
        # Only providers implementing Provider::ClassificationConcept#decide
        # belong here. OpenAI and Anthropic can auto-categorize but cannot
        # answer typed questions, so they stay under :llm — the eval runner
        # builds them by name when benchmarking against Jev.
        %i[jev]
      when :property_valuations
        %i[rentcast realie chimnie]
      else
        %i[plaid_us plaid_eu github openai anthropic]
      end
    end
end
