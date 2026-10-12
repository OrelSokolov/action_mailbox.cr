# action_mailbox.cr

A 1:1 Crystal port of **actionmailbox 8.1.4** (the Rails inbound email
component) — receive raw RFC822 messages, store them as `InboundEmail`
records with a `raw_email` Active Storage blob, route them to mailbox
classes via address rules, and track the processing lifecycle
(`pending → processing → delivered / failed / bounced`). Mailbox
classes are a compile-time registry (`macro inherited` + the `routing`
DSL), and incoming mail is parsed by a `Mail::Message.from_source`
reopen in the port itself. Suite: **29/29 oracle** cases captured from
the real gem (SQLite in-memory, Disk service, ActiveJob `:test`
adapter) and replayed without edits.

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  action_mailbox_cr:
    github: OrelSokolov/action_mailbox.cr
```

```sh
shards install
```

Depends on `active_record.cr`, `active_storage.cr` and
`action_mailer.cr`.

## Usage

```crystal
require "action_mailbox_cr"

class ApplicationMailbox < ActionMailbox::Base
  routing({/^replies@/i       => :replies,
           "help@example.com" => :help,
           :all               => :backstop})
end

class RepliesMailbox < ApplicationMailbox
  before_processing :check_sender   # halts the chain by bouncing

  def process
    inbound_email.mail.subject
    inbound_email.delivered!
  end

  def check_sender
    inbound_email.bounced! if mail.from.nil?
  end
end

email = ActionMailbox::InboundEmail.create_and_extract_message_id!(rfc822_source)
ActionMailbox.enqueued_jobs   # => ["ActionMailbox::RoutingJob"]
email.route                   # dispatch via ::ApplicationMailbox
email.reload.status           # => "delivered"
```

## Feature comparison vs actionmailbox 8.1.4

### InboundEmail model & storage

| Feature | Original (actionmailbox) | Port (action_mailbox.cr) | Status |
|---|---|---|---|
| `create_and_extract_message_id!` (checksum, Message-ID extraction, missing-ID generation `<checksum>@<hostname>.mail`) | ✅ | Same (SHA1 checksum) | ✅ |
| `has_one_attached :raw_email` | ✅ | Active Storage blob + attachment (`message.eml`, `message/rfc822`) | ✅ |
| Status enum `pending/processing/delivered/failed/bounced` | ✅ | Same, stored as the Rails integer enum (0..4) | ✅ |
| `#mail`, `#source`, `#processed?`, status predicates/bangers | ✅ | Same | ✅ |
| `InboundEmail < ActiveRecord::Base` | ✅ | Hand-rolled row class over `Base.connection` | ⚠️ partial |
| Incineration (`IncinerationJob`, `incinerate_after` 30 days) | ✅ | Not implemented (P1) | ❌ |

### Routing & mailbox lifecycle

| Feature | Original | Port (action_mailbox.cr) | Status |
|---|---|---|---|
| `routing address => :mailbox` — String (case-insensitive) / Regex / Proc / `:all` over `mail.recipients` | ✅ | Same | ✅ |
| `mailbox_for` (first matching route) | ✅ | Same | ✅ |
| `perform_processing`: `processing!` → `before_processing` → `process` → `delivered!`; exception → `failed!` | ✅ | Same | ✅ |
| `before_processing` halting via `bounced!` (`finished_processing?`) | ✅ | Same | ✅ |
| Unrouted email → `bounced!` + `RoutingError` | ✅ | Same | ✅ |
| `after_processing` / `around_processing` / `rescue_from` | ✅ | Not implemented (P1) | ❌ |
| `bounce_with` / `bounce_now_with` | ✅ | Not implemented (P1) | ❌ |

### Ingress & configuration

| Feature | Original | Port (action_mailbox.cr) | Status |
|---|---|---|---|
| `RoutingJob` (ActiveJob) | ✅ | In-memory `ActionMailbox.enqueued_jobs` register, `#route` dispatch | ⚠️ partial |
| HTTP ingress: `relay` (basic auth + ingress password), `postmark`, `sendgrid`, `mailgun`, `mandrill` | ✅ | Not implemented (P1) | ❌ |
| `config.action_mailbox.*` (`incinerate`, `queues`, `ingress`, `logger`) | ✅ | Not implemented (P1) | ❌ |

## Deviations & Crystal-specific notes

- Mailbox name → class resolution is a compile-time registry
  (`macro inherited` collects subclasses; the `routing` macro registers
  `:name → NameMailbox` and adds routes) — Ruby's runtime
  `constantize` is impossible in Crystal.
- `RoutingJob` is a register of enqueued job names instead of an
  ActiveJob integration; the oracle itself runs the gem under the
  ActiveJob `:test` adapter with `route` invoked explicitly.
- `InboundEmail` is a hand-rolled row class over `Base.connection`
  (same layout as `RichText` in action_text.cr) so status helpers stay
  overridable; the table matches the gem's migration (integer status,
  `message_id`, `message_checksum`).
- The reading side of `Mail::Message` (`from_source`: unfolded headers
  with downcased keys, to/cc/bcc address lists,
  `recipients = to + cc + bcc`, `message_id` without angle brackets)
  is a reopen of the `Mail::Message` built by action_mailer.cr.
- P1 (not yet ported): ingress controllers (`relay`/`postmark`/
  `sendgrid`/`mailgun`/`mandrill`), `bounce_with`/`bounce_now_with`,
  `IncinerationJob`/`incinerate_after`, `after`/`around_processing`.

Full list with rationale: `PLAN.md` (Russian).

## Testing

```sh
crystal spec          # needs a local PostgreSQL (AMB_TEST_URL, default
                      # postgres://root@/crails_as_test?host=/var/run/postgresql)
```

Oracle: 29 cases recorded with the real actionmailbox 8.1.4
(`oracle/cases.rb` → `oracle/expected.yml`; SQLite in-memory, Disk
service, ActiveJob `:test` adapter); `spec/oracle_spec.cr` replays them
1:1 without edits — 29/29.
