# API Authentication Contract (current state)

**Status:** Documents the authentication behaviour that exists today. Nothing
here was changed by the API-foundation phase. Locked by
`spec/requests/api/v1/characterization/authentication_spec.rb` and
`biometric_punch_spec.rb`.

WorkPulse has two authentication realms on `/api/v1`.

## 1. Staff realm — Devise session cookie

Used by every `/api/v1` endpoint except `POST /api/v1/attendance/punch`.

| Aspect | Current behaviour |
|---|---|
| Mechanism | The **same Devise session cookie** the Rails web app uses. There are no API tokens, no refresh tokens and no JWT. |
| Login | `POST /api/v1/auth/login` with `{ "login": "<email or phone>", "password": "…" }` (JSON). The body is wrapped into `session` by Rails `wrap_parameters`; an explicit `{ "session": { … } }` also works. Email match is case-insensitive; phone is matched as normalized. |
| Login success | `200 { success: true, data: { id, first_name, last_name, email, phone_number, role, permissions, manages_area, manages_branch, business_id, self_service: {…}, checkin_branch_ids } }` and a `Set-Cookie` session cookie. `role` is `"owner"` or `"staff"`; `permissions` is the raw PermissionRole list (empty for staff with no role). |
| Login failure | `401 { success: false, message: "Invalid credentials", errors: [] }` — identical for wrong password, unknown login and inactive user (no user enumeration). |
| Missing credentials | `400` (Rails `ParameterMissing`, rendered by Rails, not the API envelope). |
| Logout | `DELETE /api/v1/auth/logout` → `200 { success: true, data: { message: "Logged out successfully" } }`. |
| Unauthenticated JSON request | `401 {"error": "You need to sign in or sign up before continuing."}` — Devise failure-app body, **not** the API envelope. |
| Unauthenticated non-JSON request | `302` redirect to `/users/sign_in` (Devise navigational format). Clients must send `Accept: application/json` / `Content-Type: application/json`. |
| Deactivated user with a live session | `401` on the next request (Devise `active_for_authentication?`). |
| CSRF | **Not verified** (`skip_before_action :verify_authenticity_token`). Mitigated only by the cookie's default `SameSite=Lax`. See "Known gaps". |
| Password reset | Not available via API (Devise password routes are skipped app-wide). |
| Rate limiting | `POST /api/v1/auth/login` is rate limited (added in this phase — see docs/api/conventions.md → "Rate limiting"). |
| Base class | `Api::V1::BaseController < ApplicationController` — therefore also subject to `allow_browser versions: :modern` (only affects clients that identify as an outdated *browser*; native HTTP clients are not blocked) and the business-timezone `around_action`. |

Standard-contract endpoints (see conventions) answer an unauthenticated request
with the standard envelope instead of the Devise body:
`401 { success: false, error: { code: "unauthenticated", … }, request_id, message, errors }`.
The deactivated-user case still goes through Devise's failure app.

## 2. Device realm — biometric device token

Used only by `POST /api/v1/attendance/punch`.

| Aspect | Current behaviour |
|---|---|
| Mechanism | Static per-device token: `Authorization: Bearer <token>` or `X-Device-Token: <token>`. |
| Lookup | `BiometricDevice.active.find_by(token:)` — tokens are stored in **plaintext**. |
| Business | Derived from the device (`device.business`), never from params. |
| Failure | `401 { success: false, message: "Invalid or missing device token", errors: [] }`. |
| Web session | Ignored — the base is `ActionController::API`; a signed-in cookie does not authenticate a punch. |

## Rules for new API work

* Do **not** read `business_id`, `branch_id`, `user_id` or `employee_id` from
  params to decide *whose* data is accessed. The business always comes from
  the authenticated principal (`current_user.business` / `device.business`);
  records are loaded through `policy_scope(...)` or `current_business.<assoc>`.
* Do not add a new authentication mechanism in controllers. Token
  authentication for React Native is a later phase (see below).

## Known gaps (documented, not changed in this phase)

1. **CSRF is skipped for cookie-authenticated API writes.** Planned: enforce CSRF
   for cookie-authenticated requests once mobile clients use bearer tokens
   (staged: log-only → browser requests → all cookie requests).
2. **No token authentication** for React Native. Planned design: opaque,
   DB-backed, hashed access + rotating refresh tokens via a Warden strategy,
   so existing controllers keep using `authenticate_user!` / `current_user`.
3. **Unauthenticated responses use the Devise body**, not the API envelope, on
   legacy endpoints.
4. **Device tokens are stored in plaintext.** Planned: store a digest.
5. **`ensure_active_user`** (inherited from ApplicationController) would answer an
   API request with an HTML redirect; in practice Devise rejects inactive users
   first, so this path is not reached.
