# API Conventions (`/api/v1`)

**Audience:** backend developers adding or migrating API endpoints.
**Companion docs:** `baseline.md` (current contract + known defects),
`authentication.md`, `openapi.yaml`.

The API is being prepared as the backend for future React Web and React Native
clients **without breaking the current Rails web app or existing API clients**.
Everything below is additive.

---

## 1. Two contracts

| | Legacy (default) | Standard (opt-in) |
|---|---|---|
| Enabled by | nothing — every existing endpoint | `standard_api_contract!` in the controller |
| Success | `{ success: true, data }` | `{ success: true, data, meta, request_id }` |
| Error | `{ success: false, message, errors }` | `{ success: false, error: { code, message, details }, request_id, message, errors }` |
| Unauthenticated | Devise body `{ "error": "…" }` | standard `unauthenticated` error |
| Unexpected exception | propagates (Rails decides) | `500 internal_error`, reported via `Rails.error`, no details leaked |
| Pagination | none | `paginate` / `paginate_if_requested` |

Endpoints currently on the standard contract: **`GET /api/v1/advances`,
`GET /api/v1/advances/:id`** (pilot).

**New endpoints must use the standard contract.** Existing endpoints stay
legacy until migrated through the checklist in §12.

## 2. Controller structure

```
ApplicationController (web)
└── Api::V1::BaseController          staff realm — Devise session, Pundit
    ├── includes ApiResponder          legacy render_success / render_error
    ├── includes Api::StandardResponses render_api_success / render_api_error / …
    ├── includes Api::ErrorHandling     legacy by default; standard_api_contract!
    ├── includes Api::Pagination        paginate / paginate_if_requested
    └── includes Api::RequestContext    request_id + actor ids → structured log
ActionController::API
└── Api::V1::BiometricBaseController  device realm — device token
```

Controllers stay thin: authorize → load through `policy_scope` → call a service →
render. No business logic in base classes or concerns.

## 3. Success envelope (standard)

```json
{
  "success": true,
  "data": { },
  "meta": { "pagination": { } },
  "request_id": "5f0c…"
}
```

`meta` is always present (`{}` when empty). `request_id` equals the
`X-Request-Id` response header.

## 4. Error envelope (standard)

```json
{
  "success": false,
  "error": { "code": "validation_failed", "message": "Validation failed.", "details": [
    { "field": "amount", "code": "greater_than", "message": "Amount must be greater than 0" }
  ] },
  "request_id": "5f0c…",
  "message": "Validation failed.",
  "errors": ["Amount must be greater than 0"]
}
```

`message` / `errors` at the top level duplicate the legacy shape so migrated
endpoints stay readable by legacy clients. They are **deprecated** and will be
removed only in a future API version.

| `error.code` | HTTP | Raised from |
|---|---|---|
| `bad_request` | 400 | `ActionController::ParameterMissing`, malformed JSON, `Api::Errors::BadRequest` (pagination/filter/sort/search) |
| `unauthenticated` | 401 | no valid session (`authenticate_user!`) |
| `forbidden` | 403 | `Pundit::NotAuthorizedError` |
| `not_found` | 404 | `ActiveRecord::RecordNotFound` — including records outside the caller's scope or business |
| `conflict` | 409 | `StaleObjectError`, `LockWaitTimeout`, `Deadlocked`, `RecordNotUnique` |
| `validation_failed` | 422 | `ActiveRecord::RecordInvalid`, `render_validation_errors(record)` |
| `business_rule_violation` | 422 | `render_service_failure(result)` for a failed service Result |
| `rate_limited` | 429 | `rate_limit … with: -> { render_rate_limited(retry_after:) }` (+ `Retry-After`) |
| `internal_error` | 500 | any other exception (details only in logs / error reporting) |

Messages are localized (`api.errors.*` in `config/locales/{en,ar}.yml`) using the
existing locale resolution (user → session → business → default).

Service results: services use two Result conventions (`ok?` and `success?`).
Use `service_result_ok?(result)` and `render_service_failure(result)`; do not
change the services.

## 5. Validation errors

`render_validation_errors(record)` → `422 validation_failed` with one
`details` entry per error: `field` (attribute), `code` (ActiveModel error type,
e.g. `blank`, `taken`, `greater_than`; `invalid` for custom messages) and the
localized full `message`.

## 6. Pagination

```ruby
records, pagination = paginate(scope)                 # always paginated (new endpoints)
records, pagination = paginate_if_requested(scope)    # legacy full-list endpoints
render_api_success(Serializer.many(records), meta: pagination ? { pagination: pagination } : {})
```

