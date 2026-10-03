module Api
  # Offset pagination for API collections (see docs/api/conventions.md).
  #
  #   records, meta = paginate(policy_scope(Model).order(...))
  #   render_api_success(records.map { … }, meta: { pagination: meta })
  #
  # Query params: `page` (1-based, default 1) and `per_page` (default 25,
  # capped at 100). Malformed values raise Api::Errors::BadRequest.
  #
  # Legacy endpoints that historically returned full lists must NOT be
  # paginated by default — use `paginate_if_requested`, which leaves the
  # relation untouched unless the client sent `page` or `per_page`.
  module Pagination
    extend ActiveSupport::Concern

    DEFAULT_PER_PAGE = 25
    MAX_PER_PAGE     = 100

    private

    def paginate(relation, default_per_page: DEFAULT_PER_PAGE, max_per_page: MAX_PER_PAGE)
      page     = pagination_integer_param(:page, default: 1)
      per_page = [ pagination_integer_param(:per_page, default: default_per_page), max_per_page ].min

      total       = relation.unscope(:order, :select).count(:all)
      total_pages = (total.to_f / per_page).ceil

      records = relation.offset((page - 1) * per_page).limit(per_page)
      meta = {
        page:          page,
        per_page:      per_page,
        total:         total,
        total_pages:   total_pages,
        next_page:     page < total_pages ? page + 1 : nil,
        # Past-the-end pages point back to the last real page.
        previous_page: page > 1 ? [ page - 1, [ total_pages, 1 ].max ].min : nil
      }

      [ records, meta ]
    end

    # Returns [relation, nil] untouched when the client did not ask for
    # pagination, so an existing full-list contract is preserved.
    def paginate_if_requested(relation, **options)
      return [ relation, nil ] unless pagination_requested?

      paginate(relation, **options)
    end

    def pagination_requested?
      params.key?(:page) || params.key?(:per_page)
    end

    def pagination_integer_param(name, default:)
      raw = params[name]
      return default if raw.nil?

      value = Integer(raw.to_s, 10, exception: false)
      return value if value && value >= 1

      raise Api::Errors::BadRequest.new(
        I18n.t("api.errors.invalid_pagination"),
        details: [ { field: name.to_s, code: "invalid", message: I18n.t("api.errors.invalid_pagination") } ]
      )
    end
  end
end
