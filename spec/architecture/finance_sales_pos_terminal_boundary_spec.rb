require "rails_helper"

# Boundary enforcement for Pilot 12 — Finance & Sales POS terminals write
# boundary (M6; see docs/architecture/next-pilot-selection.md §27).
#
# PosTerminal (table pos_terminals) and Finance::BranchPosTerminals are owned by
# Finance & Sales. Organization & Access sits upstream: since M2–M4 the Branch
# form stages its terminal rows only through the Organization & Access-defined
# OrganizationAccess::BranchTerminalSettings contract, implemented by Finance &
# Sales and wired in config/initializers/branch_terminal_settings.rb.
#
# Two boundaries:
# 1. POS terminal internals (the class, the collection/table and the contract
#    implementation) may be named only by Finance & Sales and the classified
#    exceptions below: two inverse lifecycle associations (D-P12-4) and the
#    branch form's read-only UI composition (D-P12-6), limited to its shapes.
# 2. Organization & Access code never writes terminals, never uses the
#    nested-attributes mechanism, and never names the Finance & Sales
#    implementation; the branch controller stages rows through the contract.
#
# Not guarded: route helpers, i18n keys, the form's HTTP parameter name
# pos_terminals_attributes, CSS classes, JavaScript, and config/ (other than the
# composition root), as in the other boundary specs.
#
# This spec fails on any NEW direct reference outside the allow-list below.
# Adding to the allow-list is an architectural decision: give the reason.
module ArchitectureSpecs
  module FinanceSalesPosTerminalBoundary
    module_function

    FORBIDDEN = /
      \bPosTerminal\b            # the model
      | \bpos_terminals\b        # the collection and the table (not the pos_terminals_attributes parameter)
      | \bBranchPosTerminals\b   # the contract implementation
    /x

    # Finance & Sales-owned code (module-boundaries.md §8, §10).
    FINANCE_SALES_FILES = {
      "app/models/pos_terminal.rb"                         => "the model itself",
      "app/services/finance/branch_pos_terminals.rb"       => "FS implementation of OrganizationAccess::BranchTerminalSettings",
      "app/services/finance/pos_imports/branch_resolver.rb" => "FS POS import: resolves a row's branch by its active terminal"
    }.freeze

    # Inverse lifecycle associations on Organization & Access models (D-P12-4).
    LIFECYCLE_FILES = {
      "app/models/branch.rb"   => "OA Branch has_many :pos_terminals, dependent: :restrict_with_error, autosave: true — " \
                                  "a branch with terminals cannot be deleted; autosave persists the rows staged by the " \
                                  "contract in the branch's own save (M4)",
      "app/models/business.rb" => "OA Business has_many :pos_terminals, dependent: :destroy — no code path destroys a " \
                                  "Business; documented lifecycle exception"
    }.freeze

    # The only lines each lifecycle file may contain about terminals.
    LIFECYCLE_LINES = {
      "app/models/branch.rb"   => /\Ahas_many :pos_terminals,\s+dependent: :restrict_with_error, autosave: true\z/,
      "app/models/business.rb" => /\Ahas_many :pos_terminals,\s+dependent: :destroy\z/
    }.freeze

    # Read-only UI composition in the OA branch form (D-P12-6): render the staged
    # rows, the empty state and the new-row template — nothing else.
    BRANCH_FORM = "app/views/admin/branches/_form.html.erb".freeze
    READ_FILES  = {
      BRANCH_FORM => "OA branch form: renders the staged terminal rows, the empty state and the NEW_INDEX template"
    }.freeze
    BRANCH_FORM_SHAPES = [
      /\bbranch\.pos_terminals\.each_with_index\.map do \|terminal, index\|/,
      /\bbranch\.pos_terminals\.any\?/,
      /f\.fields_for :pos_terminals_attributes, PosTerminal\.new, index: "NEW_INDEX" do \|pt_f\|/
    ].freeze

    COMPOSITION_ROOT = "config/initializers/branch_terminal_settings.rb".freeze

    def exception_files = LIFECYCLE_FILES.merge(READ_FILES)

    def allowed_files = FINANCE_SALES_FILES.merge(exception_files)

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Full-line Ruby comments, ERB comments (including multi-line) and t(...)
    # i18n keys are ignored.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/\b(?:I18n\.)?t\(\s*(["'])[^"']*\1/, 't("KEY"'), number ] }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    def violations_in(path) = matches_in(path, FORBIDDEN)

    def allowed?(path) = allowed_files.key?(path)
  end

  module OrganizationAccessBranchTerminalContract
    module_function

    # Organization & Access code that touches branches (module-boundaries.md §4).
    ORGANIZATION_ACCESS_GLOBS = %w[
      app/models/organization_access/**/*.rb
      app/models/{branch,business}.rb
      app/services/organization_access/**/*.rb
      app/controllers/admin/branches_controller.rb
      app/views/admin/branches/**/*.erb
      app/policies/branch_policy.rb
    ].freeze

    # Writing terminals, the nested-attributes mechanism, or naming the FS
    # implementation. (The two lifecycle associations and the form's read
    # shapes are checked by the first boundary.)
    FORBIDDEN_IN_ORGANIZATION_ACCESS = /
      \bBranchPosTerminals\b
      | accepts_nested_attributes_for\s+:pos_terminals
      | pos_terminals_attributes\s*=(?!=)
      | \.pos_terminals\.(?:build|new|create|create!|destroy|destroy_all|delete|delete_all|update_all|insert_all|upsert_all|clear)\b
      | \.pos_terminals\s*<<
      | \bPosTerminal\.(?!new\b)\w+
    /x

    CONTRACT_FILE = "app/services/organization_access/branch_terminal_settings.rb".freeze
    CONTROLLER    = "app/controllers/admin/branches_controller.rb".freeze

    def organization_access_files
      ORGANIZATION_ACCESS_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }
                               .map { |f| f.delete_prefix("#{Rails.root}/") }.uniq.sort
    end
  end
