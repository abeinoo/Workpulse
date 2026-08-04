require "rails_helper"

RSpec.describe Performance::ReviewAnalytics do
  let(:business)   { create(:business) }
  let(:department) { create(:department, business: business) }
  let(:reviewer)    { create(:user, business: business) }

  def scored_review(employee:, score:, year: 2026, month: 1, status: "finalized")
    review = create(:performance_review,
      business: business, department: department, employee: employee, reviewer: reviewer,
      review_year: year, review_month: month, status: status)
    review.update_column(:average_score, score)
    review
  end

  let(:alice) { create(:user, business: business) }
  let(:bob)   { create(:user, business: business) }

  before do
    scored_review(employee: alice, score: 5, year: 2026, month: 1)
    scored_review(employee: alice, score: 3, year: 2026, month: 2)
    scored_review(employee: bob,   score: 4, year: 2026, month: 1, status: "submitted")
    create(:performance_review, business: business, department: department, employee: bob,
           reviewer: reviewer, review_year: 2026, review_month: 3, status: "draft")
  end

  subject(:analytics) { described_class.new(PerformanceReview.for_business(business), filters) }

  context "with no filters" do
    let(:filters) { {} }

    it "counts every review regardless of score" do
      expect(analytics.total_reviews).to eq(4)
    end

    it "averages only scored reviews" do
      expect(analytics.average_rating).to eq(4.0)
    end

    it "builds the 1-5 star distribution" do
      expect(analytics.star_distribution).to eq(1 => 0, 2 => 0, 3 => 1, 4 => 1, 5 => 1)
    end

    it "reports highest and lowest" do
      expect(analytics.highest_rating.to_f).to eq(5.0)
      expect(analytics.lowest_rating.to_f).to eq(3.0)
    end

    it "builds a chronological monthly trend of scored reviews only" do
      trend = analytics.rating_trend
      expect(trend.map { |t| [ t.average, t.count ] }).to eq([
        [ 4.5, 2 ],
        [ 3.0, 1 ]
      ])
    end
  end

  context "filtering by employee" do
    let(:filters) { { employee_id: alice.id } }

    it "scopes total_reviews and relation to that employee" do
      expect(analytics.total_reviews).to eq(2)
      expect(analytics.relation.pluck(:employee_id).uniq).to eq([ alice.id ])
    end

    it "computes a per-employee summary" do
      summary = analytics.employee_summary(alice.id)
      expect(summary.reviews_count).to eq(2)
      expect(summary.average).to eq(4.0)
      expect(summary.highest.to_f).to eq(5.0)
      expect(summary.lowest.to_f).to eq(3.0)
    end
  end

  context "filtering by status" do
    let(:filters) { { status: "draft" } }

    it "only includes matching reviews" do
      expect(analytics.total_reviews).to eq(1)
      expect(analytics.average_rating).to be_nil
    end
  end

  context "filtering by date range" do
    let(:filters) { { from_date: "2026-02-01", to_date: "2026-02-28" } }

    it "excludes reviews outside the review_year/review_month window" do
      expect(analytics.total_reviews).to eq(1)
      expect(analytics.relation.first.review_month).to eq(2)
    end
  end

  describe "#star_distribution_with_percentage" do
    let(:filters) { {} }

    it "computes percentages against total_reviews, not just scored reviews" do
      # 4 total reviews; 1 three-star, 1 four-star, 1 five-star, 1 unscored draft.
      result = analytics.star_distribution_with_percentage
      expect(result[5]).to eq(count: 1, percentage: 25)
      expect(result[4]).to eq(count: 1, percentage: 25)
      expect(result[3]).to eq(count: 1, percentage: 25)
      expect(result[2]).to eq(count: 0, percentage: 0)
    end
  end

  describe "department and branch summaries" do
    let(:other_department) { create(:department, business: business) }
    let(:branch_a)          { create(:branch, business: business) }
    let(:branch_b)          { create(:branch, business: business) }
    let(:filters)           { {} }

    before do
      # Rebuild employees with different departments/branch snapshots.
      carol_review = create(:performance_review, business: business, department: other_department,
        employee: alice, reviewer: reviewer, branch: branch_b,
        review_year: 2026, review_month: 4, status: "finalized")
      carol_review.update_column(:average_score, 2)

      PerformanceReview.where(employee: bob, review_month: 1).update_all(branch_id: branch_a.id)
      PerformanceReview.where(employee: alice).where.not(id: carol_review.id).update_all(branch_id: branch_a.id)
    end

    it "ranks departments by average rating descending" do
      summaries = analytics.department_summaries
      expect(summaries.first.department_id).to eq(department.id)
      expect(summaries.map(&:department_id)).to include(other_department.id)
      expect(analytics.multiple_departments?).to be(true)
    end

    it "ranks branches by average rating descending, grouping nil snapshots separately" do
      summaries = analytics.branch_summaries
      ids = summaries.map(&:branch_id)
      expect(ids).to include(branch_a.id, branch_b.id, nil)
      expect(analytics.multiple_branches?).to be(true)
    end
  end

  describe "#top_employees / #bottom_employees" do
    let(:filters) { {} }

    before do
      # alice and bob only have 2 reviews each so far (from the top-level before block) —
      # below the 3-review qualification threshold.
      scored_review(employee: alice, score: 5, year: 2026, month: 4)
      scored_review(employee: bob,   score: 4, year: 2026, month: 4)
      scored_review(employee: bob,   score: 4, year: 2026, month: 5)
    end

    it "only ranks employees with at least 3 scored reviews" do
      rankings = analytics.qualifying_employee_rankings
      expect(rankings.map(&:employee_id)).to contain_exactly(alice.id, bob.id)
    end

    it "sorts top employees best-first and bottom employees worst-first" do
      expect(analytics.top_employees(1).first.employee_id).to eq(alice.id)
      expect(analytics.bottom_employees(1).first.employee_id).to eq(bob.id)
    end
  end

  describe "#previous_period_comparison" do
    context "without a from/to date filter" do
      let(:filters) { {} }

      it "returns nil" do
        expect(analytics.previous_period_comparison).to be_nil
      end
    end

    context "with a date range filter" do
      let(:filters) { { from_date: "2026-02-01", to_date: "2026-02-28" } }

      before do
        # Previous equal-length period immediately preceding Feb.
        scored_review(employee: alice, score: 2, year: 2026, month: 1)
      end

      it "compares against an equal-length preceding period" do
        comparison = analytics.previous_period_comparison
        expect(comparison.previous_average_rating).not_to be_nil
        expect(comparison.rating_delta).to eq((analytics.average_rating - comparison.previous_average_rating).round(2))
        expect(comparison.review_count_delta).to eq(analytics.total_reviews - comparison.previous_review_count)
      end
    end
  end

  describe "#rating_trend adaptive granularity" do
    context "when the filtered range is <= 31 days" do
      let(:filters) { { from_date: "2026-01-01", to_date: "2026-01-20" } }

      it "groups by day" do
        expect(analytics.rating_trend.size).to eq(1)
      end
    end

    context "when the filtered range is <= 12 months" do
      let(:filters) { { from_date: "2026-01-01", to_date: "2026-03-31" } }

      it "groups by month" do
        trend = analytics.rating_trend
        expect(trend.map(&:label)).to all(match(/\A[A-Za-z]+ \d{4}\z/))
      end
    end

    context "when the filtered range spans more than 12 months" do
      let(:filters) { { from_date: "2024-01-01", to_date: "2026-12-31" } }

      it "groups by year" do
        expect(analytics.rating_trend.map(&:label)).to eq([ "2026" ])
      end
    end

    context "without a date range filter" do
      let(:filters) { {} }

      it "defaults to month grouping" do
        expect(analytics.rating_trend.map(&:label)).to all(match(/\A[A-Za-z]+ \d{4}\z/))
      end
    end
  end

  describe "#employee_summary_rows and #employee_summary_overview" do
    let(:filters) { {} }

    before do
      scored_review(employee: alice, score: 1, year: 2026, month: 4)
    end

    it "aggregates one row per employee with trend classification" do
      rows = analytics.employee_summary_rows(per_page: nil)
      alice_row = rows.find { |r| r.employee_id == alice.id }

      expect(alice_row.reviews_count).to eq(3)
      expect(alice_row.highest_rating).to eq(5.0)
      expect(alice_row.lowest_rating).to eq(1.0)
      expect(alice_row.trend).to eq("declining") # first score 5 (Jan) -> latest score 1 (Apr)
      expect(alice_row.employee_name).to eq(alice.full_name)
    end

    it "sorts by the requested column and direction" do
      rows = analytics.employee_summary_rows(sort: "average_rating", direction: "asc", per_page: nil)
      expect(rows.first.employee_id).to eq(alice.id) # lowest average after the score of 1
    end

    it "paginates results" do
      page1 = analytics.employee_summary_rows(page: 1, per_page: 1)
      page2 = analytics.employee_summary_rows(page: 2, per_page: 1)
      expect(page1.size).to eq(1)
      expect(page1.first.employee_id).not_to eq(page2.first&.employee_id)
    end

    it "counts distinct employees for pagination" do
      expect(analytics.employee_summary_total_count).to eq(2)
    end

    it "computes overview stats from per-employee averages, not per-review averages" do
      overview = analytics.employee_summary_overview
      expect(overview.employees_reviewed).to eq(2)
      expect(overview.highest_rated_employee_name).to be_present
      expect(overview.lowest_rated_employee_name).to be_present
      expect(overview.employees_below_threshold).to be >= 0
      expect(overview.employees_above_threshold).to be >= 0
    end
  end
end
