# Generates the route-level baseline of the UI/UX scenario inventory
# (docs/quality/ui-ux-scenario-inventory.md): every application route with its
# domain, authorization style and the request / system specs that reference it.
# "Referenced" is a text match (path helper, controller class or path prefix),
# so a zero means "verify", not "untested".
#
#   OUT=docs/quality/ui-ux-route-inventory.csv bin/rails runner script/quality/route_inventory.rb
require Rails.root.join("script/architecture/dependency_inventory").to_s
require "csv"
inv = ArchitectureTools::DependencyInventory
specs = Dir[Rails.root.join("spec/{requests,system,controllers,features}/**/*_spec.rb")].to_h { |f| [ f.delete_prefix("#{Rails.root}/"), File.read(f) ] }
rows = []
Rails.application.routes.routes.each do |route|
  controller = route.defaults[:controller]; action = route.defaults[:action]
  next unless controller && action
  next if controller.start_with?("rails/", "active_storage/", "action_mailbox/", "turbo/", "devise/") && !controller.start_with?("devise")
  file = "app/controllers/#{controller}_controller.rb"
  next unless File.exist?(Rails.root.join(file))
  source = File.read(Rails.root.join(file))
  verb = route.verb.to_s
  path = route.path.spec.to_s.sub("(.:format)", "")
  name = route.name
  auth = source.match?(/\bauthorize\b|\bpolicy_scope\b/) ? "pundit" : (source.match?(/authenticate_device|current_device|require_|before_action/) ? "custom" : "none")
  helper = name ? "#{name}_path" : nil
  klass = "#{controller.camelize}Controller"
  covered = specs.select { |f, src| (helper && src.include?(helper)) || src.include?(klass) || src.include?("\"#{path.split('/:').first}") }.keys
  rows << [ inv.domain_of_file(file) || "unmapped", controller, action, verb, path, auth,
            covered.count { |f| f.include?("spec/requests") || f.include?("spec/controllers") },
            covered.count { |f| f.include?("spec/system") }, covered.first(3).join(" ") ]
end
rows.uniq!
File.write(ENV.fetch("OUT"), CSV.generate { |csv| csv << %w[domain controller action verb path auth request_specs system_specs examples]; rows.sort.each { |r| csv << r } })
puts "#{rows.size} routes"
puts rows.group_by(&:first).map { |d, rs| "#{d}: #{rs.size} routes, #{rs.count { |r| r[6].zero? && r[7].zero? }} with no request/system spec reference, #{rs.map { _1[1] }.uniq.size} controllers" }
