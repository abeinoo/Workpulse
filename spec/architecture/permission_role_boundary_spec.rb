require "rails_helper"

# Boundary enforcement for the PermissionRole pilot (Step 6, see
# docs/architecture/permission-role-migration-plan.md).
#
# Outside Organization & Access, code must reach roles and permissions only via:
#   * User#can? / User#scope_for / User#management_sidebar? (authorization)
#   * OrganizationAccess::PermissionCatalog (permission groups)
#   * OrganizationAccess::Authorization (granted permissions)
# and must not touch PermissionRole, the permission_role(s) association/table,
# PermissionGrants or the Organization & Access role-operation services.
#
# This spec fails on any NEW direct reference outside the allow-list below.
# Adding to the allow-list is an architectural decision: give the reason.
module ArchitectureSpecs
  module PermissionRoleBoundary
    module_function

    FORBIDDEN = /
      \bPermissionRole\b                     # the model and its catalogue constants (not PermissionRolePolicy)
      | \bPermissionGrants\b                 # grant rules (Organization & Access internal)
      | \bpermission_roles?\b                # the association and the table
      | OrganizationAccess::(?:RoleAssignmentRule|ChangeUserRole|CreateRole|UpdateRole|DeleteRole|RoleGrantCheck)\b
    /x

    # Preloading the association only feeds User#can? (plan I11); allowed anywhere.
    ALLOWED_LINE = /\.includes\(\s*:permission_role\b/

    ALLOWED_FILES = {
      # Organization & Access internals
      "app/models/permission_role.rb"                       => "the model itself",
      "app/models/user.rb"                                  => "account role association, can?/scope_for",
      "app/models/business.rb"                              => "business has_many :permission_roles",
      "app/policies/permission_role_policy.rb"              => "role administration policy",
      "app/policies/user_policy.rb"                         => "account/role attribute tiers, privilege hierarchy",
      "app/controllers/admin/permission_roles_controller.rb" => "role administration screens",
      "app/controllers/admin/users_controller.rb"           => "role assignment on the employee form",
      "app/views/admin/users/_form.html.erb"                => "assignable-role list",
      "app/views/admin/users/show.html.erb"                 => "role name display",
      "app/views/admin/branches/_employees.html.erb"        => "role name display (Organization & Access branch admin)",
      "app/views/admin/dashboard/index.html.erb"            => "role name display (Organization & Access admin dashboard)",
      "app/views/layouts/_sidebar.html.erb"                 => "UI shell: role-screen nav entry and current role label",
      # Must remain unchanged (plan D3 / text only)
      "lib/tasks/attendance.rake"                           => "R-L4, out of scope (plan D3)",
      "lib/tasks/laundry.rake"                              => "operator message text only"
    }.freeze

    ALLOWED_DIRS = [
      "app/services/organization_access/",                  # the boundary itself
      "app/views/admin/permission_roles/"                   # role administration screens
    ].freeze

    def source_files
      Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Full-line Ruby comments and ERB comments (including multi-line) are ignored.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1).reject { |line, _| line.lstrip.start_with?("#") }
    end

    def violations_in(path)
      code_lines(path).filter_map do |line, number|
        "#{path}:#{number}: #{line.strip}" if line.match?(FORBIDDEN) && !line.match?(ALLOWED_LINE)
      end
    end

    def allowed?(path)
      ALLOWED_FILES.key?(path) || ALLOWED_DIRS.any? { |dir| path.start_with?(dir) }
    end
  end
end

RSpec.describe "Architecture: PermissionRole boundary" do
  boundary = ArchitectureSpecs::PermissionRoleBoundary

  it "has no direct PermissionRole / PermissionGrants access outside Organization & Access" do
    violations = boundary.source_files.reject { |path| boundary.allowed?(path) }.flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Direct access to Organization & Access role internals from outside the boundary:
      #{violations.join("\n")}
      Use user.can? / user.scope_for, OrganizationAccess::PermissionCatalog or
      OrganizationAccess::Authorization instead.
    MSG
  end

  it "keeps the allow-list tight (every listed file still needs its exception)" do
    stale = boundary::ALLOWED_FILES.keys.select { |path| !File.exist?(Rails.root.join(path)) || boundary.violations_in(path).empty? }
    expect(stale).to be_empty, "Remove from ALLOWED_FILES: #{stale.join(', ')}"
  end

  it "detects direct access and accepts the boundary interfaces" do
    expect("PermissionRole::PERMISSION_GROUPS[:x]").to match(boundary::FORBIDDEN)
    expect("user.permission_role&.permissions").to match(boundary::FORBIDDEN)
    expect("OrganizationAccess::PermissionGrants.covers?(a, b)").to match(boundary::FORBIDDEN)
    expect("OrganizationAccess::ChangeUserRole.new(1, actor: a, role_id: 2)").to match(boundary::FORBIDDEN)
    expect("OrganizationAccess::PermissionCatalog.group(:laundry_operations)").not_to match(boundary::FORBIDDEN)
    expect("OrganizationAccess::Authorization.granted_permissions(user)").not_to match(boundary::FORBIDDEN)
    expect("authorize PermissionRolePolicy; user.can?(:view_attendance)").not_to match(boundary::FORBIDDEN)
    expect("users.includes(:permission_role).where(id: ids)").to match(boundary::ALLOWED_LINE)
  end
end
