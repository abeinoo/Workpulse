require "rails_helper"

# Server-side guards on adjustment review (approve / reject), for BOTH entry
# points — the standalone AdjustmentsController and the review-time
# PayrollAdjustmentsController:
#
#   * only pending_review → approved | rejected is a valid transition;
#   * a finalized or paid payroll period freezes every adjustment in it —
#     including a standalone adjustment (no payroll_period_id) whose month's
#     period is locked;
#   * a refused request leaves review status, line items and entry totals
#     untouched;
#   * approval + materialisation into the payroll entry is atomic.
RSpec.describe "Payroll adjustment review guards", type: :request do
  let(:business) { create(:business) }
  let(:manager)  { create(:user, :branch_manager, business: business) }
  let(:approver) { create(:user, :accountant, business: business) }
  let(:employee) { create(:user, business: business) }

  def entry_for(period)
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, net_salary: 5_000.0,
           total_bonuses: 0.0, total_deductions: 0.0)
  end

  # A pending adjustment can no longer be CREATED in a finalized/paid period;
  # those rows are legacy state, built approved and set back to pending.
  def adjustment_in(period, status:, linked: true)
    legacy = status.to_s == "pending_review" && period.locked?
    adj = create(:payroll_adjustment, :cash_incentive,
                 payroll_period: linked ? period : nil, business: business,
                 period_month: period.period_month, period_year: period.period_year,
                 user: employee, created_by: manager, review_status: legacy ? :approved : status)
    adj.update_column(:review_status, "pending_review") if legacy
    adj
  end

  # Mirrors what the review-time flow writes: a line item tracking the
  # adjustment's status, counted in totals only once approved.
  def line_item_for(entry, adjustment)
    li = create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
                amount: adjustment.signed_amount, source_type: "PayrollAdjustment",
                source_id: adjustment.id, review_status: adjustment.review_status)
    entry.recalculate_totals!
    li
  end

  def snapshot(adjustment, entry)
    adjustment.reload
    entry.reload
    {
      review_status: adjustment.review_status,
      approved_by:   adjustment.approved_by_id,
      rejected_by:   adjustment.rejected_by_id,
      reviewed_at:   adjustment.reviewed_at,
      line_items:    entry.payroll_line_items.reload.map { |li| [ li.id, li.review_status, li.amount ] },
      net_salary:    entry.net_salary,
      total_bonuses: entry.total_bonuses
    }
  end

  before { sign_in approver }

  describe "review-time PayrollAdjustmentsController" do
    %i[finalized paid].each do |status|
      context "when the period is #{status}" do
        let(:period) { create(:payroll_period, status, business: business) }
        let!(:entry) { entry_for(period) }

        it "refuses to approve a pending adjustment and changes nothing" do
          adj = adjustment_in(period, status: :pending_review)
          line_item_for(entry, adj)
          before = snapshot(adj, entry)

          expect {
            patch approve_payroll_period_payroll_adjustment_path(period, adj)
          }.not_to change(PayrollAuditLog, :count)

          expect(snapshot(adj, entry)).to eq(before)
        end

        it "refuses to reject an already-approved adjustment and keeps totals" do
          adj = adjustment_in(period, status: :approved)
          line_item_for(entry, adj)
          before = snapshot(adj, entry)
          expect(before[:net_salary]).to eq(5_500.0)

          patch reject_payroll_period_payroll_adjustment_path(period, adj)

          expect(snapshot(adj, entry)).to eq(before)
        end
      end
    end

    context "when the period is open" do
      let(:period) { create(:payroll_period, business: business, status: "under_review") }
      let!(:entry) { entry_for(period) }

      it "approves a pending adjustment, its line item and totals together" do
        adj = adjustment_in(period, status: :pending_review)
        line_item_for(entry, adj)

        patch approve_payroll_period_payroll_adjustment_path(period, adj)

        expect(adj.reload.review_status).to eq("approved")
        expect(adj.approved_by).to eq(approver)
        expect(entry.reload.net_salary).to eq(5_500.0)
        expect(PayrollAuditLog.where(action_type: "adjustment_approved").count).to eq(1)
      end

      it "refuses to reject an adjustment that is already approved" do
        adj = adjustment_in(period, status: :approved)
        line_item_for(entry, adj)
        before = snapshot(adj, entry)

        patch reject_payroll_period_payroll_adjustment_path(period, adj)

        expect(snapshot(adj, entry)).to eq(before)
      end

      it "refuses to approve an adjustment that is already rejected" do
        adj = adjustment_in(period, status: :rejected)
        line_item_for(entry, adj)
        before = snapshot(adj, entry)

        patch approve_payroll_period_payroll_adjustment_path(period, adj)

        expect(snapshot(adj, entry)).to eq(before)
      end

      it "refuses to let the creator review their own adjustment" do
        adj = adjustment_in(period, status: :pending_review)
        line_item_for(entry, adj)
        before = snapshot(adj, entry)

        sign_in manager
        patch approve_payroll_period_payroll_adjustment_path(period, adj)

        expect(snapshot(adj, entry)).to eq(before)
      end

      it "refuses a user without approve_adjustments" do
        adj = adjustment_in(period, status: :pending_review)
        line_item_for(entry, adj)
        before = snapshot(adj, entry)

        sign_in employee
        patch reject_payroll_period_payroll_adjustment_path(period, adj)

        expect(snapshot(adj, entry)).to eq(before)
      end

      it "does not resolve an adjustment through another period's URL (audit log names the right period)" do
        other_period = create(:payroll_period, business: business, status: "under_review",
                              period_year: period.period_year + 1)
        adj = adjustment_in(period, status: :pending_review)
        line_item_for(entry, adj)
        before = snapshot(adj, entry)

        expect {
          patch approve_payroll_period_payroll_adjustment_path(other_period, adj)
        }.not_to change(PayrollAuditLog, :count)

        expect(response).to have_http_status(:not_found)
        expect(snapshot(adj, entry)).to eq(before)
      end

      it "rolls the status change back when total recalculation fails" do
        adj = adjustment_in(period, status: :pending_review)
        line_item_for(entry, adj)
        before = snapshot(adj, entry)

        allow_any_instance_of(PayrollEntry).to receive(:recalculate_totals!)
          .and_raise(ActiveRecord::RecordInvalid.new(PayrollEntry.new))

        patch approve_payroll_period_payroll_adjustment_path(period, adj)

        expect(snapshot(adj, entry)).to eq(before)
      end
    end
  end

  describe "standalone AdjustmentsController" do
    %i[finalized paid].each do |status|
      context "when the adjustment's month is #{status}" do
        let(:period) { create(:payroll_period, status, business: business) }
        let!(:entry) { entry_for(period) }

        it "refuses to approve a pending standalone adjustment (no payroll_period_id)" do
          # Submitted while the month was still open; payroll was closed afterwards.
          period.update_column(:status, "draft")
          adj = adjustment_in(period, status: :pending_review, linked: false)
          period.update_column(:status, status.to_s)
          before = snapshot(adj, entry)

          patch approve_adjustment_path(adj)

          expect(snapshot(adj, entry)).to eq(before)
          expect(entry.payroll_line_items.where(source_id: adj.id)).to be_empty
        end

        it "refuses to reject a pending linked adjustment" do
          adj = adjustment_in(period, status: :pending_review)
          before = snapshot(adj, entry)

          patch reject_adjustment_path(adj)

          expect(snapshot(adj, entry)).to eq(before)
        end
      end
    end

    describe "GET /adjustments (bulk selection, preloaded :payroll_period)" do
      it "offers a review checkbox only for pending rows in an open period" do
        open_period   = create(:payroll_period, business: business, status: "draft")
        closed_period = create(:payroll_period, :finalized, business: business,
                               period_year: open_period.period_year + 1)
        open_adj   = adjustment_in(open_period, status: :pending_review)
        closed_adj = adjustment_in(closed_period, status: :pending_review)

        get adjustments_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(class="bulk-check-row" value="#{open_adj.id}"))
        expect(response.body).not_to include(%(class="bulk-check-row" value="#{closed_adj.id}"))
      end
    end

    context "when the period is open" do
      let(:period) { create(:payroll_period, business: business, status: "draft") }
      let!(:entry) { entry_for(period) }

      it "refuses to reject an already-approved adjustment" do
        adj = adjustment_in(period, status: :approved)
        line_item_for(entry, adj)
        before = snapshot(adj, entry)

        patch reject_adjustment_path(adj)

        expect(snapshot(adj, entry)).to eq(before)
      end

      it "refuses to re-approve an approved adjustment (approval audit fields kept)" do
        other = create(:user, :super_admin, business: business)
        adj   = adjustment_in(period, status: :approved)
        adj.update_columns(approved_by_id: other.id, approved_at: 2.days.ago)
        before = snapshot(adj, entry)

        patch approve_adjustment_path(adj)

        expect(snapshot(adj, entry)).to eq(before)
      end

      it "leaves the adjustment pending when materialising into the entry fails" do
        adj = adjustment_in(period, status: :pending_review)

        allow_any_instance_of(PayrollEntry).to receive(:recalculate_totals!)
          .and_raise(ActiveRecord::RecordInvalid.new(PayrollEntry.new))

        patch approve_adjustment_path(adj)

        expect(adj.reload.review_status).to eq("pending_review")
        expect(adj.approved_by).to be_nil
        expect(entry.reload.payroll_line_items.where(source_id: adj.id)).to be_empty
        expect(entry.net_salary).to eq(5_000.0)
      end
    end
  end
end
