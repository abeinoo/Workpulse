require "rails_helper"
require Rails.root.join("script/architecture/dependency_inventory").to_s

# Boundary for D1 (#7) — Organization & Access account fields are written only
# through OrganizationAccess::Accounts (module-boundaries.md §3.2, §14.2 #7;
# docs/architecture/organization-access-account-interface-baseline-failures.txt).
#
# Rules (over every app/ file; "Organization & Access" = the files the domain
# dependency inventory maps to it):
# 1. Outside Organization & Access nothing builds a users row (User.new / create,
#    business.users.new / build / create).
# 2. Outside Organization & Access nothing writes an account field of a user:
#    status, login identifiers, role or password through update / update_column(s)
#    / attribute assignment, nor Business#owner.
# 3. Only the classified callers use the interface, each with exactly its
#    operations; the employee form extracts the account fields before assigning
#    the rest.
module ArchitectureSpecs
  module OrganizationAccessAccountInterfaceBoundary
    module_function

    INTERFACE = "app/services/organization_access/accounts.rb".freeze

    BUILD_ROW = /\bUser\.(?:new|create!?|insert(?:_all)?!?)\b|\.users\.(?:new|build|create!?)\b/
    ACCOUNT_FIELD = /(?:active|email|phone_number|permission_role(?:_id)?|encrypted_password|password)/
    # Receivers are matched by name (a user / employee / account variable, or the
    # User class for update_all) — a static scan cannot know the type of an
    # arbitrary local; this precision limit is recorded in next-pilot-selection.md §44.
    USER_RECEIVER = /\b(?:user|employee|account|owner|current_user|@user|@employee|record)/
    ACCOUNT_WRITE = /
      #{USER_RECEIVER}\.(?:update!?|update_columns?|update_attribute|assign_attributes)\(\s*:?#{ACCOUNT_FIELD}\b
      | #{USER_RECEIVER}\.#{ACCOUNT_FIELD}\s*=(?!=)
      | \bUser\b[^#]*\.update_all\([^)]*\b#{ACCOUNT_FIELD}\b
      | \bbusiness\.update!?\(\s*owner:
    /x

    CALL = /OrganizationAccess::Accounts\.(\w+!?)/
    CALLERS = {
      "app/controllers/admin/users_controller.rb"               => %w[build stage stage_role toggle_active! transfer_ownership!],
      "app/services/employee_data_requests/employee_attributes.rb" => %w[build]
    }.freeze

    def inventory = ArchitectureTools::DependencyInventory

    def app_code_files
      inventory.app_files.select { _1.end_with?(".rb", ".erb") }
    end

    def outside_oa = app_code_files.reject { inventory.domain_of_file(_1) == :organization_access }

    def code_lines(path) = inventory.code_lines(path)

    def matches_in(path, pattern) = code_lines(path).filter_map { |l, n| "#{path}:#{n}: #{l.strip}" if l.match?(pattern) }

    def calls_in(path) = code_lines(path).flat_map { |l, _| l.scan(CALL).flatten }.uniq.sort
  end
end

RSpec.describe "Architecture: Organization & Access account fields are written only through OrganizationAccess::Accounts (D1)" do
  boundary = ArchitectureSpecs::OrganizationAccessAccountInterfaceBoundary

  it "the interface is an Organization & Access file" do
    expect(boundary.inventory.domain_of_file(boundary::INTERFACE)).to eq(:organization_access)
  end

  it "nothing outside Organization & Access builds a users row (rule 1)" do
    found = boundary.outside_oa.flat_map { boundary.matches_in(_1, boundary::BUILD_ROW) }
    expect(found).to be_empty, "Build accounts with OrganizationAccess::Accounts.build:\n#{found.join("\n")}"
  end

  it "nothing outside Organization & Access writes an account field (rule 2)" do
    found = boundary.outside_oa.flat_map { boundary.matches_in(_1, boundary::ACCOUNT_WRITE) }
    expect(found).to be_empty, "Write account fields through OrganizationAccess::Accounts:\n#{found.join("\n")}"
  end

  it "only the classified callers use the interface, with exactly their operations (rule 3)" do
    callers = boundary.outside_oa.to_h { [ _1, boundary.calls_in(_1) ] }.reject { _2.empty? }
    expect(callers).to eq(boundary::CALLERS)
  end

  it "the employee form extracts the account fields before assigning the rest (rule 3)" do
    path = "app/controllers/admin/users_controller.rb"
    extracts = boundary.matches_in(path, /p\.extract!\(\*OrganizationAccess::Accounts::FIELDS\)/)
    assigns  = boundary.matches_in(path, /@user\.assign_attributes\(/)
    expect([ extracts.size, assigns.size ]).to eq([ 2, 2 ])
  end

  describe "self-tests" do
    it "matches the former direct writes and row construction" do
      [ "@user.update!(active: !@user.active?)", "current_user.business.update!(owner: @user)",
        "user.permission_role = decision.role", "employee.update_column(:phone_number, x)",
        "@user.assign_attributes(email: e)", "User.where(id: ids).update_all(active: false)" ].each do |code|
        expect(code).to match(boundary::ACCOUNT_WRITE), code
      end
      [ "User.new(attrs)", "current_user.business.users.new", "User.create!(email: e)" ].each do |code|
        expect(code).to match(boundary::BUILD_ROW), code
      end
    end

    it "does not match reads, comparisons, other models or the interface calls" do
      [ "@user.active?", "if user.active == false", "scope.where(active: true)", "department.update!(active: false)",
        "OrganizationAccess::Accounts.toggle_active!(actor: current_user, user: @user)",
        "@user.assign_attributes(p.except(:permission_role_id))" ].each do |code|
        expect(code).not_to match(boundary::ACCOUNT_WRITE), code
      end
    end

    it "reports a write planted outside Organization & Access" do
      path = "app/services/employee_data_requests/reviewer.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(File.join(Rails.root.to_s, path)).and_return("employee.update!(active: false)\n")
      expect(boundary.matches_in(path, boundary::ACCOUNT_WRITE)).not_to be_empty
    end
  end
end
