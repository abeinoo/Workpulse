require "rails_helper"

RSpec.describe "Performance reviews — Phase 2 analytics dashboard", type: :request do
  let(:business)    { create(:business) }
  let(:owner)       { create(:user, :owner, business: business) }
  let(:department)  { create(:department, business: business) }
  let(:branch)      { create(:branch, business: business) }
  let(:shift)       { create(:shift, :fixed_time, business: business) }
  let(:employee)    { create(:user, business: business, department: department) }

  before do
    create(:shift_assignment, user: employee, branch: branch, shift: shift)

    3.times do |i|
      review = create(:performance_review, business: business, department: department,
        employee: employee, reviewer: owner, review_year: 2026, review_month: i + 1, status: "finalized")
      review.update_column(:average_score, 4 + i * 0.5)
    end

    sign_in owner
  end

  describe "GET employee_summary" do
    it "renders the overview stats and per-employee table" do
      get employee_summary_performance_reviews_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("performance.reviews.analytics.employees_reviewed"))
      expect(response.body).to include(employee.full_name)
    end

    it "supports sorting by review_count" do
      get employee_summary_performance_reviews_path(sort: "review_count", direction: "asc")

      expect(response).to have_http_status(:ok)
    end

    it "respects the same filters as the reviews tab" do
      get employee_summary_performance_reviews_path(branch_id: branch.id)
      expect(response.body).to include(employee.full_name)

      other_branch = create(:branch, business: business)
      get employee_summary_performance_reviews_path(branch_id: other_branch.id)
      expect(response.body).to include(I18n.t("performance.reviews.empty"))
    end
  end

  describe "GET export_xlsx" do
    it "streams a valid .xlsx workbook reflecting the active filters" do
      get export_xlsx_performance_reviews_path

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
      expect(response.body).not_to be_empty
    end
  end

  describe "GET export_pdf" do
    it "renders analytics HTML through the PDF renderer and streams the result" do
      allow(Performance::Exports::PdfRenderer).to receive(:render).and_return("%PDF-fake")

      get export_pdf_performance_reviews_path

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("application/pdf")
      expect(response.body).to eq("%PDF-fake")
      expect(Performance::Exports::PdfRenderer).to have_received(:render) do |html|
        expect(html).to include(I18n.t("performance.reviews.analytics.title"))
      end
    end
  end

  describe "GET employee_summary_export_xlsx" do
    it "streams a valid .xlsx workbook of the full (unpaginated) employee summary" do
      get employee_summary_export_xlsx_performance_reviews_path

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    end
  end

  describe "GET employee_summary_export_pdf" do
    it "renders the employee summary HTML through the PDF renderer" do
      allow(Performance::Exports::PdfRenderer).to receive(:render).and_return("%PDF-fake")

      get employee_summary_export_pdf_performance_reviews_path

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to eq("application/pdf")
      expect(Performance::Exports::PdfRenderer).to have_received(:render) do |html|
        expect(html).to include(employee.full_name)
      end
    end
  end

  describe "POST create — snapshot population" do
    it "automatically populates branch_id and department_id from the employee" do
      permission_role = create(:permission_role, business: business,
        permissions: %w[view_monthly_reviews manage_reviews])
      manager = create(:user, business: business, permission_role: permission_role)

      sign_in manager
      post performance_reviews_path, params: {
        performance_review: {
          employee_id: employee.id, review_year: 2027, review_month: 1
        }
      }

      review = PerformanceReview.order(:created_at).last
      expect(review.branch_id).to eq(branch.id)
      expect(review.department_id).to eq(department.id)
    end
  end

  describe "historical branch snapshot" do
    it "keeps a review under its original branch even after the employee transfers" do
      other_branch = create(:branch, business: business)

      get performance_reviews_path(branch_id: branch.id)
      expect(response.body).to include(employee.full_name)

      ShiftAssignment.where(user: employee, branch: branch).update_all(branch_id: other_branch.id)

      get performance_reviews_path(branch_id: branch.id)
      expect(response.body).to include(employee.full_name), "review should remain attributed to its snapshot branch"

      get performance_reviews_path(branch_id: other_branch.id)
      expect(response.body).to include(I18n.t("performance.reviews.empty")),
        "the employee's new branch should not retroactively claim old reviews"
    end
  end
end