* Params: `page` (≥ 1, default 1), `per_page` (≥ 1, default 25, **capped at 100**).
* Non-integer or < 1 → `400 bad_request` (`details[0].field` = `page` / `per_page`).
* Meta: `page, per_page, total, total_pages, next_page, previous_page`
  (`next_page` / `previous_page` are `null` at the ends; past-the-end pages
  point `previous_page` at the last real page).
* **Never force pagination on an existing full-list endpoint** — use
  `paginate_if_requested` so old clients keep receiving the full list.

## 7. Filtering, sorting, search — `Api::ListQuery`

Declare one frozen `ListQuery` per endpoint and apply it to an **already
scoped** relation:

```ruby
LIST_QUERY = Api::ListQuery.new(
  filters: { status: { column: Advance.arel_table[:status], type: :enum, values: Advance.statuses.keys } },
  sorts:   { "issued_at" => Advance.arel_table[:issued_at] },
  default_sort: "-issued_at",
  tiebreaker:   Advance.arel_table[:id],
  search:  []   # Arel columns; the relation must already join their tables
)

LIST_QUERY.apply(policy_scope(Advance), params)
```

| Param | Syntax |
|---|---|
| Filter | `filter[status]=active`, arrays for equality: `filter[status][]=a&filter[status][]=b` |
| Sort | `sort=-issued_at,total_amount` (max 3 fields, `-` = descending; a stable `id` tiebreaker is always appended) |
| Search | `q=text` — case-insensitive `ILIKE %text%` over the configured columns, max 100 chars, `%`/`_` matched literally |

Filter types: `enum` (allowlisted values), `integer`, `date` (ISO-8601),
`boolean` (`true`/`false`), `string` (exact); operators `eq` (default), `gteq`,
`lteq`.

Security rules (enforced by `ListQuery`):

* **Allowlist only.** Unknown filter / sort field, bad value, search on an
  endpoint without search columns → `400 bad_request`. Nothing is silently
  ignored and nothing is interpolated into SQL (Arel + bound values).
* **Narrow, never widen.** `apply` only adds `WHERE` / `ORDER BY` to the
  relation it receives. Always pass `policy_scope(...)` or
  `current_business.<association>` — never `Model.all`.
* **No cross-business filtering.** Do not expose `business_id` as a filter. An
  `id`-type filter (e.g. `branch_id`) narrows inside the caller's scope only;
  it must never be used to *select* whose data is visible.
* No business rules in filters — only request-parameter plumbing.

## 8. Serialization

Use `Api::V1::BaseSerializer` subclasses in `app/serializers/api/v1/` for new
or migrated endpoints — no controller-private `*_json` helpers.

```ruby
class AdvanceSerializer < Api::V1::BaseSerializer
  attributes :id, :user_id, :total_amount, :remaining_amount, :status, :issued_at
  attribute(:repaid_amount) { record.repaid_amount }
end
AdvanceSerializer.many(advances, viewer: current_user)
```

* **Explicit allowlist only** — there is no "all attributes" mode. Credential /
  secret attributes (`encrypted_password`, `reset_password_token`, `token`, …)
  raise at class definition.
* **Never serialize:** password or token material; salary / payroll amounts
  unless the endpoint's policy already authorizes them for `viewer`; personal
  identifiers (national ID, ID photos) unless the endpoint exists for that
  purpose; anything outside the record set returned by `policy_scope`.
* Permission-dependent fields read `viewer` and existing policy/permission
  checks (`viewer.can?(…)`) — no new permission logic in serializers.
* Serializers never query; preload in the controller.
* When migrating a legacy endpoint the serializer must reproduce the legacy
  field set exactly (prove it with a spec comparing against the legacy hash).
* Types: decimals serialize as strings (Rails default — keep it); timestamps
  ISO-8601; business dates `YYYY-MM-DD`.

## 9. Authorization & tenant isolation

Reuse the existing Pundit policies and scopes — **no permission redesign**.

1. Every action calls `authorize` (instance for member actions, class for
   collection actions) **and** loads records via `policy_scope(Model)` or
   `current_business.<association>`.
2. Out-of-scope and other-business records → `404` (via `find` on the scoped
   relation), not 403.
3. **Never trust** `business_id`, `branch_id`, `user_id`, `employee_id` from
   params to decide *whose* data is read or written. The business comes from
   `current_user.business` (or `device.business`). An id in params that
   selects a related record (e.g. the employee an adjustment is for) must be
   resolved through a scoped relation (`policy_scope(User).find(id)`) before use.
4. Every new endpoint needs a cross-business spec (business A user → business B
   record → 404, and B's rows never appear in A's lists) and a
   permission-denied spec.

