module Api
  # Adds API tracing fields to the `process_action.action_controller`
  # instrumentation payload. config/initializers/api_request_logging.rb turns
  # payloads marked `api: true` into one structured JSON log line per request.
  #
  # Only identifiers and timings are recorded — never params, bodies, headers,
  # tokens or personal data.
  module RequestContext
    extend ActiveSupport::Concern

    private

    def append_info_to_payload(payload)
      super
      payload[:api]        = true
      payload[:request_id] = request.request_id
      payload.merge!(api_log_actor)
    rescue StandardError
      # Tracing must never break a request.
      payload[:api] = true
    end

    # Reads the already-authenticated user without running Warden callbacks
    # (which could throw :warden from inside instrumentation).
    # Overridden by the device-authenticated base controller.
    def api_log_actor
      user = request.env["warden"]&.user(scope: :user, run_callbacks: false)
      { user_id: user&.id, business_id: user&.business_id }
    end
  end
end
