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
  CLOUD = { deepseek: "DeepSeek", gemini: "Gemini", gemini_lite: "Gemini (lite)" }.freeze

  # `fallback_for` names the reader this one only stands in for when that one
  # was overloaded (Gemini's lighter model for Gemini).
  Reader = Data.define(:provider, :kind, :label, :guard, :fallback_for) do
    def initialize(fallback_for: nil, **fields) = super(fallback_for: fallback_for, **fields)

    def local? = kind == :local

    # How much a read from this reader is trusted when nothing could verify it:
    # the cloud readers over the selected provider over the local model, and a
    # lighter fallback model below the one it stands in for.
    def strength
      case kind
      when :cloud then fallback_for ? 2 : 3
      when :selected then 2
      else 1
      end
    end
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

    # A cloud service already chosen as the AI provider is the selected reader;
    # it is not tried a second time as a fallback (2026-10-17).
    def cloud_readers
      CLOUD.filter_map do |name, label|
        next if @mode != "online" && name.to_s == Setting.llm_provider.to_s
        provider = Provider::Registry.get_provider(name)
        provider && Reader.new(provider: provider, kind: :cloud, label: label, guard: nil,
                               fallback_for: (CLOUD[:gemini] if name == :gemini_lite))
      end
    end

    def provider_label(provider)
      provider.respond_to?(:provider_name) ? provider.provider_name.to_s : provider.to_s
    end
end
