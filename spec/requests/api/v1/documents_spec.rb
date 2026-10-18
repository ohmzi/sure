# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Documents', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Read Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:file) do
    Rack::Test::UploadedFile.new(
      StringIO.new("\x89PNG\r\n\x1a\n".b),
      'image/png',
      original_filename: 'receipt.png'
    )
  end

  path '/api/v1/documents' do
    post 'Upload a document' do
      description 'Archive a photo or PDF through the same intake pipeline as the web dropzone. ' \
                  'The document is queued for reading and the response returns its id and status. ' \
                  'Bank exports (CSV/OFX) are refused here; use the imports API. Maximum size is 25MB.'
      tags 'Documents'
      security [ { apiKeyAuth: [] } ]
      consumes 'multipart/form-data'
      produces 'application/json'

      parameter name: :file, in: :formData, required: true,
                description: 'Photo or PDF (PNG, JPEG, WebP, HEIC/HEIF, or any file whose bytes start with %PDF-). Maximum 25MB.',
                schema: {
                  type: :object,
                  required: [ 'file' ],
                  properties: {
                    file: { type: :string, format: :binary },
                    currency: {
                      type: :string,
                      description: 'Optional ISO 4217 currency for a receipt or bill. Ignored when not a real code.'
                    }
                  }
                }

      response '202', 'document accepted for reading' do
        schema '$ref' => '#/components/schemas/DocumentUploadResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope or guest user' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '422', 'missing or unrecognised file' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:file) do
          Rack::Test::UploadedFile.new(
            StringIO.new("\x00\x01".b),
            'application/octet-stream',
            original_filename: 'thing.bin'
          )
        end

        run_test!
      end

      response '413', 'file larger than the 25MB cap' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:file) do
          Rack::Test::UploadedFile.new(
            StringIO.new('x' * (DocumentLink::Staging::MAX_BYTES + 1)),
            'image/png',
            original_filename: 'huge.png'
          )
        end

        run_test!
      end
    end
  end
end
