# "طلبات إضافة موظف" — requesters submit a new employee's data and ID photos;
# reviewers correct it; approvers approve / reject / send it back. Every action
# is authorized server-side by EmployeeDataRequestPolicy (one explicit
# permission per action) — the UI only hides what the policy already denies.
# Orchestration only: every state change goes through EmployeeDataRequests::*.
class EmployeeDataRequestsController < ApplicationController
  include ActiveStorage::Streaming

  before_action :authenticate_user!
  # HTML only — no JSON/XML representation of requests or their personal data.
  before_action :reject_data_formats
  before_action :set_request, only: %i[show edit update correct approve reject request_changes document]

  PER_PAGE = 25

  def index
    authorize EmployeeDataRequest
    base = policy_scope(EmployeeDataRequest)

    # Header counts reflect every visible request, not just the filtered page.
    @status_counts = base.group(:status).count
    @reviewer      = policy(EmployeeDataRequest).view_all?

    @filters = {
      status:          params[:status].presence_in(EmployeeDataRequest::STATUSES),
      submitted_by_id: params[:submitted_by_id].presence,
      date_from:       parse_date(params[:date_from]),
      date_to:         parse_date(params[:date_to])
    }
    @active_filters = @filters.values.any?(&:present?)

    scope = base.with_status(@filters[:status])
                .submitted_by_user(@filters[:submitted_by_id])
                .submitted_on_or_after(@filters[:date_from])
                .submitted_on_or_before(@filters[:date_to])

    @total_count = scope.count
    @total_pages = [ (@total_count.to_f / PER_PAGE).ceil, 1 ].max
    @page        = params[:page].to_i.clamp(1, @total_pages)
    @requests    = scope.includes(:latest_revision, :submitted_by, :reviewed_by)
                        .review_order
                        .offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

    @submitters = @reviewer ? User.where(id: base.select(:submitted_by_id)).order(:first_name, :last_name) : []
  end

  def new
    authorize EmployeeDataRequest, :create?
    @revision = EmployeeDataRequestRevision.new
  end

  def create
    authorize EmployeeDataRequest, :create?
    result = EmployeeDataRequests::Submitter.new(actor: current_user, params: revision_params).call

    if result.ok?
      redirect_to employee_data_request_path(result.record), notice: t("employee_data_requests.flash.submitted")
    else
      @revision = result.record
      flash.now[:alert] = result.error if result.error
      render :new, status: :unprocessable_entity
    end
  end

  def show
    authorize @request
    load_review_page
  end

  # Resubmission form (only after the reviewer requested changes).
  def edit
    authorize @request, :update?
    @current  = @request.revisions.last
    @revision = EmployeeDataRequestRevision.new(@current.data_attributes.merge(manager_notes: @current.manager_notes))
  end

  def update
    authorize @request
    result = EmployeeDataRequests::Resubmitter.new(request_id: @request.id, actor: current_user,
                                                   params: revision_params).call

    if result.ok?
      redirect_to employee_data_request_path(@request), notice: t("employee_data_requests.flash.resubmitted")
    elsif result.record.is_a?(EmployeeDataRequestRevision)
      @current  = @request.revisions.last
      @revision = result.record
      flash.now[:alert] = result.error if result.error
      render :edit, status: :unprocessable_entity
    else
      redirect_to employee_data_request_path(@request), alert: result.error
    end
  end

  # Saves the reviewer's corrections without deciding.
  def correct
    authorize @request
    respond_with_review EmployeeDataRequests::Reviewer.correct(request_id: @request.id, actor: current_user,
                                                               corrections: correction_params), :corrected
  end

  # Approves, applying any corrections from the review form in the same step.
  # Corrections additionally need reviewer rights — approval alone never lets
  # someone change the data.
  def approve
    authorize @request
    authorize @request, :correct? if correction_params.present?
    respond_with_review EmployeeDataRequests::Reviewer.approve(request_id: @request.id, actor: current_user,
                                                               note: params[:note],
                                                               corrections: correction_params), :approved
  end

  def reject
    authorize @request
    respond_with_decision EmployeeDataRequests::Reviewer.reject(request_id: @request.id, actor: current_user,
                                                                note: params[:note]), :rejected
  end

  def request_changes
    authorize @request
    respond_with_decision EmployeeDataRequests::Reviewer.request_changes(request_id: @request.id, actor: current_user,
                                                                         note: params[:note]), :changes_requested
  end

  # Streams an ID photo through this authorized action — never through a
  # public/signed Active Storage URL — with no caching by browsers or proxies.
  def document
    authorize @request, :document?
    revision   = params[:revision_id].present? ? @request.revisions.find(params[:revision_id]) : @request.revisions.last
    attachment = case params[:side]
    when "front" then revision.id_front
    when "back"  then revision.id_back
    end
    raise ActiveRecord::RecordNotFound unless attachment&.attached?

    response.headers["Cache-Control"]          = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    send_blob_stream attachment.blob, disposition: :inline
  end

  private

  # Scoped to the viewer's business; a request from another business is a 404.
  # Visibility inside the business is enforced by the policy on every action.
  def set_request
    @request = EmployeeDataRequest.where(business_id: current_user.business_id)
                                  .includes(:submitted_by, :reviewed_by, :employee,
                                            revisions: [ :submitted_by, { id_front_attachment: :blob,
                                                                           id_back_attachment: :blob } ],
                                            events: :actor)
                                  .find(params[:id])
  end

  def revision_params
    params.require(:employee_data_request)
          .permit(*EmployeeDataRequestRevision::DATA_FIELDS, :manager_notes, :id_front, :id_back)
  end

  # Reviewer corrections: data fields only — never notes or ID photos.
  def correction_params
    params.fetch(:employee_data_request, {}).permit(*EmployeeDataRequestRevision::DATA_FIELDS)
  end

  # Everything the review page renders. Reviewer-only data (verification
  # checks, the submitted-vs-corrected comparison, the correction form) is only
  # computed for reviewers — requesters never receive it.
  def load_review_page(correction: nil)
    @revisions = @request.revisions.to_a
    @current   = @revisions.last
    @events    = @request.events.to_a
    return unless policy(@request).review_details?

    @submitted = @revisions.reverse.find(&:submission?)
    @checks    = EmployeeDataRequests::VerificationChecks.for(@current, today: BusinessDay.current(context: current_user.business))
    @correction = correction || EmployeeDataRequestRevision.new(@current.data_attributes) if policy(@request).correct?
  end

  # Invalid corrections re-render the review page with the reviewer's input and
  # errors; any other failure redirects back with the message.
  def respond_with_review(result, key)
    if result.ok?
      redirect_to employee_data_request_path(@request), notice: t("employee_data_requests.flash.#{key}")
    elsif result.record.is_a?(EmployeeDataRequestRevision) && !policy(@request).correct?
      # An approver without reviewer rights can't fix the data here.
      redirect_to employee_data_request_path(@request),
                  alert: t("employee_data_requests.errors.needs_review", errors: result.record.errors.full_messages.to_sentence)
    elsif result.record.is_a?(EmployeeDataRequestRevision)
      @request.reload
      load_review_page(correction: result.record)
      flash.now[:alert] = t("employee_data_requests.flash.correction_invalid")
      render :show, status: :unprocessable_entity
    elsif correction_params.present? && @request.reload.pending_review?
      # e.g. approval refused (phone already used) — keep the reviewer's edits.
      load_review_page
      @correction = EmployeeDataRequestRevision.new(@current.data_attributes.merge(correction_params.to_h.symbolize_keys))
      flash.now[:alert] = result.error
      render :show, status: :unprocessable_entity
    else
      redirect_to employee_data_request_path(@request), alert: result.error
    end
  end

  def respond_with_decision(result, key)
    if result.ok?
      redirect_to employee_data_request_path(@request), notice: t("employee_data_requests.flash.#{key}")
    else
      redirect_to employee_data_request_path(@request), alert: result.error
    end
  end

  def reject_data_formats
    head :not_acceptable if request.format.json? || request.format.xml?
  end

  def parse_date(value)
    Date.iso8601(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end
end
