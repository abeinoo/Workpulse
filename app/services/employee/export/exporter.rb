module Employee
  module Export
    # Employee Data Export (admin/users#export): a CSV or Excel file of the
    # chosen fields for the employees the actor sees on the Employees page.
    #
    # * Rows: UserPolicy::Scope — the page's own scope, so business and
    #   employee-scope isolation are the page's — narrowed by status (active /
    #   inactive / all), in the page's name order.
    # * Fields: FieldCatalog.resolve! — a request naming any unknown or
    #   unpermitted field is refused as a whole; nothing is dropped silently.
    # * Audit: one "export_employees" entry on the business with the format,
    #   field keys, status and counts — never employee data. Written fail-closed
    #   (log_audit!) in the same transaction as the per-employee salary views of
    #   Employee::ExportColumns: without the audit entry there is no file, and
    #   no salary view is recorded for a file that was never handed out.
    # Read-only otherwise: no employee record is changed.
    class Exporter
      include AuditLoggable

      Result   = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }
      Download = Struct.new(:data, :filename, :content_type, :row_count, keyword_init: true)

      RENDERERS    = { "csv" => CsvRenderer, "xlsx" => XlsxRenderer }.freeze
      STATUSES     = %w[active inactive all].freeze
      AUDIT_ACTION = "export_employees".freeze

      def initialize(actor_id:, field_keys:, format:, status:, batch_size: Rows::BATCH_SIZE)
        @actor_id   = actor_id
        @field_keys = field_keys
        @format     = format.to_s
        @status     = status.to_s
        @batch_size = batch_size
      end

      def call
        actor = User.find(@actor_id)
        raise Refused, "not_authorized" unless UserPolicy.new(actor, User).export?

        renderer = RENDERERS[@format] || raise(Refused, "invalid_format")
        raise Refused, "invalid_status" unless STATUSES.include?(@status)

        fields = FieldCatalog.resolve!(actor, @field_keys)

        ApplicationRecord.transaction do
          ids  = employee_ids(actor)
          rows = Rows.new(viewer: actor, fields: fields, employee_ids: ids, batch_size: @batch_size)
          data = renderer.render(fields, rows)

          log_audit!(actor: actor, auditable: actor.business, action: AUDIT_ACTION,
                     metadata: audit_metadata(fields, ids.size, rows))

          Result.new(ok: true, record: Download.new(data: data, filename: filename(actor, renderer),
                                                    content_type: renderer::CONTENT_TYPE, row_count: ids.size))
        end
      rescue Refused => e
        Result.new(ok: false, error: e.message)
      rescue AuditLoggable::AuditWriteFailed
        Result.new(ok: false, error: "audit_failed")
      end

      private

      def employee_ids(actor)
        scope = UserPolicy::Scope.new(actor, User).resolve.where(business_id: actor.business_id)
        scope = scope.where(active: true)  if @status == "active"
        scope = scope.where(active: false) if @status == "inactive"
        scope.order(:first_name, :last_name, :id).pluck(:id)
      end

      # Field keys, counts and request parameters only — never employee data.
      def audit_metadata(fields, row_count, rows)
        keys = fields.map(&:key)
        {
          format:    @format,
          status:    @status,
          fields:    keys,
          row_count: row_count,
          locale:    I18n.locale.to_s
        }.tap do |metadata|
          metadata[:rows_without_salary]    = rows.rows_without_salary if keys.intersect?(Rows::SALARY_FIELDS)
          metadata[:rows_without_insurance] = rows.rows_without_insurance if keys.intersect?(Rows::INSURANCE_FIELDS)
        end
      end

      def filename(actor, renderer)
        zone = actor.business.timezone_object || Time.zone
        "employees_#{Time.current.in_time_zone(zone).strftime('%Y%m%d_%H%M')}.#{renderer::EXTENSION}"
      end
    end
  end
end
