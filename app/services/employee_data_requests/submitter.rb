module EmployeeDataRequests
  # A manager submits a new employee's basic personal data + ID photos for
  # review ("طلب إضافة موظف"). Creates the request (pending_review), its first
  # immutable revision, and the "submitted" history event.
  #
  # Only personal data is accepted: nothing about branch, salary, role, shifts
  # or payroll — and nothing is inferred from the submitting manager. No
  # employee record is touched until a reviewer approves.
  class Submitter
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    PERMITTED = (EmployeeDataRequestRevision::DATA_FIELDS + %i[manager_notes id_front id_back]).freeze

    def initialize(actor:, params:)
      @actor  = actor
      @params = params.to_h.symbolize_keys.slice(*PERMITTED)
    end

    def call
      request  = EmployeeDataRequest.new(business_id: @actor.business_id, submitted_by: @actor,
                                         status: "pending_review")
      revision = request.revisions.build(@params.merge(revision_number: 1, submitted_by: @actor))
      return Result.new(ok: false, record: revision) unless revision.valid?

      ActiveRecord::Base.transaction do
        DuplicateGuard.lock!(business_id: @actor.business_id, national_id: revision.national_id)
        if (conflict = DuplicateGuard.conflict_for(business_id: @actor.business_id,
                                                  national_id: revision.national_id))
          revision.errors.add(:national_id, I18n.t(conflict))
          raise ActiveRecord::Rollback
        end

        request.save!
        request.events.create!(actor: @actor, action: "submitted", revision: revision)
        log_audit(actor: @actor, auditable: request, action: "employee_data_request.submitted",
                  metadata: { revision_number: revision.revision_number,
                              manager_notes_present: revision.manager_notes.present? })
      end

      return Result.new(ok: false, record: revision) unless request.persisted?

      Result.new(ok: true, record: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, record: revision, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
