module Api
  # Standard API response envelope (see docs/api/conventions.md).
  #
  #   success: { success: true,  data: …, meta: {…}, request_id: "…" }
  #   error:   { success: false, error: { code:, message:, details: [] },
  #              request_id: "…", message: "…", errors: […] }
  #
  # The top-level `message` / `errors` keys on errors mirror the legacy
  # ApiResponder shape, so an endpoint migrated to this contract stays readable
  # by clients written against the legacy envelope. They are deprecated and
  # will be dropped only in a future API version.
  #
  # Pure rendering helpers — no business decisions live here.
  module StandardResponses
    extend ActiveSupport::Concern

    private

    def render_api_success(data, status: :ok, meta: {})
      render json: {
        success:    true,
        data:       data,
        meta:       meta,
        request_id: request.request_id
      }, status: status
    end

    def render_api_error(code, message: nil, details: [], legacy_errors: nil)
      code    = code.to_sym
      status  = Api::Errors::STATUS_BY_CODE.fetch(code)
      message = message.presence || I18n.t("api.errors.#{code}")

      render json: {
        success:    false,
        error:      { code: code.to_s, message: message, details: details },
        request_id: request.request_id,
        message:    message,
        errors:     legacy_errors || details.map { |d| d[:message] }.compact
      }, status: status
    end

    # 422 validation_failed from an ActiveModel errors collection.
    def render_validation_errors(record_or_errors)
      errors = record_or_errors.respond_to?(:errors) ? record_or_errors.errors : record_or_errors
      render_api_error(
        :validation_failed,
        details:       validation_details(errors),
        legacy_errors: errors.full_messages
      )
    end

    # 422 business_rule_violation from a failed service Result. Services use two
    # Result conventions (`ok?` and `success?`); both are read here so neither
    # has to change. The service's own message is passed through verbatim.
    def render_service_failure(result)
      legacy_errors = Array(result.try(:errors)).compact
      message       = result.try(:error).presence || legacy_errors.first
      render_api_error(:business_rule_violation, message: message, legacy_errors: legacy_errors.presence || Array(message))
    end

    # 429 for Rails' `rate_limit ... with:`. Always the standard envelope — the
    # status is new, so no legacy client depends on a previous body.
    def render_rate_limited(retry_after:)
      response.set_header("Retry-After", retry_after.to_i.to_s)
      render_api_error(:rate_limited)
    end

    def service_result_ok?(result)
      result.respond_to?(:ok?) ? result.ok? : result.success?
    end

    def validation_details(errors)
      errors.map do |error|
        {
          field:   error.attribute.to_s,
          code:    error.type.is_a?(Symbol) ? error.type.to_s : "invalid",
          message: error.full_message
        }
      end
    end
  end
end
