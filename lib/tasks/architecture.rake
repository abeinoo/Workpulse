# Report-only domain dependency inventory (module-boundaries.md §19 step 0).
# Writes docs/architecture/dependency-inventory-report.txt; never fails on findings.
namespace :architecture do
  desc "Write the report-only domain dependency inventory to docs/architecture/dependency-inventory-report.txt"
  task dependency_report: :environment do
    require Rails.root.join("script/architecture/dependency_inventory").to_s

    inventory = ArchitectureTools::DependencyInventory
    path = Rails.root.join("docs/architecture/dependency-inventory-report.txt")
    File.write(path, inventory.report)
    puts File.read(path).lines.take_while { |line| line.start_with?("#") }.join
    puts "Wrote #{path.relative_path_from(Rails.root)}"
  end
end
