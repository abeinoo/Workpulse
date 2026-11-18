module OrganizationAccess
  # Applies the Branch form to a branch, exactly as Admin::BranchesController
  # did before branch create/update moved into OrganizationAccess::CreateBranch /
  # OrganizationAccess::UpdateBranch (Warehouse Architecture — PR 3):
  #
  # * the permitted branch attributes;
  # * the POS terminal rows, staged through the Organization & Access
  #   BranchTerminalSettings contract (Finance & Sales implements it) and saved
  #   by the branch's own save, in the same transaction (Pilot 12);
  # * Branch#branch_type is a Rails enum — assigning an unsupported string
  #   raises ArgumentError before any validation runs, so a tampered value is
  #   turned into a normal validation-style error instead of a 500.
  #
  # Returns true when applied, false (with the branch_type error) otherwise.
  module BranchFormAssignment
    module_function

    def assign(branch:, attributes:, terminal_rows:)
      branch.assign_attributes(attributes)
      rows = terminal_rows
      OrganizationAccess::BranchTerminalSettings.assign(branch: branch, rows: rows) unless rows.nil?
      true
    rescue ArgumentError
      branch.errors.add(:branch_type, :inclusion)
      false
    end
  end
end
