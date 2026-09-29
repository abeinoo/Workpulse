module EmployeeDataRequests
  # Reviewer actions on a pending employee data request:
  #
  #   correct          — the reviewer fixes submitted values before deciding.
  #                      Appends a reviewer_correction revision (the manager's
  #                      submission is never modified) + a "corrected" event,
  #                      and audits every field as [submitted, corrected].
  #   approve          — optionally applies corrections first (same
  #                      transaction), then creates the employee from the
  #                      APPROVED values via EmployeeAttributes (name, national
  #                      ID + expiry, phone, address, date of birth, job title,
  #                      hire date, emergency contact) and copies the ID photos
  #                      onto the employee's national_id_front / _back. No
  #                      branch, salary, role/permissions, shift, commission or
  #                      payroll configuration is created — manager notes (even
  #                      ones mentioning salary) are never parsed.
  #   reject           — terminal; reason required.
  #   request_changes  — back to the submitting manager; note required.
  #
  # Every action appends a history event and an audit log entry.
  class Reviewer
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def self.correct(request_id:, actor:, corrections:)
      new(request_id: request_id, actor: actor, corrections: corrections).correct
    end

    def self.approve(request_id:, actor:, note: nil, corrections: nil)
      new(request_id: request_id, actor: actor, note: note, corrections: corrections).approve
    end

    def self.reject(request_id:, actor:, note:)
      new(request_id: request_id, actor: actor, note: note).decide("rejected", "rejected")
    end

    def self.request_changes(request_id:, actor:, note:)
      new(request_id: request_id, actor: actor, note: note).decide("changes_requested", "changes_requested")
    end

    def initialize(request_id:, actor:, note: nil, corrections: nil)
      @request_id  = request_id
      @actor       = actor
      @note        = note.to_s.strip.presence
      @corrections = corrections&.to_h&.symbolize_keys&.slice(*EmployeeDataRequestRevision::DATA_FIELDS)
    end

    def correct
      request = load_request
      request.with_lock do
        return not_pending(request) unless request.pending_review?

        revision = apply_corrections!(request)
        return revision if revision.is_a?(Result)
      end
      Result.new(ok: true, record: request)
    end

    def approve
      request = load_request
      request.with_lock do
        return not_pending(request) unless request.pending_review?

        corrected = apply_corrections!(request)
        return corrected if corrected.is_a?(Result)

        revision = latest_revision(request)
        # Re-check the version being approved against the current rules (e.g.
        # a request submitted before hire date / ID expiry became required).
        return Result.new(ok: false, record: revision) unless revision.valid?

        if (conflict = identity_conflict(revision))
          raise_rollback_with(request, I18n.t("employee_data_requests.errors.#{conflict}"))
        end

        employee = build_employee(request, revision)
        employee.save!

        request.update!(status: "approved", reviewed_by: @actor, reviewed_at: Time.current, employee: employee)
        request.events.create!(actor: @actor, action: "approved", revision: revision, note: @note)
        log_audit(actor: @actor, auditable: request, action: "employee_data_request.approved",
                  metadata: { revision_number: revision.revision_number, employee_id: employee.id })
        log_audit(actor: @actor, auditable: employee, action: "employee.created_from_data_request",
                  metadata: { employee_data_request_id: request.id, revision_number: revision.revision_number })
      end
      Result.new(ok: true, record: request)
    rescue RollbackWithError => e
      Result.new(ok: false, record: e.request, error: e.message)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, record: request,
                 error: I18n.t("employee_data_requests.errors.employee_invalid",
                               errors: e.record.errors.full_messages.to_sentence))
    end

    def decide(status, action)
      request = load_request
      return Result.new(ok: false, record: request, error: I18n.t("employee_data_requests.errors.note_required")) unless @note

      request.with_lock do
        return not_pending(request) unless request.pending_review?

        revision = latest_revision(request)
        request.update!(status: status, reviewed_by: @actor, reviewed_at: Time.current)
        request.events.create!(actor: @actor, action: action, revision: revision, note: @note)
        log_audit(actor: @actor, auditable: request, action: "employee_data_request.#{action}",
                  metadata: { revision_number: revision.revision_number, note: @note })
      end
      Result.new(ok: true, record: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, record: request, error: e.record.errors.full_messages.to_sentence)
    end

    private

    # Raised to roll back a transaction that already wrote corrections when the
    # approval itself then can't proceed — approve is all-or-nothing.
    class RollbackWithError < StandardError
      attr_reader :request

      def initialize(request, message)
        @request = request
        super(message)
      end
    end

    def raise_rollback_with(request, message)
      raise RollbackWithError.new(request, message)
    end

    def load_request
      EmployeeDataRequest.where(business_id: @actor.business_id).find(@request_id)
    end

    def latest_revision(request)
      request.revisions.reorder(revision_number: :desc).first
    end

    def not_pending(request)
      Result.new(ok: false, record: request, error: I18n.t("employee_data_requests.errors.not_pending"))
    end

    # Appends a reviewer_correction revision when any submitted value changed.
    # Returns the new revision, nil when nothing changed, or a failed Result
    # (record = the invalid revision, for re-rendering the review form).
    def apply_corrections!(request)
      return nil if @corrections.blank?

      previous = latest_revision(request)
      revision = request.revisions.build(
        previous.data_attributes.merge(@corrections).merge(
          revision_number: previous.revision_number + 1, submitted_by: @actor,
          source: "reviewer_correction", manager_notes: previous.manager_notes
        )
      )
      revision.id_front.attach(previous.id_front.blob)
      revision.id_back.attach(previous.id_back.blob)

      unless revision.valid?
        request.revisions.delete(revision)
        return Result.new(ok: false, record: revision)
      end

      changed = revision.changed_data_fields_since(previous)
      if changed.empty?
        request.revisions.delete(revision)
        return nil
      end

      if revision.national_id != previous.national_id
        DuplicateGuard.lock!(business_id: request.business_id, national_id: revision.national_id)
        if (conflict = DuplicateGuard.conflict_for(business_id: request.business_id,
                                                  national_id: revision.national_id,
                                                  exclude_request_id: request.id))
          revision.errors.add(:national_id, I18n.t(conflict))
          request.revisions.delete(revision)
          return Result.new(ok: false, record: revision)
        end
      end

      revision.save!
      request.touch
      request.events.create!(actor: @actor, action: "corrected", revision: revision)
      log_audit(actor: @actor, auditable: request, action: "employee_data_request.corrected",
                changes: changed.to_h { |f| [ f, [ previous.public_send(f), revision.public_send(f) ] ] },
                metadata: { revision_number: revision.revision_number, changed_fields: changed.map(&:to_s) })
      revision
    end

    # Phone and national ID are unique across all users; report a clash clearly
    # instead of a raw validation message.
    def identity_conflict(revision)
      return "national_id_taken" if User.where(identity_card_number: revision.national_id).exists?

      "phone_taken" if User.where(phone_number: revision.phone_number).exists?
    end

    # Approved basic data only — EmployeeAttributes is the explicit whitelist,
    # the guarantee that no employment configuration leaks in from the request.
    def build_employee(request, revision)
      employee = EmployeeAttributes.build_user(revision, business_id: request.business_id)
      # Independent copies, not shared blobs: the employee's documents follow
      # the employee's lifecycle (an admin may replace/purge them) while the
      # request history keeps the originals exactly as submitted.
      copy_document(revision.id_front, employee.national_id_front)
      copy_document(revision.id_back,  employee.national_id_back)
      employee
    end

    def copy_document(source, target)
      blob = source.blob
      target.attach(io: StringIO.new(blob.download), filename: blob.filename.to_s,
                    content_type: blob.content_type, identify: false)
    end
  end
end
