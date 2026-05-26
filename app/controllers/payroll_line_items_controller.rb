class PayrollLineItemsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_context

  def approve
    authorize @line_item, :approve?

    result = Payroll::LineItemReviewer.call(
      line_item:   @line_item,
      action:      "approve",
      reviewed_by: current_user,
      notes:       params[:notes]
    )

    if result.success?
      redirect_to payroll_period_payroll_entry_path(@period, @entry),
                  notice: t("flash.deduction_approved")
    else
      redirect_to payroll_period_payroll_entry_path(@period, @entry),
                  alert: result.error
    end
  end

  def reject
    authorize @line_item, :reject?

    result = Payroll::LineItemReviewer.call(
      line_item:   @line_item,
      action:      "reject",
      reviewed_by: current_user,
      notes:       params[:notes]
    )

    if result.success?
      redirect_to payroll_period_payroll_entry_path(@period, @entry),
                  notice: t("flash.deduction_rejected")
    else
      redirect_to payroll_period_payroll_entry_path(@period, @entry),
                  alert: result.error
    end
  end

  def waive
    authorize @line_item, :waive?

    result = Payroll::LineItemReviewer.call(
      line_item:   @line_item,
      action:      "waive",
      reviewed_by: current_user,
      notes:       params[:notes]
    )

    if result.success?
      redirect_to payroll_period_payroll_entry_path(@period, @entry),
                  notice: t("flash.deduction_waived")
    else
      redirect_to payroll_period_payroll_entry_path(@period, @entry),
                  alert: result.error
    end
  end

  private

  def set_context
    @period    = policy_scope(PayrollPeriod).find(params[:payroll_period_id])
    @entry     = policy_scope(PayrollEntry)
                   .where(payroll_period: @period)
                   .find(params[:payroll_entry_id])
    @line_item = policy_scope(PayrollLineItem)
                   .joins(:payroll_entry)
                   .where(payroll_entries: { id: @entry.id })
                   .find(params[:id])
  end
end
