require "rails_helper"

# Boundary enforcement for Pilot 5 — Organization & Access ↔ Workforce
# membership contract (M6; see docs/architecture/next-pilot-selection.md §20).
#
# Branch membership is Workforce data (BranchMembership over ShiftAssignment).
# Organization & Access reads it only through its own contract
# OrganizationAccess::MembershipProvider, implemented by Workforce
# (Workforce::MembershipProvider) and wired in
# config/initializers/organization_access_membership_provider.rb.
#
# 1. The access scopes (EmployeeScope, BranchScope) and the contract never name
#    BranchMembership, ShiftAssignment, shift-assignment associations, Shifts::
#    or Workforce:: — no exception.
# 2. The rest of Organization & Access code may name them only in the
#    classified exceptions below, each limited to its exact current shape.
# 3. Only the composition root and Workforce name Workforce::MembershipProvider,
#    and it is the registered provider.
#
# Not guarded: the include_shift_assignments keyword and the private
# shift_assignment_branch_ids method name (names, not dependencies), t(...)
# i18n keys, comments, config/ (routes, locales), and every other domain —
# Attendance & Payroll, Finance & Sales, Inventory & Purchasing and Reporting
# reading Workforce is an allowed downstream direction.
module ArchitectureSpecs
  module OrganizationAccessMembershipBoundary
    module_function

    FORBIDDEN = /
      \bBranchMembership\b
      | \bShiftAssignment\b
      | \bWorkforce::
      | \bShifts::
      | \.shift_assignments\b
      | \b(?:has_many|has_one|belongs_to)\s+:shift_assignments?\b
    /x

    # Organization & Access production code (module-boundaries.md §4).
    ORGANIZATION_ACCESS_GLOBS = %w[
      app/services/employee_scope.rb
      app/services/branch_scope.rb
      app/services/organization_access/**/*.rb
      app/services/approvals/**/*.rb
      app/models/organization_access/**/*.rb
      app/models/{business,branch,user,user_audit_log}.rb
      app/controllers/admin/{branches,permission_roles,settings}_controller.rb
      app/controllers/{sessions,registrations,locale,preferences}_controller.rb
      app/controllers/profile/**/*.rb
      app/controllers/api/v1/sessions_controller.rb
      app/policies/{branch,permission_role}_policy.rb
      app/views/admin/branches/**/*.erb
      app/views/admin/permission_roles/**/*.erb
      app/views/admin/settings/**/*.erb
    ].freeze

    # No exception, ever: the access scopes and the contract itself.
    STRICT_FILES = %w[
      app/services/employee_scope.rb
      app/services/branch_scope.rb
      app/services/organization_access/membership_provider.rb
    ].freeze

    # Classified exceptions (Pilot 5 M0 §20.1). Each may contain only lines
    # matching one of its shapes. Class E = lifecycle association,
    # F = read / composition.
    EXCEPTIONS = {
      "app/models/user.rb" => {
        classes: "E + F",
        reason: "User has_many :shift_assignments (inverse association; dependent: :destroy is the documented User " \
                "cascade) and User#effective_shift_assignment_on → Shifts::AssignmentResolver (User / Employee " \
                "stewardship helper consumed by Attendance and cash screens)",
        shapes: [ /\Ahas_many :shift_assignments,\s+dependent: :destroy\z/,
                  /\AShifts::AssignmentResolver\.for\(user: self, date: date, time: time\)\z/ ]
      },
      "app/models/branch.rb" => {
        classes: "E",
        # Was dependent: :nullify (a write into Workforce rows); BUG-026 made it
        # restrict_with_error — an existence check only, so history is never detached.
        reason: "Branch has_many :shift_assignments (inverse association, dependent: :restrict_with_error)",
        shapes: [ /\Ahas_many :shift_assignments,\s+dependent: :restrict_with_error\z/ ]
      },
      "app/controllers/admin/branches_controller.rb" => {
        classes: "F",
        reason: "Branch staff view (#show): lists the branch's current employees and shift assignments and " \
                "selects their pending requests — a cross-domain dashboard (target: Reporting / composition)",
        shapes: [ /\A@employees = User\.where\(id: ShiftAssignment\.user_ids_for_branches\(\[ @branch\.id \]\), active: true\)\z/,
                  /\A@shift_assignments = @branch\.shift_assignments\.current\z/,
                  /\Abranch_user_ids = ShiftAssignment\.user_ids_for_branches\(\[ @branch\.id \]\)\z/ ]
      },
      "app/controllers/api/v1/sessions_controller.rb" => {
        classes: "F",
        reason: "Login payload checkin_branch_ids — the documented mixed OA / WF / AP session payload " \
                "(module-boundaries.md §17); API unchanged",
        shapes: [ /\Acheckin_branch_ids: ShiftAssignment\.current\z/ ]
      }
    }.freeze

    COMPOSITION_ROOT = "config/initializers/organization_access_membership_provider.rb".freeze
    CONTRACT_FILE    = "app/services/organization_access/membership_provider.rb".freeze

    WRITE_CALL = /\.(?:create|update|update_all|update_columns?|save|destroy|destroy_all|delete|delete_all|
                    insert_all|upsert_all|build|new|find_or_create_by)!?(?=[(\s]|$)/x

    def organization_access_files
      ORGANIZATION_ACCESS_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }
                               .map { |f| f.delete_prefix("#{Rails.root}/") }.uniq.sort
    end

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Full-line comments, ERB comments and t(...) i18n keys are ignored.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/\b(?:I18n\.)?t\(\s*(["'])[^"']*\1/, 't("KEY"'), number ] }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| [ number, line.strip ] if line.match?(pattern) }
    end

    def violations_in(path)
      allowed_shapes = EXCEPTIONS.dig(path, :shapes) || []
      matches_in(path, FORBIDDEN).reject { |_, line| allowed_shapes.any? { |shape| line.match?(shape) } }
                                 .map { |number, line| "#{path}:#{number}: #{line}" }
    end
  end
end

RSpec.describe "Architecture: Organization & Access ↔ Workforce membership boundary" do
  boundary = ArchitectureSpecs::OrganizationAccessMembershipBoundary

  it "covers every Organization & Access glob (no stale glob)" do
    empty = boundary::ORGANIZATION_ACCESS_GLOBS.select { |glob| Dir.glob(Rails.root.join(glob)).empty? }
    expect(empty).to be_empty, "Remove or fix: #{empty.join(', ')}"
  end

  it "the access scopes and the contract name no Workforce membership internals (no exception)" do
    violations = boundary::STRICT_FILES.flat_map { |path| boundary.matches_in(path, boundary::FORBIDDEN).map { |n, l| "#{path}:#{n}: #{l}" } }
    expect(violations).to be_empty, <<~MSG
      Organization & Access scopes must read membership only through OrganizationAccess::MembershipProvider:
      #{violations.join("\n")}
    MSG
  end

  it "the access scopes read membership through their own contract" do
    expect(boundary.matches_in("app/services/employee_scope.rb", /OrganizationAccess::MembershipProvider\.current_member_ids\(/)).to be_present
    expect(boundary.matches_in("app/services/branch_scope.rb", /OrganizationAccess::MembershipProvider\.current_branch_ids\(@user\)/)).to be_present
  end

  it "the rest of Organization & Access reaches Workforce membership only in the classified exceptions" do
    violations = (boundary.organization_access_files - boundary::STRICT_FILES).flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Unclassified Organization & Access → Workforce membership reference:
      #{violations.join("\n")}
      Use OrganizationAccess::MembershipProvider, or classify a new exception in next-pilot-selection.md §20.
    MSG
  end

  it "keeps the read / composition exceptions read-only and every exception still needed" do
    read_only = boundary::EXCEPTIONS.select { |_, e| e[:classes] == "F" }.keys
    writes = read_only.flat_map { |path| boundary.matches_in(path, boundary::FORBIDDEN) }.select { |_, line| line.match?(boundary::WRITE_CALL) }
    expect(writes).to be_empty

    stale = boundary::EXCEPTIONS.keys.select do |path|
      !File.exist?(Rails.root.join(path)) || boundary.matches_in(path, boundary::FORBIDDEN).empty?
    end
    expect(stale).to be_empty, "Remove from the exceptions: #{stale.join(', ')}"
    expect(boundary::EXCEPTIONS.keys - boundary.organization_access_files).to be_empty
  end

  it "only the composition root and Workforce name the Workforce implementation; it is the registered provider" do
    sources = boundary.source_files + boundary.source_files("config")
    outside = sources.reject { |file| file.start_with?("app/services/workforce/") || file == boundary::COMPOSITION_ROOT }
                     .flat_map { |file| boundary.matches_in(file, /\bWorkforce::MembershipProvider\b/).map { |n, l| "#{file}:#{n}: #{l}" } }

    expect(outside).to be_empty, "Unexpected reference to the Workforce implementation:\n#{outside.join("\n")}"
    expect(boundary.matches_in(boundary::COMPOSITION_ROOT,
                               /OrganizationAccess::MembershipProvider\.register\(Workforce::MembershipProvider\)/)).to be_present
    expect(OrganizationAccess::MembershipProvider.provider).to equal(Workforce::MembershipProvider)
    expect(OrganizationAccess::MembershipProvider::OPERATIONS)
      .to all(satisfy { |op| Workforce::MembershipProvider.respond_to?(op) })
  end

  it "the Workforce implementation stays a delegation to the Workforce membership owner" do
    code = boundary.code_lines("app/services/workforce/membership_provider.rb").map(&:first).join
    expect(code).to include("BranchMembership.current_branch_ids(user)", "BranchMembership.current_member_ids(branch_ids)",
                            "BranchMembership.effective_assignments_at?(branch_id, on: on)")
    expect(code).not_to match(/\bEmployeeScope\b|\bBranchScope\b|OrganizationAccess::MembershipProvider/)
  end

  describe "self-tests (planted probes)" do
    def plant(path, content)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    it "catches BranchMembership and ShiftAssignment planted in EmployeeScope and BranchScope" do
      plant("app/services/employee_scope.rb", "base.where(id: BranchMembership.current_member_ids(ids))\n")
      expect(boundary.matches_in("app/services/employee_scope.rb", boundary::FORBIDDEN)).not_to be_empty

      plant("app/services/branch_scope.rb", "ShiftAssignment.current.where(user_id: @user.id).pluck(:branch_id)\n")
      expect(boundary.matches_in("app/services/branch_scope.rb", boundary::FORBIDDEN)).not_to be_empty
    end

    it "catches a Workforce name planted in the contract" do
      plant(boundary::CONTRACT_FILE, "def current_branch_ids(user) = Workforce::MembershipProvider.current_branch_ids(user)\n")
      expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::FORBIDDEN)).not_to be_empty
    end

    it "catches a widened read and a write in a read exception" do
      plant("app/controllers/admin/branches_controller.rb",
            "@shift_assignments = @branch.shift_assignments.current\n@branch.shift_assignments.destroy_all\n")
      expect(boundary.violations_in("app/controllers/admin/branches_controller.rb"))
        .to eq([ "app/controllers/admin/branches_controller.rb:2: @branch.shift_assignments.destroy_all" ])
    end

    it "catches a membership reference planted in another Organization & Access file" do
      plant("app/services/organization_access/permission_grants.rb", "ids = ShiftAssignment.user_ids_for_branches(branch_ids)\n")
      expect(boundary.violations_in("app/services/organization_access/permission_grants.rb")).not_to be_empty
    end

    it "ignores comments, i18n keys and the include_shift_assignments keyword" do
      plant("app/services/branch_scope.rb",
            "# BranchMembership is Workforce\nt(\"admin.branches.shift_assignments\")\n" \
            "def initialize(user, include_shift_assignments: false)\nids += shift_assignment_branch_ids\n")
      expect(boundary.matches_in("app/services/branch_scope.rb", boundary::FORBIDDEN)).to be_empty
    end
  end
end