end

RSpec.describe "Architecture: Finance & Sales POS terminal boundary" do
  boundary = ArchitectureSpecs::FinanceSalesPosTerminalBoundary

  it "has no direct POS terminal access outside Finance & Sales and the classified exceptions" do
    violations = boundary.source_files.reject { |path| boundary.allowed?(path) }.flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Direct access to Finance & Sales POS terminal internals from outside the domain:
      #{violations.join("\n")}
      Go through OrganizationAccess::BranchTerminalSettings or Finance & Sales code, or classify a new
      exception in next-pilot-selection.md (§27) and the allow-list.
    MSG
  end

  it "limits the branch form to its read-only composition shapes (D-P12-6)" do
    lines = boundary.violations_in(boundary::BRANCH_FORM)
    expect(lines.size).to eq(boundary::BRANCH_FORM_SHAPES.size)
    unexpected = lines.reject { |line| boundary::BRANCH_FORM_SHAPES.any? { |shape| line.match?(shape) } }
    expect(unexpected).to be_empty, "The branch form may only render terminals:\n#{unexpected.join("\n")}"
    boundary::BRANCH_FORM_SHAPES.each do |shape|
      expect(lines.grep(shape)).not_to be_empty, "#{shape.source} is gone — update the exception"
    end
  end

  it "keeps the Branch and Business lifecycle associations exactly as classified (D-P12-4)" do
    boundary::LIFECYCLE_LINES.each do |path, shape|
      lines = boundary.violations_in(path).map { |line| line.split(": ", 2).last }
      expect(lines.size).to eq(1), "#{path}: #{lines.inspect}"
      expect(lines).to all(match(shape))
    end

    branch = Branch.reflect_on_association(:pos_terminals)
    expect(branch).to have_attributes(macro: :has_many, class_name: "PosTerminal")
    expect(branch.options).to include(dependent: :restrict_with_error, autosave: true)
    expect(Branch.nested_attributes_options).not_to have_key(:pos_terminals)
    expect(Branch.new).not_to respond_to(:pos_terminals_attributes=)

    business = Business.reflect_on_association(:pos_terminals)
    expect(business).to have_attributes(macro: :has_many, class_name: "PosTerminal")
    expect(business.options).to include(dependent: :destroy)
  end

  it "keeps the allow-list tight (every listed file exists and still needs its entry)" do
    stale = boundary.allowed_files.keys.select { |path| !File.exist?(Rails.root.join(path)) || boundary.violations_in(path).empty? }
    expect(stale).to be_empty, "Remove from the allow-list: #{stale.join(', ')}"
  end

  describe "self-tests" do
    it "allows Finance & Sales files and the classified exceptions, and rejects any other file" do
      expect(boundary.allowed?("app/services/finance/branch_pos_terminals.rb")).to be(true)
      expect(boundary.allowed?("app/models/branch.rb")).to be(true)
      expect(boundary.allowed?(boundary::BRANCH_FORM)).to be(true)
      expect(boundary.allowed?("app/controllers/admin/branches_controller.rb")).to be(false)
      expect(boundary.allowed?("app/services/organization_access/branch_terminal_settings.rb")).to be(false)
      expect(boundary.allowed?("app/services/finance/pos_imports/importer.rb")).to be(false)
    end

    it "matches every guarded name, and not the form parameter, the contract or route helpers" do
      [
        "PosTerminal.active.where(business: b)", "branch.pos_terminals.any?", "has_many :pos_terminals",
        "Finance::BranchPosTerminals.assign(**args)"
      ].each { |code| expect(code).to match(boundary::FORBIDDEN), code }
      [
        "params.require(:branch).permit(pos_terminals_attributes: FIELDS)",
        "OrganizationAccess::BranchTerminalSettings.assign(branch: b, rows: r)", "terminal_id", "admin_branch_path(b)"
      ].each { |code| expect(code).not_to match(boundary::FORBIDDEN), code }
    end

    it "flags a guarded reference planted outside the allow-list" do
      external = "app/services/organization_access/hypothetical.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(external)).and_return("PosTerminal.where(branch: b).delete_all\n")

      expect(boundary.allowed?(external)).to be(false)
      expect(boundary.violations_in(external)).to eq([ "#{external}:1: PosTerminal.where(branch: b).delete_all" ])
    end

    it "flags a write or a widened read planted in the branch form" do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(boundary::BRANCH_FORM))
        .and_return("<% branch.pos_terminals.each_with_index.map do |terminal, index| %>\n<% branch.pos_terminals.destroy_all %>\n")

      lines = boundary.violations_in(boundary::BRANCH_FORM)
      expect(lines.reject { |l| boundary::BRANCH_FORM_SHAPES.any? { |s| l.match?(s) } }).not_to be_empty
    end

    it "ignores guarded names in comments and i18n keys" do
      path = "app/services/hypothetical_comment.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path))
        .and_return("# PosTerminal is FS-owned\nlabel = t(\"admin.branches.form.pos_terminals\")\n")

      expect(boundary.violations_in(path)).to be_empty
    end
  end
