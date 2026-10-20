require "rails_helper"

# Boundary enforcement for Pilot 8 — Workforce Employee Insurance Profile (M6;
# see docs/architecture/next-pilot-selection.md §23).
#
# EmployeeInsuranceProfile (table employee_insurance_profiles),
# Employee::InsuranceProfileUpdater, Admin::EmployeeInsuranceProfilesController,
# EmployeeInsuranceProfilePolicy, the insurance form and the employee page's
# Social Insurance card are owned by Workforce. Payroll periods, entries and
# their recalculation are owned by Attendance & Payroll, downstream of
# Workforce. Since M2–M3 Workforce reaches them only through the
# Workforce-defined contract Employee::InsuranceProfileEffects, implemented by
# Payroll::InsuranceProfileEffects and wired in
# config/initializers/employee_insurance_profile_effects.rb.
#
# Rules:
# 1. Workforce insurance-profile code never names Attendance & Payroll: no
#    Payroll:: / Attendance:: constant (EntryRecalculator, the contract
#    implementation, …), PayrollPeriod / PayrollEntry / PayrollLineItem, their
#    associations, or a period's locked? state. It may use the contract.
# 2. The two M3 callers use the contract: the updater for profile_changed, the
#    controller for payroll_notice_for.
# 3. The Attendance & Payroll implementation is named only by the composition
#    root.
# 4. Outside Workforce, the profile is named only by the classified exceptions:
#    the Organization & Access lifecycle associations (Business, User; exact
#    line shapes) and the Attendance & Payroll read in Payroll::EntryCalculator
#    (the allowed direction — not a contract).
# 5. That read stays a read: nothing outside Workforce writes the profile.
#
# Not guarded: route helpers, i18n keys, the insurance permission names,
# comments, JavaScript and config/ (routes, locales), as in the other boundary
# specs. The employee page's salary card (SalaryProfile, module-boundaries.md
# §12.2 "salary display", SEC-M2-5) is a separate, documented edge and is not
# scanned here — only the Social Insurance section of that view is.
module ArchitectureSpecs
  module WorkforceEmployeeInsuranceProfileBoundary
    module_function

    CONTRACT            = "Employee::InsuranceProfileEffects".freeze
    CONTRACT_FILE       = "app/services/employee/insurance_profile_effects.rb".freeze
    IMPLEMENTATION      = "Payroll::InsuranceProfileEffects".freeze
    IMPLEMENTATION_FILE = "app/services/payroll/insurance_profile_effects.rb".freeze
    COMPOSITION_ROOT    = "config/initializers/employee_insurance_profile_effects.rb".freeze

    # Workforce insurance-profile code (module-boundaries.md §5 / §10).
    WORKFORCE_FILES = {
      "app/models/workforce/employee_insurance_profile.rb"             => "the model (folder collapsed: top-level constant, M7)",
      "app/services/employee/insurance_profile_updater.rb"             => "the single write path (M3 caller: profile_changed)",
      CONTRACT_FILE                                                    => "the Workforce contract",
      "app/controllers/admin/employee_insurance_profiles_controller.rb" => "the insurance form (M3 caller: payroll_notice_for)",
      "app/policies/employee_insurance_profile_policy.rb"              => "authorization (SEC-P8-2 scope)"
    }.freeze

    WORKFORCE_DIRS = [ "app/views/admin/employee_insurance_profiles/" ].freeze

    # The employee page (Workforce part of admin/users) renders the card; only its
    # Social Insurance section is in scope: from this marker to the next ERB section comment.
    EMPLOYEE_PAGE   = "app/views/admin/users/show.html.erb".freeze
    CARD_SECTION    = /<%#\s*Social Insurance\s*%>/

    # Derived from the edges removed in M3 (§23.3): the recalculator, the payroll
    # period / entry queries and the locked? rule — and, generally, any Attendance
    # & Payroll constant, including the contract implementation.
    FORBIDDEN_IN_WORKFORCE = /
      \bPayroll::\w+                                     # EntryRecalculator, InsuranceProfileEffects, …
      | \bAttendance::\w+
      | \b(?:PayrollPeriod|PayrollEntry|PayrollLineItem)\b
      | \bpayroll_(?:periods|entries|line_items)\b       # associations, e.g. @employee.payroll_entries
      | \blocked\?                                       # a payroll period's state (incl. &:locked?)
    /x

    CALLERS = {
      "app/services/employee/insurance_profile_updater.rb"              => :profile_changed,
      "app/controllers/admin/employee_insurance_profiles_controller.rb" => :payroll_notice_for
    }.freeze

    PROFILE = /\bEmployeeInsuranceProfile\b|\bemployee_insurance_profiles?\b/

    # The only places outside Workforce that may name the profile, each limited
    # to its exact current line shape.
    EXCEPTIONS = {
      "app/models/business.rb" => {
        kind: "lifecycle (Organization & Access inverse association)",
        shapes: [ /\Ahas_many :employee_insurance_profiles,\s+dependent: :destroy\z/ ]
      },
      "app/models/user.rb" => {
        kind: "lifecycle (Organization & Access inverse association)",
        shapes: [ /\Ahas_one\s+:employee_insurance_profile,\s+dependent: :destroy\z/ ]
      },
      "app/services/payroll/entry_calculator.rb" => {
        kind: "read (Attendance & Payroll snapshots the profile onto the payroll entry — the allowed direction)",
        shapes: [ /\Aprofile = @user\.employee_insurance_profile\z/ ]
      }
    }.freeze

    # A write to the profile.
    PROFILE_WRITE = /
      \bEmployeeInsuranceProfile\.(?:create|new|insert|upsert|update|delete|destroy|find_or_create_by|find_or_initialize_by)
      | \bemployee_insurance_profile&?\.(?:update|save|destroy|delete|assign_attributes|toggle|touch|increment|decrement)
      | \bemployee_insurance_profiles?&?\.(?:create|build|new|update|delete|destroy|insert|upsert)
      | \bbuild_employee_insurance_profile\b
      | \bemployee_insurance_profile\s*=(?![=~>])
    /x

    # Ambiguous receiver (the read assigns the profile to `profile`): a write
    # counts only in a file that names the insurance profile (elsewhere
    # `profile` is e.g. a salary or shift-rule profile).
    CONTEXTUAL_PROFILE_WRITE = /\bprofile&?\.(?:update|save|destroy|delete|assign_attributes|toggle|touch|increment|decrement)/

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    def workforce_files
      dirs = WORKFORCE_DIRS.flat_map { |dir| source_files(dir.chomp("/")) }
      (WORKFORCE_FILES.keys + dirs).uniq.sort
    end

    def workforce?(path) = workforce_files.include?(path) || path == EMPLOYEE_PAGE

    # Full-line Ruby comments, ERB comments (including multi-line) and t(...)
    # i18n keys are ignored.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/\b(?:I18n\.)?t\(\s*(["'])[^"']*\1/, 't("KEY"'), number ] }
    end

    def matches_in(path, pattern, lines = code_lines(path))
      lines.filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    # The Social Insurance section of the employee page (line numbers kept).
    def card_lines
      raw    = File.read(Rails.root.join(EMPLOYEE_PAGE)).lines
      start  = raw.index { |line| line.match?(CARD_SECTION) } or return []
      finish = raw.each_index.find { |i| i > start && raw[i].include?("<%#") } || raw.size
      numbers = (start + 2)..finish # 1-based, after the marker line
      code_lines(EMPLOYEE_PAGE).select { |_, number| numbers.cover?(number) }
    end

    def workforce_violations
      workforce_files.flat_map { |path| matches_in(path, FORBIDDEN_IN_WORKFORCE) } +
        matches_in(EMPLOYEE_PAGE, FORBIDDEN_IN_WORKFORCE, card_lines)
    end

    def profile_writes(path)
      found = matches_in(path, PROFILE_WRITE)
      found |= matches_in(path, CONTEXTUAL_PROFILE_WRITE) if matches_in(path, PROFILE).any?
      found
    end

    def profile_violations(path)
      shapes = EXCEPTIONS.dig(path, :shapes) || []
      code_lines(path).filter_map do |line, number|
        next unless line.match?(PROFILE)
        next if shapes.any? { |shape| line.strip.match?(shape) }

        "#{path}:#{number}: #{line.strip}"
      end
    end
  end
