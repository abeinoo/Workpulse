module EmployeeDataRequests
  # Service-level duplicate prevention for employee data requests: a national
  # ID may not be submitted while another open (pending / needs-changes) request
  # for the same national ID exists. (An existing employee with that national ID
  # is caught by the User model's own uniqueness rule — see
  # EmployeeDataRequestRevision#valid_as_employee.)
  #
  # Callers must run inside a transaction: #lock! takes a transaction-scoped
  # advisory lock keyed by business + national ID, so two concurrent
  # submissions for the same person serialize and the second sees the first.
  module DuplicateGuard
    LOCK_NAMESPACE = 0x4544 # "ED" — distinct from User's employee_code lock

    module_function

    def lock!(business_id:, national_id:)
      conn = ActiveRecord::Base.connection
      key  = conn.quote("#{business_id}:#{national_id}")
      conn.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, hashtext(#{key}))")
    end

    # Returns an i18n error key, or nil when the national ID is free.
    def conflict_for(business_id:, national_id:, exclude_request_id: nil)
      return nil if national_id.blank?

      open_ids = EmployeeDataRequest.where(business_id: business_id).open_requests
      open_ids = open_ids.where.not(id: exclude_request_id) if exclude_request_id
      # Match against each open request's LATEST revision only.
      latest = EmployeeDataRequestRevision
                 .where(employee_data_request_id: open_ids.select(:id))
                 .where(revision_number: EmployeeDataRequestRevision
                          .where("r2.employee_data_request_id = employee_data_request_revisions.employee_data_request_id")
                          .from("employee_data_request_revisions r2")
                          .select("MAX(r2.revision_number)"))
      "employee_data_requests.errors.open_request_exists" if latest.where(national_id: national_id).exists?
    end
  end
end
