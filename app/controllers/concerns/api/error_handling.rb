module Api
  # Exception → response mapping for API controllers, in two modes:
  #
  # * Legacy (default) — exactly the pre-existing behaviour of
  #   Api::V1::BaseController: Pundit → 403 and RecordNotFound → 404 in the
  #   legacy ApiResponder envelope. No other handlers are registered, so every
  #   other exception propagates exactly as before.
  #
  # * Standard — opted into per controller with `standard_api_contract!`.
  #   Every error, including unexpected ones, is rendered in the standard error
  #   envelope (Api::StandardResponses) with a stable `error.code`. Internal
  #   exception details are never rendered; they are reported via Rails.error.
  #
  # Existing endpoints stay legacy until their characterization specs prove a
  # migration is safe (docs/api/conventions.md → "Migrating an endpoint").
  module ErrorHandling
    extend ActiveSupport::Concern

    CONFLICT_ERRORS = [
      ActiveRecord::StaleObjectError,
      ActiveRecord::LockWaitTimeout,
      ActiveRecord::Deadlocked,
      ActiveRecord::RecordNotUnique
    ].freeze

    BAD_REQUEST_ERRORS = [
      ActionController::ParameterMissing,
      ActionDispatch::Http::Parameters::ParseError,
      Api::Errors::BadRequest
    ].freeze

    included do
      class_attribute :standard_api_contract, default: false, instance_writer: false

      rescue_from ActiveRecord::RecordNotFound, with: :handle_record_not_found
      rescue_from Pundit::NotAuthorizedError,   with: :handle_not_authorized
    end

    class_methods do
      # Opt a controller into the standard response/error contract.
      #
      # rescue_from handlers are matched last-declared-first, so the catch-all
      # is declared first and the specific handlers (including the two legacy
      # ones, re-declared) after it.
      def standard_api_contract!
        self.standard_api_contract = true

        rescue_from StandardError,              with: :handle_unexpected_error
        rescue_from(*CONFLICT_ERRORS,           with: :handle_conflict)
        rescue_from ActiveRecord::RecordInvalid, with: :handle_record_invalid
        rescue_from(*BAD_REQUEST_ERRORS,        with: :handle_bad_request)
        rescue_from ActiveRecord::RecordNotFound, with: :handle_record_not_found
        rescue_from Pundit::NotAuthorizedError,   with: :handle_not_authorized
      end
    end

    # Devise's authenticate_user! answers unauthenticated requests through its
    # failure app ({"error": "…"}). Standard-contract controllers answer in the
    # standard envelope instead; legacy controllers keep Devise's response.
    def authenticate_user!(*args)
      return super unless standard_api_contract?
      return if user_signed_in?

      render_api_error(:unauthenticated)
    end

    private

    def handle_not_authorized(_exception)
      return render_error("Forbidden", status: :forbidden) unless standard_api_contract?

      render_api_error(:forbidden)
    end

    def handle_record_not_found(_exception)
      return render_not_found unless standard_api_contract?

      render_api_error(:not_found)
    end

    def handle_bad_request(exception)
      details = exception.respond_to?(:details) ? exception.details : []
      message = exception.is_a?(Api::Errors::BadRequest) ? exception.message : nil
      render_api_error(:bad_request, message: message, details: details)
    end

    def handle_record_invalid(exception)
      render_validation_errors(exception.record)
    end

    def handle_conflict(exception)
      Rails.error.report(exception, handled: true, severity: :warning, context: api_error_context)
      render_api_error(:conflict)
    end

    def handle_unexpected_error(exception)
      Rails.error.report(exception, handled: true, context: api_error_context)
      Rails.logger.error("[API] unexpected #{exception.class} request_id=#{request.request_id}")
      render_api_error(:internal_error)
    end

    def api_error_context
      { request_id: request.request_id, controller: controller_path, action: action_name }
    end
  end
end
