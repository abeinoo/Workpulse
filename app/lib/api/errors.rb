module Api
  # Error catalogue for the standard API contract (see docs/api/conventions.md).
  #
  # Every standard error response carries one of these codes. The HTTP status is
  # derived from the code so the two can never disagree. Messages are localized
  # under `api.errors.<code>` (en + ar).
  module Errors
    STATUS_BY_CODE = {
      bad_request:             :bad_request,           # 400
      unauthenticated:         :unauthorized,          # 401
      forbidden:               :forbidden,             # 403
      not_found:               :not_found,             # 404
      conflict:                :conflict,              # 409
      validation_failed:       :unprocessable_content, # 422
      business_rule_violation: :unprocessable_content, # 422
      rate_limited:            :too_many_requests,     # 429
      internal_error:          :internal_server_error  # 500
    }.freeze

    CODES = STATUS_BY_CODE.keys.freeze

    # Raised by API-layer helpers (pagination, filtering, sorting) when a client
    # sends a malformed or non-allowlisted parameter. Never raised by services.
    class BadRequest < StandardError
      attr_reader :details

      def initialize(message = nil, details: [])
        @details = details
        super(message)
      end
    end
  end
end
