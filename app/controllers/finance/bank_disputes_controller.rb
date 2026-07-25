class Finance::BankDisputesController < Finance::BaseController
  before_action :set_dispute, only: %i[show submit_to_bank start_investigation refund confirm_successful reject
                                        close update_case confirm_deposit]

  # GET /finance/bank_disputes/new?till_deposit_id=:id
  # GET /finance/bank_disputes/new?daily_reconciliation_id=:id  (Report ATM Deposit Problem)
  def new
    if params[:till_deposit_id].present?
      @deposit = policy_scope(TillDeposit).find(params[:till_deposit_id])
      @dispute = BankDispute.new(till_deposit: @deposit)
    else
      @reconciliation = policy_scope(DailyReconciliation).find(params[:daily_reconciliation_id])
      @dispute = BankDispute.new(daily_reconciliation: @reconciliation, kind: "atm_deposit_failure")
    end
    authorize @dispute
  end

  # POST /finance/bank_disputes
  def create
    if dispute_params[:till_deposit_id].present?
      @deposit = policy_scope(TillDeposit).find(dispute_params[:till_deposit_id])
      @dispute = BankDispute.new(till_deposit: @deposit)
    else
      @reconciliation = policy_scope(DailyReconciliation).find(dispute_params[:daily_reconciliation_id])
      @dispute = BankDispute.new(daily_reconciliation: @reconciliation, kind: "atm_deposit_failure")
    end
    authorize @dispute

    result = Finance::BankDisputes::Creator.new(
      actor:                   current_user,
      till_deposit_id:         dispute_params[:till_deposit_id].presence,
      daily_reconciliation_id: dispute_params[:daily_reconciliation_id].presence,
      params:                  dispute_params.except(:till_deposit_id, :daily_reconciliation_id).to_h.symbolize_keys
    ).call

    if result.ok?
      redirect_to finance_bank_dispute_path(result.dispute), notice: t("finance.bank_disputes.created")
    else
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  # GET /finance/bank_disputes/:id
  def show
    authorize @dispute
    @audit_logs = AuditLog.for_auditable(@dispute).includes(:actor).recent
  end

  # PATCH /finance/bank_disputes/:id/submit_to_bank
  def submit_to_bank
    transition("submitted_to_bank", params.permit(:bank_ticket_number, :notes))
  end

  # PATCH /finance/bank_disputes/:id/start_investigation
  def start_investigation
    transition("under_investigation", params.permit(:notes))
  end

  # PATCH /finance/bank_disputes/:id/refund
  def refund
    transition("refunded", params.permit(:notes))
  end

  # PATCH /finance/bank_disputes/:id/confirm_successful
  def confirm_successful
    transition("confirmed_successful", params.permit(:notes))
  end

  # PATCH /finance/bank_disputes/:id/reject
  def reject
    transition("rejected", params.permit(:notes))
  end

  # PATCH /finance/bank_disputes/:id/close
  def close
    transition("closed", params.permit(:notes))
  end

  # PATCH /finance/bank_disputes/:id/update_case
  def update_case
    authorize @dispute, :update_case?

    result = Finance::BankDisputes::CaseUpdater.new(
      @dispute.id,
      actor:               current_user,
      bank_ticket_number:  params[:bank_ticket_number],
      case_note:           params[:case_note],
      case_note_category:  params[:case_note_category],
      photos:              Array(params[:photos])
    ).call

    if result.ok?
      redirect_to finance_bank_dispute_path(@dispute), notice: t("finance.bank_disputes.case_updated")
    else
      flash.now[:alert] = result.error
      @audit_logs = AuditLog.for_auditable(@dispute).includes(:actor).recent
      render :show, status: :unprocessable_entity
    end
  end

  # PATCH /finance/bank_disputes/:id/confirm_deposit
  def confirm_deposit
    authorize @dispute, :confirm_deposit?

    result = Finance::BankDisputes::DepositConfirmer.new(
      @dispute.id,
      actor:              current_user,
      payment_method_id:  params[:payment_method_id],
      amount:             params[:amount]
    ).call

    if result.ok?
      redirect_to finance_bank_dispute_path(@dispute), notice: t("finance.bank_disputes.deposit_confirmed")
    else
      flash.now[:alert] = result.error
      @audit_logs = AuditLog.for_auditable(@dispute).includes(:actor).recent
      render :show, status: :unprocessable_entity
    end
  end

  private

  def transition(target_status, permitted_params)
    authorize @dispute, "#{policy_action_for(target_status)}?"

    result = Finance::BankDisputes::StatusTransitioner.new(
      @dispute.id,
      actor:         current_user,
      target_status: target_status,
      params:        permitted_params.to_h.symbolize_keys
    ).call

    if result.ok?
      redirect_to finance_bank_dispute_path(@dispute),
                  notice: t("finance.bank_disputes.transitioned.#{target_status}")
    else
      flash.now[:alert] = result.error
      @audit_logs = AuditLog.for_auditable(@dispute).includes(:actor).recent
      render :show, status: :unprocessable_entity
    end
  end

  def policy_action_for(target_status)
    {
      "submitted_to_bank"    => "submit_to_bank",
      "under_investigation"  => "start_investigation",
      "refunded"             => "refund",
      "confirmed_successful" => "confirm_successful",
      "rejected"             => "reject",
      "closed"               => "close"
    }.fetch(target_status)
  end

  def set_dispute
    @dispute = policy_scope(BankDispute)
                 .includes(till_deposit: { daily_reconciliation: :branch },
                           daily_reconciliation: :branch, opened_by: [])
                 .find(params[:id])
  end

  def dispute_params
    params.require(:bank_dispute).permit(
      :till_deposit_id, :daily_reconciliation_id, :transaction_date, :transaction_time, :amount, :bank_name,
      :terminal_id, :merchant_id, :card_last4, :reference_number, :stan,
      :authorization_code, :bank_ticket_number, :atm_location, :notes, photos: []
    )
  end
end
