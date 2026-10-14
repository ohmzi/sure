# frozen_string_literal: true

# One document, one call. Follows AutoCategorizer's shape: a PORO holding the
# client, the model and the JSON-mode fallback ladder, returning a typed value
# rather than a raw hash.
#
# The request carries the page images as data URLs AND the OCR text as a
# separate part. That duplication is the point: the model structures what it
# sees, the OCR text pins the digits, and Task 7 compares the two totals.
class Provider::Openai::DocumentReader
  include Provider::Openai::Concerns::UsageRecorder

  INSTRUCTIONS = <<~TEXT.freeze
    You read financial documents. You are given the page images of ONE
    document and, separately, the text an OCR engine extracted from the same
    pages. Use BOTH: the images show the layout, the OCR text pins exact
    digits. Where they disagree, trust the images for structure and the OCR
    text for characters, and lower the field confidence.

    Return ONE flat JSON object with exactly these keys:
    - document_class: one of #{DocumentUnderstanding::CLASSES.map(&:inspect).join(", ")}
    - institution_name, account_last4, card_last4, card_network, currency,
      total, date, payee: a string, or null when the document does not show it.
      card_network, when present, is one of #{Account::CARD_NETWORKS.map(&:inspect).join(", ")}.
    - statement_period: an object {"start": string|null, "end": string|null},
      or null when the document has no statement period.
    - line_items: an array of objects {"description": string, "amount": string}
      — the purchased items on a RECEIPT or BILL. For a STATEMENT this MUST be
      an empty array: a statement has no purchased items.
    - transactions: an array of objects
      {"date": string, "amount": string, "name": string, "notes": string|null}
      — the account rows on a STATEMENT only, and EVERY account row belongs here:
      one entry per line of the statement's transaction table, each with its date
      (a statement's rows always carry a date), the name and the amount. Use an
      empty array for anything that is not a statement.
    - field_confidence: an object mapping a field name to a number between 0
      and 1, e.g. {"total": 0.99}.

    Never invent a value. If a field is not present in the document, return
    null for it (or an empty array for line_items and transactions).
  TEXT

  attr_reader :client, :model, :pages, :ocr_text, :custom_provider, :langfuse_trace, :family

  def initialize(client, model:, pages:, ocr_text:, custom_provider: false, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @pages = Array(pages)
    @ocr_text = ocr_text.to_s
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def read
    raw =
      if custom_provider
        read_generic
      else
        read_native
      end

    DocumentUnderstanding.new(raw)
  end

  private
    def read_native
      response = client.responses.create(parameters: {
        model: model,
        instructions: INSTRUCTIONS,
        input: [ { role: "developer", content: native_content_parts } ],
        text: { format: { type: "json_schema", name: "document_understanding",
                          strict: true, schema: json_schema } }
      })

      record_usage(model, response.dig("usage"), operation: "understand_document",
                   metadata: { page_count: pages.size })
      parse_native(response)
    end

    def read_generic
      # The DeepSeek/Ollama path this deployment actually uses. json_object is
      # the broadest compatibility level; on a 400 we retry with none, the
      # same ladder AutoCategorizer documents.
      response = client.chat(parameters: {
        model: model,
        messages: [
          { role: "system", content: INSTRUCTIONS },
          { role: "user", content: generic_content_parts }
        ],
        response_format: { type: "json_object" }
      })

      record_usage(model, response.dig("usage"), operation: "understand_document",
                   metadata: { page_count: pages.size })
      parse_generic(response)
    rescue Faraday::BadRequestError
      response = client.chat(parameters: {
        model: model,
        messages: [
          { role: "system", content: INSTRUCTIONS },
          { role: "user", content: generic_content_parts }
        ]
      })
      parse_generic(response)
    end

    # The multimodal content array, shaped per endpoint: the Responses API
    # (read_native) takes "input_image"/"input_text" parts with a flat image_url
    # string, while chat completions (read_generic) takes "image_url"/"text"
    # parts with a nested image_url object. Both send the images first and the
    # same ocr_block last, so the two paths cannot drift in what they tell the
    # model. (pdf_processor.rb's vision call is the chat-completions shape.)
    def native_content_parts
      pages.map { |base64| { type: "input_image", image_url: image_data_url(base64) } } +
        [ { type: "input_text", text: ocr_block } ]
    end

    def generic_content_parts
      pages.map { |base64| { type: "image_url", image_url: { url: image_data_url(base64) } } } +
        [ { type: "text", text: ocr_block } ]
    end

    def image_data_url(base64) = "data:image/png;base64,#{base64}"

    def ocr_block
      return "OCR text: (none — the OCR engine found no text; rely on the images.)" if ocr_text.blank?

      "OCR text extracted from these same pages:\n\n#{ocr_text}"
    end

    def parse_native(response)
      message = response["output"]&.find { |o| o["type"] == "message" }
      raw = message&.dig("content", 0, "text")
      raise Provider::Openai::Error, "No message content in the understand_document response" if raw.nil?

      JSON.parse(raw)
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in understand_document: #{e.message}"
    end

    def parse_generic(response)
      raw = response.dig("choices", 0, "message", "content")
      JSON.parse(strip_thinking_tags(raw.to_s))
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Could not parse the understand_document reply: #{e.message}"
    end

    # Thinking models emit reasoning before the JSON; keep whatever follows the
    # closing tag (same handling AutoCategorizer uses).
    def strip_thinking_tags(raw)
      return raw unless raw.include?("<think>")
      after = raw[/<\/think>\s*([\s\S]*)/m, 1]
      after.presence || raw
    end

    # Small and flat on purpose — structured-output validity collapses on wide
    # or deeply nested schemas, and a document verdict is easy to over-model.
    def json_schema
      {
        type: "object",
        properties: {
          document_class: { type: "string", enum: DocumentUnderstanding::CLASSES },
          institution_name: { type: [ "string", "null" ] },
          account_last4: { type: [ "string", "null" ] },
          card_last4: { type: [ "string", "null" ] },
          card_network: { type: [ "string", "null" ], enum: Account::CARD_NETWORKS + [ nil ] },
          statement_period: {
            type: [ "object", "null" ],
            properties: { start: { type: [ "string", "null" ] }, end: { type: [ "string", "null" ] } },
            required: [ "start", "end" ],
            additionalProperties: false
          },
          currency: { type: [ "string", "null" ] },
          total: { type: [ "string", "null" ] },
          date: { type: [ "string", "null" ] },
          payee: { type: [ "string", "null" ] },
          line_items: {
            type: "array",
            items: {
              type: "object",
              properties: { description: { type: "string" }, amount: { type: "string" } },
              required: [ "description", "amount" ],
              additionalProperties: false
            }
          },
          transactions: {
            type: "array",
            items: {
              type: "object",
              properties: {
                date: { type: "string" }, amount: { type: "string" },
                name: { type: "string" }, notes: { type: [ "string", "null" ] }
              },
              required: [ "date", "amount", "name" ],
              additionalProperties: false
            }
          },
          field_confidence: { type: "object", additionalProperties: { type: "number" } }
        },
        required: [ "document_class", "line_items", "transactions", "field_confidence" ],
        additionalProperties: false
      }
    end
end
