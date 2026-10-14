module Provider::LlmConcept
  extend ActiveSupport::Concern

  AutoCategorization = Data.define(:transaction_id, :category_name)

  def auto_categorize(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_categorize"
  end

  AutoDetectedMerchant = Data.define(:transaction_id, :business_name, :business_url)

  def auto_detect_merchants(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_detect_merchants"
  end

  EnhancedMerchant = Data.define(:merchant_id, :business_url)

  def enhance_provider_merchants(merchants)
    raise NotImplementedError, "Subclasses must implement #enhance_provider_merchants"
  end

  # One proposed recurring-bill configuration, inferred from charge history.
  # Every field is nullable: null means the history cannot support a value
  # (or, in configure mode, that the current configuration is already right).
  BillSetupSuggestion = Data.define(
    :name, :amount, :frequency, :day_of_month, :weekday, :month_of_year,
    :category_name, :bill_type, :autopay, :confidence, :rationale
  )

  def suggest_bill_setup(charges:, categories: [], current_config: nil, model: "", family: nil)
    raise NotImplementedError, "Subclasses must implement #suggest_bill_setup"
  end

  PdfProcessingResult = Data.define(:summary, :document_type, :extracted_data)

  def supports_pdf_processing?
    false
  end

  def process_pdf(pdf_content:, family: nil)
    raise NotImplementedError, "Provider does not support PDF processing"
  end

  # One document read as a typed verdict. The images and the OCR text travel
  # together (spec N4); a provider that cannot take images cannot honour this.
  # `rows_expected: false` asks for the identity fields only (the caller has
  # already proven the statement's rows deterministically).
  def understand_document(pages:, ocr_text:, family: nil, model: "", rows_expected: true)
    raise NotImplementedError, "Provider does not support document understanding"
  end

  def supports_document_understanding?
    false
  end

  ChatMessage = Data.define(:id, :output_text)
  ChatStreamChunk = Data.define(:type, :data, :usage)
  ChatResponse = Data.define(:id, :model, :messages, :function_requests)
  ChatFunctionRequest = Data.define(:id, :call_id, :function_name, :function_args, :extra_content) do
    def initialize(id:, call_id:, function_name:, function_args:, extra_content: nil)
      super
    end
  end

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    tool_choice: nil,
    messages: nil,
    conversation_history: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil
  )
    raise NotImplementedError, "Subclasses must implement #chat_response"
  end
end
