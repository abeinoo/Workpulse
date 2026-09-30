require "rails_helper"

# Keeps docs/api/openapi.yaml in sync with the /api/v1 routes that actually
# work (a route counts only when its controller and action exist). Routes
# declared without an implementation are tracked by the last example and must
# NOT be documented (docs/api/baseline.md → D2).
RSpec.describe "docs/api/openapi.yaml" do
  let(:http_methods) { %w[get post put patch delete] }

  let(:spec) do
    YAML.safe_load_file(Rails.root.join("docs/api/openapi.yaml"), aliases: true)
  end

  let(:documented) do
    spec.fetch("paths").flat_map do |path, operations|
      (operations.keys & http_methods).map { |verb| "#{verb.upcase} #{path}" }
    end.to_set
  end

  let(:api_routes) do
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub("(.:format)", "")
      next unless path.start_with?("/api/v1/")

      verb = route.verb.to_s
      next if verb.empty?

      { key: "#{verb} #{path.gsub(/:(\w+)/, '{\1}')}", controller: route.defaults[:controller], action: route.defaults[:action] }
    end
  end

  def implemented?(route)
    klass = "#{route[:controller]}_controller".camelize.safe_constantize
    klass && klass.action_methods.include?(route[:action])
  end

  let(:implemented_routes)   { api_routes.select { |r| implemented?(r) }.map { |r| r[:key] }.to_set }
  let(:unimplemented_routes) { api_routes.reject { |r| implemented?(r) }.map { |r| r[:key] }.to_set }

  it "is valid OpenAPI 3.1 metadata" do
    expect(spec["openapi"]).to eq("3.1.0")
    expect(spec.dig("info", "version")).to eq("v1")
  end

  it "documents every implemented /api/v1 route" do
    expect(implemented_routes - documented).to be_empty
  end

  it "documents nothing that is not an implemented route" do
    expect(documented - implemented_routes).to be_empty
  end

  it "tracks routes that are declared but not implemented (known defect D2)" do
    expect(unimplemented_routes.map { |k| k.split(" ", 2).last.split("/")[3] }.uniq)
      .to match_array(%w[businesses branches users shifts shift_assignments employee_requests])
  end

  it "resolves every $ref" do
    refs = spec.to_s.scan(%r{"#/components/(\w+)/(\w+)"})
    refs.each do |section, name|
      expect(spec.dig("components", section, name)).not_to be_nil, "missing #/components/#{section}/#{name}"
    end
  end
end
