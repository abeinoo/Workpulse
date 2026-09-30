# One structured JSON log line per /api request, correlated by request_id
# (see Api::RequestContext and docs/api/conventions.md → "Request tracing").
#
# Deliberately excluded: params, request/response bodies, headers, the query
# string (it can carry login identifiers), tokens and any personal data.
ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
  payload = event.payload
  next unless payload[:api]

  exception = payload[:exception]
  status    = payload[:status] || (exception ? 500 : nil)

  Rails.logger.info({
    event:       "api.request",
    request_id:  payload[:request_id],
    method:      payload[:method],
    path:        payload[:path].to_s.split("?").first,
    controller:  payload[:controller],
    action:      payload[:action],
    status:      status,
    duration_ms: event.duration.round(1),
    db_ms:       payload[:db_runtime]&.round(1),
    user_id:     payload[:user_id],
    business_id: payload[:business_id],
    device_id:   payload[:device_id],
    error_class: exception&.first
  }.compact.to_json)
end
