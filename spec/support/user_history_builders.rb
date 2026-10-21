# F-A5 — one minimal history row per User association that refuses the user's
# deletion (dependent: :restrict_with_error). Shared by the model and request
# specs of the deletion guard.
module UserHistoryBuilders
  # association name → builder (user) — the row it creates belongs to the user.
  USER_HISTORY = {
    payroll_entries:            ->(user) { FactoryBot.create(:payroll_entry, user: user, payroll_period: FactoryBot.create(:payroll_period, business: user.business)) },
    # The advance hangs off ANOTHER employee's request, so the advance is this user's only history row.
    advances:                   lambda do |user|
      other = FactoryBot.create(:user, business: user.business)
      FactoryBot.create(:advance, user: user,
                                  employee_request: FactoryBot.create(:employee_request, :salary_advance, :approved, user: other))
    end,
    employee_requests:          ->(user) { FactoryBot.create(:employee_request, user: user) },
    attendance_records:         ->(user) { FactoryBot.create(:attendance_record, user: user, business: user.business) },
    salary_profiles:            ->(user) { FactoryBot.create(:salary_profile, user: user) },
    employee_obligations:       ->(user) { FactoryBot.create(:employee_obligation, business: user.business, user: user) },
    employee_insurance_profile: ->(user) { FactoryBot.create(:employee_insurance_profile, user: user) },
    performance_reviews:        ->(user) { FactoryBot.create(:performance_review, business: user.business, employee: user) },
    performance_observations:   lambda do |user|
      department = FactoryBot.create(:department, business: user.business)
      user.update!(department: department) # an observation requires the employee's department
      template   = EvaluationTemplate.create!(business: user.business, department: department, name: "Template")
      criterion  = EvaluationCriterion.create!(evaluation_template: template, name: "Punctuality")
      PerformanceObservation.create!(business: user.business, evaluation_criterion: criterion, employee: user,
                                     observed_by: FactoryBot.create(:user, business: user.business),
                                     observation_type: "positive", observation_date: Date.current)
    end
  }.freeze

  def create_user_history(association, user) = USER_HISTORY.fetch(association).call(user)

  # The rows of that association's table owned by the user (counted directly,
  # so the count survives a refused destroy).
  def user_history_count(association, user)
    reflection = User.reflect_on_association(association)
    reflection.klass.unscoped.where(reflection.foreign_key => user.id).count
  end
end

RSpec.configure { |config| config.include UserHistoryBuilders }
