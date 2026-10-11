# frozen_string_literal: true

# A receipt draft's editable details: the manual total/date/payee (the
# needs_understanding fix path) and the one-tap receipt<->bill override (locked
# decision 12). Publishing is NOT here — it stays imports#publish, the reviewed
# D8 gate.
class ReceiptImportsController < ApplicationController
  before_action :set_receipt_import
  before_action :require_non_guest!

  def update
    return redirect_to import_path(@receipt_import), alert: t(".locked") if @receipt_import.complete?

    source = params.dig(:receipt_import, :source).presence
    if source.present?
      return redirect_to import_path(@receipt_import), alert: t(".invalid_source") unless source.in?(%w[receipt bill])

      @receipt_import.document_link.update!(source: source)
    end

    if details_params.values.any?(&:present?)
      saved = @receipt_import.apply_manual_details!(
        total: details_params[:total_amount], date: details_params[:purchase_date], payee: details_params[:payee]
      )
      return redirect_to import_path(@receipt_import), alert: t(".invalid_details") unless saved
    end

    redirect_to import_path(@receipt_import), notice: t(".saved")
  end

  private
    def set_receipt_import
      @receipt_import = Current.family.imports.find(params[:id])
      raise ActiveRecord::RecordNotFound unless @receipt_import.is_a?(ReceiptImport)
    end

    def details_params
      params.fetch(:receipt_import, {}).permit(:total_amount, :purchase_date, :payee)
    end
end
