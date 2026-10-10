# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Envelopes', type: :request do
  let(:family) { Family.create!(name: 'API Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y') }
  let(:user) { family.users.create!(email: 'api-user@example.com', password: 'password123', password_confirmation: 'password123') }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: 'API Docs Key', key: key, display_key: key,
                   scopes: %w[read_write], source: 'web')
  end
  let(:'X-Api-Key') { api_key.plain_key }

  let!(:category) { family.categories.create!(name: 'Groceries', color: '#22c55e') }
  let!(:budget) do
    family.budgets.create!(start_date: 5.months.ago.beginning_of_month,
                           end_date: 5.months.ago.end_of_month,
                           budgeted_spending: 3000, expected_income: 5000, currency: 'USD')
  end
  let!(:budget_category) do
    budget.budget_categories.create!(category: category, budgeted_spending: 500, currency: 'USD')
  end

  path '/api/v1/envelopes' do
    get 'List envelopes' do
      tags 'Envelopes'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'envelopes listed' do
        schema '$ref' => '#/components/schemas/EnvelopeCollection'
        run_test!
      end
      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        run_test!
      end
    end
  end

  path '/api/v1/envelopes/{id}' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }

    get 'Retrieve an envelope' do
      tags 'Envelopes'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      let(:id) { budget_category.id }
      response '200', 'envelope retrieved' do
        schema '$ref' => '#/components/schemas/Envelope'
        run_test!
      end
      response '404', 'envelope not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end

    patch 'Update an envelope' do
      tags 'Envelopes'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      # The body wraps the payload under :envelope — the controller does
      # params.require(:envelope); mirrors transactions_spec.rb:305,331-338
      # (Ruling P-m4a-2, 2026-10-10 pre-flight).
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          envelope: {
            type: :object,
            properties: { budgeted_spending: { type: :string } }
          }
        }
      }
      let(:id) { budget_category.id }
      let(:body) { { envelope: { budgeted_spending: "450" } } }
      response '200', 'envelope updated' do
        schema '$ref' => '#/components/schemas/Envelope'
        run_test!
      end
    end

    delete 'Delete an envelope' do
      tags 'Envelopes'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      let(:id) { budget_category.id }
      response '200', 'envelope deleted' do
        # Ruling M4a-L3: the controller renders { message: ... } with 200 —
        # ErrorResponse was the wrong $ref (only a real request run catches it).
        schema '$ref' => '#/components/schemas/DeleteResponse'
        run_test!
      end
    end
  end
end