end

RSpec.describe "Architecture: Organization & Access reaches POS terminals only through BranchTerminalSettings" do
  contract = ArchitectureSpecs::OrganizationAccessBranchTerminalContract
  boundary = ArchitectureSpecs::FinanceSalesPosTerminalBoundary

  it "covers every Organization & Access glob (no stale glob)" do
    empty = contract::ORGANIZATION_ACCESS_GLOBS.select { |glob| Dir.glob(Rails.root.join(glob)).empty? }
    expect(empty).to be_empty, "Remove or fix: #{empty.join(', ')}"
  end

  it "Organization & Access code writes no terminal and names no Finance & Sales implementation" do
    violations = contract.organization_access_files.flat_map { |file| boundary.matches_in(file, contract::FORBIDDEN_IN_ORGANIZATION_ACCESS) }
    expect(violations).to be_empty, <<~MSG
      Organization & Access must stage POS terminals only through OrganizationAccess::BranchTerminalSettings:
      #{violations.join("\n")}
    MSG
  end

  it "the branch controller stages terminal rows only through the contract" do
    lines = boundary.code_lines(contract::CONTROLLER).map(&:first).join
    expect(lines).to include("OrganizationAccess::BranchTerminalSettings.assign(branch: branch, rows: rows)")
  end

  it "the Organization & Access contract names nothing from Finance & Sales" do
    expect(boundary.matches_in(contract::CONTRACT_FILE, /\bFinance::|\bPosTerminal\b|\bpos_terminals\b/)).to be_empty
  end

  it "only the composition root and Finance & Sales name the implementation; it is the registered handler" do
    reference = /\bBranchPosTerminals\b/
    outside = (boundary.source_files + boundary.source_files("config"))
              .reject { |file| file == "app/services/finance/branch_pos_terminals.rb" || file == boundary::COMPOSITION_ROOT }
              .flat_map { |file| boundary.matches_in(file, reference) }

    expect(outside).to be_empty, "Unexpected reference to the contract implementation:\n#{outside.join("\n")}"
    expect(boundary.matches_in(boundary::COMPOSITION_ROOT,
                               /OrganizationAccess::BranchTerminalSettings\.register\(Finance::BranchPosTerminals\)/)).to be_present
    expect(OrganizationAccess::BranchTerminalSettings.handler).to equal(Finance::BranchPosTerminals)
  end

  describe "self-tests" do
    it "flags write mechanics and implementation references planted in Organization & Access code" do
      [
        "Finance::BranchPosTerminals.assign(branch: b, rows: r)", "PosTerminal.create!(attrs)",
        "accepts_nested_attributes_for :pos_terminals", "branch.pos_terminals_attributes = rows",
        "branch.pos_terminals.build(attrs)", "@branch.pos_terminals.destroy_all", "branch.pos_terminals << terminal"
      ].each { |code| expect(code).to match(contract::FORBIDDEN_IN_ORGANIZATION_ACCESS), code }
    end

    it "allows the contract, the form's reads and the template object" do
      [
        "OrganizationAccess::BranchTerminalSettings.assign(branch: branch, rows: rows)", "branch.pos_terminals.any?",
        "f.fields_for :pos_terminals_attributes, PosTerminal.new, index: \"NEW_INDEX\" do |pt_f|",
        "params.require(:branch).permit(pos_terminals_attributes: POS_TERMINAL_FIELDS)"
      ].each { |code| expect(code).not_to match(contract::FORBIDDEN_IN_ORGANIZATION_ACCESS), code }
    end
  end
end
