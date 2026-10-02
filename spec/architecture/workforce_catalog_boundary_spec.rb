require "rails_helper"

# Boundary enforcement for the Department + JobTitle pilot (Workforce, M6; see
# docs/architecture/next-pilot-selection.md, decisions D-WF1..D-WF6).
#
# Department and JobTitle are Workforce catalogues. Per D-WF3 there is NO
# Workforce boundary object: Workforce code uses them directly, and other
# domains must not reach their internals (the classes, their class methods, or
# the `departments` / `job_titles` collections and tables). Employee attributes
# on users (`user.department`, `department_id`, `users.job_title`) remain
# readable by any domain and are not guarded here.
#
# This spec fails on any NEW direct reference outside the allow-list below.
# Adding to the allow-list is an architectural decision: give the reason.
module ArchitectureSpecs
  module WorkforceCatalogBoundary
    module_function

    FORBIDDEN = /
      \bDepartment\b        # the model and its class methods (not DepartmentPolicy)
      | \bJobTitle\b        # the model and its class methods (not JobTitlePolicy)
      | \bdepartments\b     # the catalogue collection and table
      | \bjob_titles\b      # the catalogue collection and table
      # Performance evaluation group (Pilot 3): models, collections and tables
      | \b(?:PerformanceReview|PerformanceReviewScore|PerformanceObservation|EvaluationTemplate|EvaluationCriterion)\b
      | \b(?:performance_reviews|performance_review_scores|performance_observations|evaluation_templates|evaluation_criteria)\b
    /x

    # Workforce-owned code (module-boundaries.md §5): uses the catalogues directly.
    WORKFORCE_FILES = {
      "app/models/workforce/department.rb"                   => "the model itself (folder collapsed: top-level constant)",
      "app/models/workforce/job_title.rb"                    => "the model itself (folder collapsed: top-level constant)",
      "app/models/workforce/performance_review.rb"           => "Workforce Performance model (folder collapsed: top-level constant)",
      "app/models/workforce/performance_review_score.rb"     => "Workforce Performance model (folder collapsed: top-level constant)",
      "app/models/workforce/performance_observation.rb"      => "Workforce Performance model (folder collapsed: top-level constant)",
      "app/models/workforce/evaluation_template.rb"          => "Workforce Performance model (folder collapsed: top-level constant)",
      "app/models/workforce/evaluation_criterion.rb"         => "Workforce Performance model (folder collapsed: top-level constant)",
      "app/controllers/admin/departments_controller.rb"      => "Workforce catalogue administration",
      "app/controllers/admin/job_titles_controller.rb"       => "Workforce catalogue administration",
      "app/controllers/admin/evaluation_templates_controller.rb" => "Workforce Performance: templates are per department",
      "app/views/shared/_job_title_select.html.erb"          => "Workforce job-title dropdown (employee form, onboarding)"
    }.freeze

    WORKFORCE_DIRS = [
      "app/views/admin/departments/",                        # catalogue administration screens
      "app/views/admin/job_titles/",                         # catalogue administration screens
      "app/views/admin/evaluation_templates/",               # Workforce Performance
      "app/controllers/performance/",                        # Workforce Performance
      "app/views/performance/",                              # Workforce Performance screens
      "app/services/performance/"                            # Workforce Performance (analytics, exports)
    ].freeze

    # Cross-domain exceptions, each documented in next-pilot-selection.md (M0/M6).
    EXCEPTION_FILES = {
      "app/models/user.rb"                                   => "D-WF1 JobTitle validation; inverse has_many :performance_reviews / :performance_observations (employee)",
      "app/models/business.rb"                               => "D-WF6 inverse associations: departments, job_titles, evaluation_templates, performance_reviews, performance_observations",
      "app/views/admin/users/_form.html.erb"                 => "Employee-profile part of admin/users (Workforce-owned per module-boundaries §5, in an Organization & Access-shared file)",
      "app/controllers/admin/users_controller.rb"            => "Employee-profile performance tab (@user.performance_reviews), Workforce-owned part of admin/users",
      "app/views/admin/users/show.html.erb"                  => "Employee-profile performance tab rendering, Workforce-owned part of admin/users",
      "app/views/layouts/_sidebar.html.erb"                  => "UI shell: catalogue nav entries and policy(JobTitle).index?",
      "app/helpers/workspace_helper.rb"                      => "UI shell: Performance workspace navigation (controller names, nav keys)"
    }.freeze

    def allowed_files = WORKFORCE_FILES.merge(EXCEPTION_FILES)

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
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(FORBIDDEN) }
    end

    def allowed?(path)
      allowed_files.key?(path) || WORKFORCE_DIRS.any? { |dir| path.start_with?(dir) }
    end
  end
end

RSpec.describe "Architecture: Workforce Department/JobTitle/Performance boundary" do
  boundary = ArchitectureSpecs::WorkforceCatalogBoundary

  it "has no direct Department / JobTitle / Performance access outside Workforce and the documented exceptions" do
    violations = boundary.source_files.reject { |path| boundary.allowed?(path) }.flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Direct access to Workforce catalogue internals (Department / JobTitle) from outside Workforce:
      #{violations.join("\n")}
      Read employee attributes (user.department, user.job_title) instead, or document a new
      exception in next-pilot-selection.md and the allow-list.
    MSG
  end

  it "keeps the allow-list tight (every listed file still needs its entry)" do
    stale = boundary.allowed_files.keys.select { |path| !File.exist?(Rails.root.join(path)) || boundary.violations_in(path).empty? }
    expect(stale).to be_empty, "Remove from the allow-list: #{stale.join(', ')}"
  end

  it "detects catalogue access and leaves employee attributes and policies alone" do
    expect("Department.where(id: ids)").to match(boundary::FORBIDDEN)
    expect("JobTitle.options_for(business)").to match(boundary::FORBIDDEN)
    expect("current_user.business.departments.active").to match(boundary::FORBIDDEN)
    expect("business.job_titles.new").to match(boundary::FORBIDDEN)
    expect("PerformanceReview.where(employee: user)").to match(boundary::FORBIDDEN)
    expect("user.performance_observations.count").to match(boundary::FORBIDDEN)
    expect("authorize PerformanceReviewPolicy; performance_reviews_path").not_to match(boundary::FORBIDDEN)
    expect("user.department&.name").not_to match(boundary::FORBIDDEN)
    expect("includes(:department)").not_to match(boundary::FORBIDDEN)
    expect("user.job_title").not_to match(boundary::FORBIDDEN)
    expect("policy(DepartmentPolicy); authorize JobTitlePolicy").not_to match(boundary::FORBIDDEN)
    expect("admin_departments_path; edit_admin_job_title_path").not_to match(boundary::FORBIDDEN)
  end
end
