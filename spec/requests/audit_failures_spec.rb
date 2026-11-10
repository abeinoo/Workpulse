require "rails_helper"

# R3.1 business audit-failure dashboard and sidebar badge (§6.8, G2, D30, D32).
RSpec.describe "Audit failures dashboard", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  def user_with(permissions, in_business: business)
    role = create(:permission_role, business: in_business, permissions: permissions)
    create(:user, business: in_business, permission_role: role)
  end

  let(:monitor)  { user_with(%w[monitor_audit_failures]) }
  let(:outsider) { user_with(%w[manage_roles view_employees]) }

  let(:secret_payload) do
    { "changes" => { "base_salary" => [ "4111.25", "5999.75" ] }, "metadata" => { "reason" => "SECRET-PERSONAL-NOTE" } }
  end

  def event_for(in_business, **attrs)
    create(:pending_audit_event, actor: create(:user, business: in_business), payload: secret_payload, **attrs)
  end

  let!(:pending)   { event_for(business) }
  let!(:escalated) do
    event_for(business, attempts: 3, consecutive_failures: 3, escalated_at: 1.hour.ago, last_error: "ActiveRecord::InvalidForeignKey",
                        last_error_details: { "sqlstate" => "23503", "constraint" => "fk_rails_audit" })
  end
  let!(:foreign_escalated) { event_for(other, attempts: 3, consecutive_failures: 3, escalated_at: 1.hour.ago) }

  def badges = Nokogiri::HTML(response.body).css(".sidebar__nav-count")
  def badge  = (badges.sole if badges.any?)

  # The visible number is hidden from screen readers; they read the one
  # .sr-only label instead (no aria-label on the plain span).
  def visible_count(badge) = badge.css("[aria-hidden='true']").sole.text
  def spoken_label(badge)  = badge.css(".sr-only").sole.text

  describe "access" do
    it "is refused without monitor_audit_failures; an event page is not even found" do
      sign_in outsider
      get audit_failures_path
      expect(response).to redirect_to(root_path)

      get audit_failure_path(pending)
      expect(response).to have_http_status(:not_found)
    end

    it "is open to the owner without the permission" do
      owner = create(:user, business: business).tap { |u| business.update!(owner: u) }
      sign_in owner
      get audit_failures_path
      expect(response).to have_http_status(:ok)
    end

    it "returns not found for another business's event, even by direct id" do
      sign_in monitor
      get audit_failure_path(foreign_escalated)
      expect(response).to have_http_status(:not_found)
    end

    it "has no retry action for business users" do
      sign_in monitor
      post "/audit_failures/#{pending.id}/retry"
      expect(response).to have_http_status(:not_found)
      expect { put "/audit_failures/#{pending.id}" }.not_to change { pending.reload.attributes }
    end
  end

  describe "index" do
    before { sign_in monitor }

    it "lists only this business's unresolved events, with escalation, and counts them" do
      get audit_failures_path

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      rows = page.css("tbody tr")
      expect(rows.size).to eq(2)
      expect(response.body).to include(audit_failure_path(pending), audit_failure_path(escalated))
      expect(response.body).not_to include(audit_failure_path(foreign_escalated))
      expect(page.css(".stat-card__value").map(&:text)).to eq(%w[1 2 0])
      expect(response.body).to include(I18n.t("audit_failures.statuses.escalated"))
    end

    it "filters escalated events" do
      get audit_failures_path(status: "escalated")

      expect(Nokogiri::HTML(response.body).css("tbody tr").size).to eq(1)
      expect(response.body).to include(audit_failure_path(escalated))
    end

    it "never shows payload values" do
      get audit_failures_path
      expect(response.body).not_to include("SECRET-PERSONAL-NOTE", "4111.25", "5999.75")
    end

    it "renders in Arabic, right to left" do
      monitor.update!(preferred_locale: "ar")
      get audit_failures_path

      expect(response.body).to include('dir="rtl"', I18n.t("audit_failures.title", locale: :ar))
    end
  end

  describe "show" do
    before { sign_in monitor }

    it "dates every time with its year, since events are kept indefinitely (L9)" do
      travel_to(Time.zone.local(2026, 11, 8, 12, 0, 0)) do
        old = event_for(business, attempted_at: Time.zone.local(2025, 3, 4, 10, 30, 0))
        get audit_failure_path(old)
      end

      expect(response.body).to include("2025")
      monitor.update!(preferred_locale: "ar")
      get audit_failure_path(PendingAuditEvent.order(:id).last)
      expect(response.body).to include("2025")
    end

    it "shows operational information and the attempt history, never the payload" do
      PendingAuditEventAttempt.create!(pending_audit_event: escalated, business_id: business.id, kind: "automatic",
                                       started_at: 2.hours.ago, finished_at: 2.hours.ago, result: "failed",
                                       error_class: "ActiveRecord::InvalidForeignKey", error_details: { "sqlstate" => "23503" })

      get audit_failure_path(escalated)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ActiveRecord::InvalidForeignKey", "sqlstate: 23503", "fk_rails_audit",
                                       escalated.action, I18n.t("audit_failures.results.failed"))
      expect(response.body).not_to include("SECRET-PERSONAL-NOTE", "4111.25", "5999.75")
    end
  end

  describe "sidebar badge" do
    def owner = @owner ||= create(:user, business: business).tap { |u| business.update!(owner: u) }
    def page  = Nokogiri::HTML(response.body)
    def admin_group = page.at_css('details[data-sidebar-group-key-value="administration"]')

    it "counts this business's unresolved escalated events, once, on the link of a single-link section" do
      sign_in monitor
      get audit_failures_path

      expect(badges.size).to eq(1)
      expect(visible_count(badge)).to eq("1")
      expect(badge.ancestors("a").first["href"]).to eq(audit_failures_path)
      expect(spoken_label(badge)).to eq(I18n.t("nav.audit_failures_escalated", count: 1))
    end

    it "gives screen readers exactly one label and no aria-label on the plain span" do
      sign_in owner
      get audit_failures_path

      label = I18n.t("nav.audit_failures_escalated", count: 1)
      expect(badge["aria-label"]).to be_nil
      expect(page.css("[aria-label='#{label}']")).to be_empty
      expect(page.css(".sidebar .sr-only").count { |node| node.text == label }).to eq(1)
      expect(badge.css("[aria-hidden='true']").sole.text).to eq("1")
    end

    it "is shown once, on the heading, while the Administration group is collapsed" do
      sign_in owner
      get root_path
      follow_redirect! while response.redirect?

      expect(admin_group["open"]).to be_nil
      expect(badges.size).to eq(1)
      expect(visible_count(admin_group.at_css("summary .sidebar__nav-count"))).to eq("1")
    end

    it "is shown once, on the heading, while the Administration group is expanded" do
      sign_in owner
      get audit_failures_path

      expect(admin_group["open"]).not_to be_nil
      expect(badges.size).to eq(1)
      expect(visible_count(admin_group.at_css("summary .sidebar__nav-count"))).to eq("1")
      expect(spoken_label(admin_group.at_css("summary .sidebar__nav-count")))
        .to eq(I18n.t("nav.audit_failures_escalated", count: 1))
    end

    it "says the count in words, singular and plural (L9)" do
      expect(I18n.t("nav.audit_failures_escalated", count: 1)).to eq("1 escalated audit failure")
      expect(I18n.t("nav.audit_failures_escalated", count: 2)).to eq("2 escalated audit failures")
      expect(I18n.t("nav.audit_failures_escalated", count: 1, locale: :ar)).to eq("إخفاق تدقيق واحد مُصعَّد")
      expect(I18n.t("nav.audit_failures_escalated", count: 7, locale: :ar)).to include("7")
    end

    it "drops resolved events from the count" do
      log = AuditLog.create!(actor_id: escalated.actor_id, business_id: business.id, auditable_type: "User",
                             auditable_id: escalated.auditable_id, action: escalated.action)
      escalated.mark_delivered!(log, at: Time.current)
      sign_in monitor
      get audit_failures_path

      expect(badge).to be_nil
    end

    it "is not shown, nor the link, to a user without the permission" do
      sign_in outsider
      get root_path
      follow_redirect! while response.redirect?

      expect(badge).to be_nil
      expect(response.body).not_to include(audit_failures_path)
    end
  end
end