end

RSpec.describe "Architecture: Workforce employee insurance profile boundary" do
  boundary = ArchitectureSpecs::WorkforceEmployeeInsuranceProfileBoundary

  it "1. Workforce insurance-profile code names nothing from Attendance & Payroll (the contract is the way through)" do
    violations = boundary.workforce_violations
    expect(violations).to be_empty, <<~MSG
      Workforce insurance-profile code must reach Attendance & Payroll only through #{boundary::CONTRACT}:
      #{violations.join("\n")}
      Add an operation to the contract (and its Attendance & Payroll implementation) instead.
    MSG
  end

  it "2. the two M3 callers use the contract, each for its own operation" do
    boundary::CALLERS.each do |path, operation|
      calls = boundary.matches_in(path, /\b#{Regexp.escape(boundary::CONTRACT)}\.\w+/)
      expect(calls.size).to eq(1), "#{path} should call #{boundary::CONTRACT} once:\n#{calls.join("\n")}"
      expect(calls.first).to include("#{boundary::CONTRACT}.#{operation}(")
    end
  end

  it "3. the Attendance & Payroll implementation is named only by the composition root" do
    namers = (boundary.source_files + boundary.source_files("config"))
             .reject { |path| path == boundary::IMPLEMENTATION_FILE }
             .flat_map { |path| boundary.matches_in(path, /\b#{Regexp.escape(boundary::IMPLEMENTATION)}\b/) }

    expect(namers.map { |line| line.split(":").first }).to eq([ boundary::COMPOSITION_ROOT ])
    expect(File.read(Rails.root.join(boundary::COMPOSITION_ROOT)))
      .to include("#{boundary::CONTRACT}.register(#{boundary::IMPLEMENTATION})")
  end

  it "4. outside Workforce the profile is named only by the OA lifecycle associations and the payroll snapshot read" do
    violations = boundary.source_files.reject { |path| boundary.workforce?(path) }
                         .flat_map { |path| boundary.profile_violations(path) }
    expect(violations).to be_empty, <<~MSG
      EmployeeInsuranceProfile is owned by Workforce; unexpected reference from another domain:
      #{violations.join("\n")}
      Classify a new exception in next-pilot-selection.md §23 (or go through Workforce).
    MSG
  end

  it "5. nothing outside Workforce writes the profile; the payroll read stays a read" do
    writes = boundary.source_files.reject { |path| boundary.workforce?(path) }
                     .flat_map { |path| boundary.profile_writes(path) }
    expect(writes).to be_empty, "Only Workforce may write EmployeeInsuranceProfile:\n#{writes.join("\n")}"
  end

  it "keeps the allow-lists tight (every file exists, every exception shape still matches, the card section is found)" do
    (boundary::WORKFORCE_FILES.keys + boundary::EXCEPTIONS.keys + [ boundary::IMPLEMENTATION_FILE, boundary::COMPOSITION_ROOT ])
      .each { |path| expect(File).to exist(Rails.root.join(path)), path }

    boundary::EXCEPTIONS.each do |path, exception|
      lines = boundary.code_lines(path).map { |line, _| line.strip }.grep(boundary::PROFILE)
      exception[:shapes].each { |shape| expect(lines.grep(shape)).not_to be_empty, "#{path}: unused shape #{shape.source}" }
    end

    card = boundary.card_lines.map(&:first).join
    expect(card).to include("EmployeeInsuranceProfile", "insurance_profile.employee_contribution_amount")
    expect(card).not_to include("Shift Timeline")
    expect(boundary.workforce_files).to include("app/views/admin/employee_insurance_profiles/edit.html.erb")
  end

  it "the Organization & Access associations stay lifecycle associations only" do
    expect(Business.reflect_on_association(:employee_insurance_profiles))
      .to have_attributes(macro: :has_many, class_name: "EmployeeInsuranceProfile", options: { dependent: :destroy })
    expect(User.reflect_on_association(:employee_insurance_profile))
      .to have_attributes(macro: :has_one, class_name: "EmployeeInsuranceProfile", options: { dependent: :destroy })
  end

  describe "self-tests (planted probes)" do
    def plant(path, content)
      unless @reads_stubbed
        allow(File).to receive(:read).and_call_original
        @reads_stubbed = true
      end
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    updater = "app/services/employee/insurance_profile_updater.rb"
    controller = "app/controllers/admin/employee_insurance_profiles_controller.rb"

    {
      "Payroll::EntryRecalculator"      => "Payroll::EntryRecalculator.recalculate_all_open_periods_for(user: user, triggered_by: @actor)",
      "the contract implementation"     => "Payroll::InsuranceProfileEffects.profile_changed(user: user, actor: @actor)",
      "PayrollPeriod"                   => "periods = PayrollPeriod.where(id: ids)",
      "PayrollEntry"                    => "PayrollEntry.where(user: user).exists?",
      "a payroll_entries query"         => "ids = @employee.payroll_entries.select(:payroll_period_id)",
      "the locked? rule"                => "active = periods.reject(&:locked?)",
      "an Attendance:: service"         => "Attendance::RecordRecomputer.recompute!(record)"
    }.each do |label, code|
      it "catches #{label} planted in a Workforce caller" do
        [ updater, controller ].each do |path|
          plant(path, "#{code}\n")
          expect(boundary.matches_in(path, boundary::FORBIDDEN_IN_WORKFORCE)).not_to be_empty, path
        end
      end
    end

    it "catches a payroll query planted in the employee page's Social Insurance card, not elsewhere on the page" do
      page = File.read(Rails.root.join(boundary::EMPLOYEE_PAGE))
      probe = "  <%= @user.payroll_entries.count %>\n"
      plant(boundary::EMPLOYEE_PAGE, page.sub(/(<%#\s*Social Insurance\s*%>\n)/) { "#{Regexp.last_match(1)}#{probe}" })
      expect(boundary.workforce_violations).to include(a_string_including("@user.payroll_entries.count"))

      plant(boundary::EMPLOYEE_PAGE, page.sub(/(<%#\s*Salary Profiles\s*%>\n)/) { "#{Regexp.last_match(1)}#{probe}" })
      expect(boundary.workforce_violations).not_to include(a_string_including("@user.payroll_entries.count"))
    end

    it "allows the contract itself" do
      plant(updater, "Employee::InsuranceProfileEffects.profile_changed(user: user, actor: @actor)\n")
      plant(controller, "@payroll_insurance_notice = Employee::InsuranceProfileEffects.payroll_notice_for(user: @employee)\n")
      expect(boundary.matches_in(updater, boundary::FORBIDDEN_IN_WORKFORCE)).to be_empty
      expect(boundary.matches_in(controller, boundary::FORBIDDEN_IN_WORKFORCE)).to be_empty
    end

    it "catches a caller that bypasses or swaps the contract operation" do
      plant(controller, "@payroll_insurance_notice = Employee::InsuranceProfileEffects.profile_changed(user: @employee, actor: current_user)\n")
      calls = boundary.matches_in(controller, /\bEmployee::InsuranceProfileEffects\.\w+/)
      expect(calls.first).not_to include(".payroll_notice_for(")
    end

    it "catches the implementation named outside the composition root" do
      plant("app/services/finance/expense_approval.rb", "Payroll::InsuranceProfileEffects.payroll_notice_for(user: user)\n")
      expect(boundary.matches_in("app/services/finance/expense_approval.rb", /\bPayroll::InsuranceProfileEffects\b/)).not_to be_empty
    end

    it "catches a widened exception and a write from outside Workforce" do
      plant("app/models/user.rb", "has_one  :employee_insurance_profile, dependent: :destroy\nemployee_insurance_profile.update!(insured: false)\n" \
                                  "employee_insurance_profile&.destroy\n")
      expect(boundary.profile_violations("app/models/user.rb"))
        .to eq([ "app/models/user.rb:2: employee_insurance_profile.update!(insured: false)",
                 "app/models/user.rb:3: employee_insurance_profile&.destroy" ])
      expect(boundary.profile_writes("app/models/user.rb").size).to eq(2)

      plant("app/services/payroll/entry_calculator.rb", "profile = @user.employee_insurance_profile\nprofile.update!(insured: true)\n")
      expect(boundary.profile_violations("app/services/payroll/entry_calculator.rb")).to be_empty # the read line is allowed …
      expect(boundary.profile_writes("app/services/payroll/entry_calculator.rb"))
        .to eq([ "app/services/payroll/entry_calculator.rb:2: profile.update!(insured: true)" ]) # … the write is not
    end

    it "does not count `profile.save` in files that never name the insurance profile" do
      # Salary-profile writes live in Salary::ProfileCorrector (`profile.save!`).
      expect(boundary.profile_writes("app/services/salary/profile_corrector.rb")).to be_empty
      expect(boundary.matches_in("app/services/salary/profile_corrector.rb", boundary::CONTEXTUAL_PROFILE_WRITE)).not_to be_empty
    end

    it "catches a new reference to the profile from another domain" do
      plant("app/services/finance/expense_approval.rb", "insured = EmployeeInsuranceProfile.insured.count\n")
      expect(boundary.profile_violations("app/services/finance/expense_approval.rb")).not_to be_empty
    end

    it "does not flag harmless references: route helpers, i18n keys, comments, the notice variable" do
      plant(controller, "redirect_to admin_user_path(@employee), notice: t(\"flash.insurance_profile_updated\")\n" \
                        "# Payroll::EntryRecalculator used to be called here\n" \
                        "edit_admin_user_employee_insurance_profile_path(@employee)\n" \
                        "@payroll_insurance_notice != :none\n")
      expect(boundary.matches_in(controller, boundary::FORBIDDEN_IN_WORKFORCE)).to be_empty
    end
  end
end
