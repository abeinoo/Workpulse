require "rails_helper"

# BUG-047: the JSON API declares only the actions it serves. Every /api route
# must resolve to an existing controller and a public action defined on it, so
# the route list is the real API contract.
RSpec.describe "API routes resolve to real actions" do
  it "has a controller and a defined action behind every /api route" do
    missing = Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      action     = route.defaults[:action]
      next unless controller&.start_with?("api/") && action

      klass = "#{controller.camelize}Controller".safe_constantize
      next "#{route.verb} #{route.path.spec} → #{controller} (no controller)" unless klass
      next if klass.action_methods.include?(action)

      "#{route.verb} #{route.path.spec} → #{controller}##{action} (no action)"
    end
    expect(missing).to be_empty, "API routes without an action:\n#{missing.uniq.join("\n")}"
  end
end
