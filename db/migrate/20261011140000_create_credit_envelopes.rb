# frozen_string_literal: true

# Per-(budget month, credit-card account) payment-envelope materialization.
#
# Every credit card gets a YNAB-style payment envelope: as card spending that a
# spending envelope can cover is budgeted, that money is moved onto the card's
# payment envelope; as cc_payment transfers pay the card down, the envelope
# falls. funded_amount and payment_amount are cumulative through the budget
# month (a forward pass, like budget_categories.rolled_over_amount), recomputed
# by Budget::CreditEnvelopeCalculator and never written by the entry path.
#
# Additive only: a new table, no existing column read or altered. The foreign
# keys cascade so deleting a budget or an account takes its derived rows with
# it without a model-level dependent: on Account or Budget.
class CreateCreditEnvelopes < ActiveRecord::Migration[8.1]
  def change
    create_table :credit_envelopes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :budget, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.decimal :funded_amount, precision: 19, scale: 4, null: false, default: "0.0"
      t.decimal :payment_amount, precision: 19, scale: 4, null: false, default: "0.0"
      t.string :currency, null: false
      t.timestamps
    end

    # The upsert's conflict target, and the row's identity.
    add_index :credit_envelopes, %i[budget_id account_id], unique: true
  end
end
