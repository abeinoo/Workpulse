module Inventory
  # Assigns or changes the responsible employee ("الموظف المسؤول عن الشراء") of an
  # approved / receivable Purchase Request — the way a legacy request gets one
  # (never automatically). A draft changes it through PurchaseRequestUpdater.
  #
  # Rules, re-checked under the request row lock (the same lock the advance
  # recorder and workflow take, so an advance can't slip in between):
  #   - the request must be receivable (approved / partially received);
  #   - no funding advance may be pending or confirmed (unreversed) — they name
  #     the current employee's custody (PurchaseRequest#responsible_employee_locked?);
  #   - the employee must be eligible: purchasing permission + active custody
  #     account, decided by Finance & Sales through
  #     Inventory::PurchaseRequestAdvanceEffects.responsible_custody_account_id.
  # Audited with the old and new employee.
  class PurchaseRequestResponsibleAssigner
    include AuditLoggable

    Result = Struct.new(:ok, :purchase_request, :error, keyword_init: true) { def ok? = ok }

    def initialize(purchase_request_id, actor:, responsible_employee_id:)
      @purchase_request_id     = purchase_request_id
      @actor                   = actor
      @responsible_employee_id = responsible_employee_id.presence&.to_i
    end

    def call
      return error(:responsible_employee_required) if @responsible_employee_id.nil?

      request.with_lock do
        return error(:responsible_employee_not_assignable) unless request.receivable?
        return Result.new(ok: true, purchase_request: request) if request.responsible_employee_id == @responsible_employee_id
        return error(:responsible_employee_locked) if request.responsible_employee_locked?
        return error(:responsible_employee_ineligible) unless eligible?

        previous = request.responsible_employee_id
        request.update!(responsible_employee_id: @responsible_employee_id)
        log_audit(actor: @actor, auditable: request, action: "assign_responsible_employee",
                  changes: { responsible_employee_id: [ previous, @responsible_employee_id ] },
                  metadata: { request_number: request.request_number })
      end

      Result.new(ok: true, purchase_request: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, purchase_request: request, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def request
      @request ||= PurchaseRequestPolicy::Scope.new(@actor, PurchaseRequest).resolve.find(@purchase_request_id) # warehouse reach, as PurchaseRequestApproval (Phase 2)
    end

    def eligible?
      Inventory::PurchaseRequestAdvanceEffects.responsible_custody_account_id(
        business_id: request.business_id, user_id: @responsible_employee_id
      ).present?
    end

    def error(key)
      Result.new(ok: false, purchase_request: request,
                 error: I18n.t("inventory.purchase_requests.errors.#{key}"))
    end
  end
end
