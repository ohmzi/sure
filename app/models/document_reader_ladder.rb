# frozen_string_literal: true

# The order a document's model read is tried in (spec §2): the household's
# selected provider first — the local model when "Local" is selected — then the
# cloud readers, DeepSeek before Gemini, when automatic cloud fallback is on.
# The two retry buttons each take one rung: "local" is the local model alone,
# "online" the cloud readers alone (the owner asked, so the switch is moot).
#
# Only a local reader carries a GPU guard: the busy check and the unload are
# about the shared card, which a cloud reader never touches.
class DocumentReaderLadder
  MODES = %w[auto local online].freeze
  CLOUD = { deepseek: "DeepSeek", gemini: "Gemini" }.freeze

  Reader = Data.define(:provider, :kind, :label, :guard) do
    def local? = kind == :local
  end

  def self.for(mode:)
    new(mode.to_s).readers
  end

  def initialize(mode)
    @mode = MODES.include?(mode) ? mode : "auto"
  end

  def readers
    case @mode
    when "local" then [ local_reader ].compact
    when "online" then cloud_readers
    else [ selected_reader, *(cloud_readers if Setting.cloud_document_fallback) ].compact
    end
  end

  private
    def selected_reader
      return local_reader if Setting.llm_provider == "local"

      provider = Provider::Registry.preferred_llm_provider
      provider && Reader.new(provider: provider, kind: :selected, label: provider_label(provider), guard: nil)
    end

    def local_reader
      provider = Provider::Registry.local_document_reader
      return nil unless provider

      model = Setting.local_llm_model
      Reader.new(provider: provider, kind: :local, label: I18n.t("document_reader_ladder.local", model: model),
                 guard: LocalLlm::GpuGuard.new(base_url: Setting.local_llm_base_url, model: model))
    end

    def cloud_readers
      CLOUD.filter_map do |name, label|
        provider = Provider::Registry.get_provider(name)
        provider && Reader.new(provider: provider, kind: :cloud, label: label, guard: nil)
      end
    end

    def provider_label(provider)
      provider.respond_to?(:provider_name) ? provider.provider_name.to_s : provider.to_s
    end
end
