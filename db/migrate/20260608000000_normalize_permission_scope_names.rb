# Rewrites stored permission_scopes jsonb from legacy scope names to the new
# canonical set (self / branch / area / business). managed_employees_only is
# folded into branch. Data-only and idempotent — re-running is a no-op.
#
# Runtime already normalizes on read (PermissionRole#scope_for) and on save, so
# this migration just makes storage canonical; it does not change behavior.
class NormalizePermissionScopeNames < ActiveRecord::Migration[8.1]
  ALIASES = {
    "self_only"              => "self",
    "managed_employees_only" => "branch",
    "branch_only"            => "branch",
    "business_wide"          => "business"
  }.freeze

  def up
    say_with_time "Normalizing permission_roles.permission_scopes" do
      count = 0
      PermissionRole.reset_column_information
      PermissionRole.find_each do |role|
        scopes = role.permission_scopes
        next if scopes.blank?

        normalized = scopes.transform_values { |v| ALIASES.fetch(v.to_s, v) }
        next if normalized == scopes

        role.update_column(:permission_scopes, normalized)
        count += 1
      end
      count
    end
  end

  def down
    # No-op: canonical names are forward-compatible and the legacy aliases remain
    # resolvable, so there is nothing to roll back.
  end
end