The violations found in the baseline (S1, S2 in `baseline.md`) are fixed and
covered by `spec/requests/api/v1/security/cross_business_authorization_spec.rb`.

## 10. Rate limiting

Rails 8 `rate_limit` with `store: Api::RateLimitStore` (delegates to
`Rails.cache` at call time — Solid Cache in production; the null store in the
test env disables limits unless a spec swaps in a real store).

| Endpoint | Limit | Key |
|---|---|---|
| `POST /api/v1/auth/login` | 10 / 5 min | IP + SHA-256 of the login identifier |
| `POST /api/v1/auth/login` | 60 / 1 min | IP (sized for a whole salon behind one Wi-Fi) |

Exceeding a limit → `429 rate_limited` + `Retry-After`.

Deliberately **not** limited yet (would risk normal salon operations):
`POST /api/v1/attendance/punch` (biometric devices batch-replay punches),
check-in/out at shift change. Candidates for later, with production traffic
data: payroll CSV export and payroll/attendance reports (expensive), per-user
global API throttles.

## 11. CORS

**No CORS is configured and none should be added for `/api/v1`.** The staff API
authenticates with the web session cookie; allowing cross-origin requests would
expose it to other sites. Future plan:

* React Web — served from the same origin (no CORS needed; dev uses a proxy).
* React Native — not a browser; CORS does not apply.
* Public APIs — a separate namespace with an explicit origin allowlist and no
  cookies, introduced only when such endpoints exist.

A characterization spec asserts no `Access-Control-*` headers are returned.

## 12. Migrating an existing endpoint to the standard contract

1. Characterization spec for the endpoint exists and passes (baseline).
2. Add `standard_api_contract!`; replace `render_success/render_error` with
   `render_api_success`, `render_validation_errors`, `render_service_failure`.
3. Replace the `*_json` helper with a serializer that reproduces the legacy
   field set exactly; add a spec comparing both.
4. Keep full-list behaviour (`paginate_if_requested`); add a `ListQuery` only
   with allowlisted fields.
5. Update `openapi.yaml` (`x-contract: standard`), and move the endpoint's
   characterization expectations from `expect_legacy_*` to `expect_standard_*`
   — the field-level expectations must remain unchanged.
6. Record the change (success adds `meta`/`request_id`; errors add `error`/
   `request_id`; unauthenticated body changes from Devise's) in the release notes.

## 13. Idempotency (inventory only — not implemented)

No existing API endpoint implements idempotency. The following write
operations will need an `Idempotency-Key` contract before mobile clients use
them with retries:

| Operation | Exposed in API today? | Existing protection |
|---|---|---|
| Biometric punch (`POST /attendance/punch`) | yes | spam window in `Attendance::PunchService` (duplicate punches become `rejected_spam`) |
| Mobile check-in / check-out | yes | "already checked in" business rule |
| Employee request create / approve / pay / cancel | yes (pay route unimplemented) | status transitions |
| Payroll `mark_paid`, `finalize`, `approve_all_pending` | yes | status transitions |
| Payroll adjustment create | yes | none |
| Till deposits / refunds | no (web only) | `idempotency_key` column + unique partial index |
| Expense creation / expense payments | no | none |
| Custody transactions, financial settlements | no | none |
| Inventory movements (receipts, issues, transfers, adjustments) | no | purchase requests: `idempotency_key` + unique index |

Planned approach: accept `Idempotency-Key` on POST/PATCH for these operations;
map it onto the existing `idempotency_key` columns where they exist, and add a
generic stored-response table for the rest (requires a migration — later phase).

## 14. Request tracing & logging

* Every response carries `X-Request-Id` (Rails; a client-supplied
  `X-Request-Id` is honoured). Standard envelopes repeat it as `request_id`.
* `config/initializers/api_request_logging.rb` writes **one JSON line per
  API request**: `event, request_id, method, path (no query string),
  controller, action, status, duration_ms, db_ms, user_id | device_id,
  business_id, error_class`.
* Never logged: params, bodies, headers, tokens, passwords, personal data.
  `config/initializers/filter_parameter_logging.rb` additionally filters
  `login`, `phone*`, `identity_card*`, `national_id*`, `authorization`.

## 15. Documentation & tests

* `docs/api/openapi.yaml` documents **only implemented** endpoints;
  `spec/docs/openapi_spec.rb` fails when routes and docs drift.
* Characterization specs: `spec/requests/api/v1/characterization/` — change
  them only when a contract change is intended and documented.
* Standard-contract specs: `spec/requests/api/v1/standard_contract/`.
* Helpers: `spec/support/api_characterization_helpers.rb`
  (`expect_legacy_success`, `expect_standard_error`, `api_user_with`, …).
