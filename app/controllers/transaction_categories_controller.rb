class TransactionCategoriesController < ApplicationController
  include ActionView::RecordIdentifier

  def update
    @entry = Current.accessible_entries.transactions.find(params[:transaction_id])
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))
    # The inflow leg of a matched transfer shows its outflow's category
    # read-only (Transaction#category_set_on_transfer_outflow?).
    return head(:unprocessable_entity) if @entry.transaction.category_set_on_transfer_outflow?

    @entry.update!(entry_params)

    transaction = @entry.transaction

    transaction.record_category_usage!

    if needs_rule_notification?(transaction)
      flash[:cta] = category_rule_cta(transaction)
    end

    transaction.lock_saved_attributes!
    @entry.lock_saved_attributes!

    in_split_group = helpers.in_split_group?(@entry, params[:grouped])
    respond_to do |format|
      format.html { redirect_back_or_to transaction_path(@entry) }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            dom_id(transaction, "category_menu_mobile"),
            partial: "transactions/transaction_category",
            locals: { transaction: transaction, variant: "mobile", in_split_group: in_split_group }
          ),
          turbo_stream.replace(
            dom_id(transaction, "category_menu_desktop"),
            partial: "transactions/transaction_category",
            locals: { transaction: transaction, variant: "desktop", in_split_group: in_split_group }
          ),
          turbo_stream.replace(
            "category_name_mobile_#{transaction.id}",
            partial: "categories/category_name_mobile",
            locals: { transaction: transaction }
          ),
          *flash_notification_stream_items
        ]
      end
    end
  end

  # Apply the category the user just chose to the other uncategorized rows
  # that share this transaction's merchant/name and direction. The rule prompt
  # then comes back with the "create a rule" offer still attached, so a
  # one-off fix can become the future rule in the same breath.
  def apply_to_similar
    @entry = Current.accessible_entries.transactions.find(params[:id])
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    transaction = @entry.transaction
    if transaction.category_id.blank?
      redirect_back_or_to transaction_path(@entry), alert: t(".no_category")
      return
    end

    entries = transaction.similar_uncategorized_entries(Current.accessible_entries)
    count = Current.accessible_entries.where(id: entries.map(&:id)).bulk_update!({ category_id: transaction.category_id })

    flash[:cta] = category_rule_cta(transaction) if category_rule_prompt_allowed?(transaction)
    redirect_back_or_to transaction_path(@entry), notice: t(".applied", count: count)
  end

  private
    def entry_params
      params.require(:entry).permit(:entryable_type, entryable_attributes: [ :id, :category_id ])
    end

    def category_rule_cta(transaction)
      {
        type: "category_rule",
        transaction_id: @entry.id,
        category_id: transaction.category_id,
        category_name: transaction.category.name,
        merchant_name: @entry.name,
        similar_count: transaction.similar_uncategorized_entries(Current.accessible_entries).size
      }
    end

    def needs_rule_notification?(transaction)
      transaction.saved_change_to_category_id? && category_rule_prompt_allowed?(transaction)
    end

    def category_rule_prompt_allowed?(transaction)
      return false if Current.user.rule_prompts_disabled
      return false if transaction.category_id.blank?

      if Current.user.rule_prompt_dismissed_at.present?
        time_since_last_rule_prompt = Time.current - Current.user.rule_prompt_dismissed_at
        return false if time_since_last_rule_prompt < 1.day
      end

      transaction.eligible_for_category_rule?
    end
end
