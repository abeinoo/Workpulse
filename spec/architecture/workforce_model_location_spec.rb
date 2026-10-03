require "rails_helper"

# Department + JobTitle pilot (M7) and Pilot 3 Performance group: the models live physically in Workforce
# (app/models/workforce/, a collapsed directory) but keep their top-level
# constants and tables (decisions D-WF2, D-WF4). Guards against an accidental
# un-collapse, namespace or table change.
RSpec.describe "Architecture: Workforce model location" do
  {
    Department => "departments", JobTitle => "job_titles",
    PerformanceReview => "performance_reviews", PerformanceReviewScore => "performance_review_scores",
    PerformanceObservation => "performance_observations", EvaluationTemplate => "evaluation_templates",
    EvaluationCriterion => "evaluation_criteria"
  }.each do |model, table|
    describe model.name do
      it "loads as a top-level constant from app/models/workforce/" do
        expect(model.name).to eq(model.name.demodulize) # resolving the constant also triggers the autoload
        path = Object.const_source_location(model.name).first
        expect(path).to eq(Rails.root.join("app/models/workforce/#{model.name.underscore}.rb").to_s)
      end

      it "keeps #{table} as its table" do
        expect(model.table_name).to eq(table)
      end

      it "is not namespaced under Workforce" do
        expect(defined?(::Workforce)).to be_nil.or(satisfy { !::Workforce.const_defined?(model.name, false) })
      end
    end
  end

  it "is the same class the User and Business associations resolve" do
    expect(User.reflect_on_association(:department).klass).to equal(Department)
    expect(Business.reflect_on_association(:departments).klass).to equal(Department)
    expect(Business.reflect_on_association(:job_titles).klass).to equal(JobTitle)
    expect(User.reflect_on_association(:performance_reviews).klass).to equal(PerformanceReview)
    expect(Business.reflect_on_association(:evaluation_templates).klass).to equal(EvaluationTemplate)
    expect(Department.reflect_on_association(:performance_reviews).klass).to equal(PerformanceReview)
  end
end
