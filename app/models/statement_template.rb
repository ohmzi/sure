# Deterministic, versioned bank-statement templates used to turn paperless OCR
# text into rows when no LLM provider is configured (spec §8.2). A template is
# selected by matching the statement's header; an unknown bank returns nil so
# the caller can archive the statement in the `needs_template` state instead of
# guessing (spec §8.6).
class StatementTemplate
  # Registry of known templates, tried in order. Add banks here as real
  # samples arrive (spec §16.2); each template owns its own version. Names are
  # resolved lazily so loading this file never triggers the template autoload.
  TEMPLATE_CLASS_NAMES = %w[
    StatementTemplate::Bank::Chase
  ].freeze

  def self.templates
    TEMPLATE_CLASS_NAMES.map(&:constantize)
  end

  def self.detect(text)
    return nil if text.blank?

    templates.each do |klass|
      return klass.new if klass.matches?(text)
    end

    nil
  end

  def self.matches?(_text)
    raise NotImplementedError, "Subclass must implement matches?"
  end

  def version
    self.class::VERSION
  end

  def bank_key
    self.class::BANK_KEY
  end

  def rows(_text)
    raise NotImplementedError, "Subclass must implement rows"
  end
end
