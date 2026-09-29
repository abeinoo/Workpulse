module EmployeeDataRequests
  # The submitting manager corrects a request the reviewer sent back
  # (changes_requested) and resubmits it. Appends a NEW immutable revision —
  # the previous submission is never modified — and returns the request to
  # pending_review with a "resubmitted" history event.
  #
  # ID photos not re-uploaded carry over from the previous revision (same blob).
  class Resubmitter
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(request_id:, actor:, params:)
      @request_id = request_id
      @actor      = actor
      @params     = params.to_h.symbolize_keys.slice(*Submitter::PERMITTED)
    end

    def call
      request  = EmployeeDataRequest.where(business_id: @actor.business_id).find(@request_id)
      revision = nil

      request.with_lock do
        return error(request, "not_awaiting_changes") unless request.changes_requested?
        return error(request, "not_submitter") unless request.submitted_by_id == @actor.id

        previous = request.revisions.reorder(revision_number: :desc).first
        uploads  = @params.extract!(:id_front, :id_back).compact_blank
        revision = request.revisions.build(@params.merge(revision_number: previous.revision_number + 1,
                                                         submitted_by: @actor))
        revision.id_front.attach(uploads[:id_front] || previous.id_front.blob)
        revision.id_back.attach(uploads[:id_back] || previous.id_back.blob)
        return Result.new(ok: false, record: revision) unless revision.valid?

        DuplicateGuard.lock!(business_id: @actor.business_id, national_id: revision.national_id)
        if (conflict = DuplicateGuard.conflict_for(business_id: @actor.business_id,
                                                  national_id: revision.national_id,
                                                  exclude_request_id: request.id))
          revision.errors.add(:national_id, I18n.t(conflict))
          return Result.new(ok: false, record: revision)
        end

        revision.save!
        request.update!(status: "pending_review")
        request.events.create!(actor: @actor, action: "resubmitted", revision: revision)
        log_audit(actor: @actor, auditable: request, action: "employee_data_request.resubmitted",
                  metadata: { revision_number: revision.revision_number,
                              changed_fields: revision.changed_fields_since(previous).map(&:to_s) })
      end

      Result.new(ok: true, record: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, record: revision, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def error(request, key)
      Result.new(ok: false, record: request, error: I18n.t("employee_data_requests.errors.#{key}"))
    end
  end
end
