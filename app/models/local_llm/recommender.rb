# frozen_string_literal: true

# Ranks the models a local OpenAI-compatible server reports, for the document
# read. That read (Provider::Openai::DocumentReader) sends the page IMAGES
# alongside the OCR text, so the one hard requirement is that a model accepts
# image input; everything else is a quality-versus-CPU tradeoff. Pure and
# I/O-free, so it is cheap to unit test and reusable from the controller and
# the panel alike.
class LocalLlm::Recommender
  # Best first. `:needs_instruct` sits just behind `:recommended`: a strong
  # vision model whose default tag is the thinking variant that wrecks flat
  # JSON until the -instruct tag is pulled. `:text_only` is never ranked and
  # never recommended — it cannot read the images at all.
  TIERS = %i[recommended needs_instruct good fair heavy light vision_unknown text_only].freeze

  # Only these Gemma 3 sizes ship a vision tower. The 1B is text-only, so it can
  # never read the page images the document read sends — it must not be offered
  # as vision-capable, however good the family's larger sizes are.
  GEMMA3_VISION_SIZES = %w[4b 12b 27b].freeze

  # Per-model one-liners shown beside each option in the picker.
  SUITABILITY = {
    recommended: "Best fit — reads page images and dense tables, and is quick enough on CPU.",
    needs_instruct: "Vision-capable, but pull the -instruct tag: the default tag is the thinking variant that breaks flat JSON.",
    good: "Accurate on dense tables, but slow on CPU (roughly 1-3 minutes per page).",
    fair: "Vision-capable and fast, but less reliable on dense tabular statements.",
    heavy: "Heaviest option here — practical only with a GPU.",
    light: "Fast on CPU, but too weak for dense statement tables.",
    vision_unknown: "Accepts images, but its accuracy on statements is unverified.",
    text_only: "Text-only — it cannot read document images, so it cannot do this job."
  }.freeze

  # Why the recommendation picked this tier, appended to "Best for reading your documents".
  REASONS = {
    recommended: "it is the best accuracy per CPU-second for reading dense statements.",
    needs_instruct: "it is a strong vision model once the -instruct tag is pulled.",
    good: "it is the most accurate local option, at the cost of slower reads.",
    fair: "it is a workable vision model, though weaker on dense tables.",
    heavy: "it is vision-capable but slow without a GPU.",
    light: "it is fast, but only suited to light documents.",
    vision_unknown: "it accepts images, though its accuracy on statements is unverified."
  }.freeze

  def initialize(models)
    @ids = Array(models).map { |model| extract_id(model) }.reject(&:blank?)
  end

  # -> one of TIERS
  def classify(id)
    name = id.to_s.downcase.strip
    return :text_only if name.blank?

    # Qwen2.5-VL: the 3b is the CPU top pick, everything else in the family is
    # the accuracy fallback. Accept both "qwen2.5vl" and the hyphenated
    # "qwen2.5-vl". Compare the parameter token exactly so a ":13b" tag is not
    # mistaken for ":3b".
    if name.match?(/qwen2\.5-?vl/)
      return size_token(name).start_with?("3b") ? :recommended : :good
    end

    # Qwen3-VL: only the -instruct tag is flat-JSON-safe; the bare/default tag
    # is the thinking variant that emits long chain-of-thought.
    if name.match?(/qwen3-?vl/)
      return name.include?("instruct") ? :recommended : :needs_instruct
    end

    return :fair if name.match?(/minicpm-v/)
    return gemma3_vision?(name) ? :fair : :text_only if name.match?(/gemma3/)
    return :heavy if name.match?(/llama3\.2-vision/)
    return :light if name.match?(/granite3\.2-vision|moondream/)
    return :vision_unknown if name.match?(/(^|[^a-z])vl|vision|llava/)

    :text_only
  end

  def vision_capable?(id)
    classify(id) != :text_only
  end

  def suitability_for(id)
    SUITABILITY.fetch(classify(id), SUITABILITY[:vision_unknown])
  end

  # -> { top_pick:, tier:, reason: } for the best installed vision model, or nil
  # when nothing installed can read images (or nothing is installed at all).
  def recommendation
    vision = @ids.select { |id| vision_capable?(id) }
    return nil if vision.empty?

    best = vision.min_by { |id| TIERS.index(classify(id)) }
    { top_pick: best, tier: classify(best), reason: REASONS.fetch(classify(best)) }
  end

  private
    def extract_id(model)
      value = model.is_a?(Hash) ? (model[:id] || model["id"]) : model
      value.to_s.strip
    end

    # The tag after the colon, e.g. "qwen2.5vl:3b-instruct" -> "3b-instruct".
    def size_token(name)
      name.split(":").last.to_s
    end

    # Gemma 3 is vision-capable only for the multimodal sizes; a bare tag or
    # "latest" is the family default (27b, multimodal). Any other size (1b) has
    # no vision tower.
    def gemma3_vision?(name)
      token = size_token(name)
      return true if token == name || token == "latest"

      GEMMA3_VISION_SIZES.any? { |size| token.start_with?(size) }
    end
end
