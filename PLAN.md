# action_mailbox.cr — порт ActionMailbox

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

Неймспейс: `ActionMailbox` — 1:1. Оценка: ~85%. Крошечный гем — тонкая
обёртка над Mailer/Storage/Job; берёмся последним из основных.

## API 1:1

- `class ApplicationMailbox < ActionMailbox::Base`:
  `routing address => :mailbox` — address: String / Regex / Proc / :all
- `class RepliesMailbox < ApplicationMailbox; before_processing;
  def process; ...; end` (+ `after/around_processing`, `rescue_from`)
- Инстанс: `inbound_email`, `mail` (Mail::Message),
  `bounce_with(message)` / `bounce_now_with(message)`
- `ActionMailbox::InboundEmail < ActiveRecord::Base`:
  `has_one_attached :raw_email`, enum статусов
  `pending/processing/delivered/failed/bounced`, `#mail`, `#source`,
  `#processed?`; incinerate-джоба (`incinerate_after` 30 дней)
- Ingress HTTP-эндпоинты: `relay` (basic auth + ingress password),
  `postmark/sendgrid/mailgun/mandrill` — контроллеры-приёмники
- Config: `config.action_mailbox.incinerate/incinerate_after/queues/
  ingress/logger`

## Реализация

- Роутинг mailbox-имён: compile-time registry (routing-таблица пишется в
  одном классе — имена известны при сборке).
- Пайплайн: ingress-контроллер → InboundEmail (AR + raw_email blob) →
  ActiveJob-роутинг → mailbox `process` → статус.
- Зависимость от mail-порта action_mailer.cr (парсинг входящих писем).

## Статус (Iteration 5 — P0 готов)

- Oracle: `oracle/cases.rb` → `oracle/expected.yml`, 29 кейсов сняты с
  actionmailbox 8.1.4 (SQLite in-memory, Disk-сервис, ActiveJob :test
  adapter с GlobalID — routing вызывается явно). Покрыто: Message-ID
  извлечение/генерация (SHA1@hostname), checksum, pending-статус и
  enqueue RoutingJob, source/mail-парсинг (from/to/cc/recipients/
  subject), raw_email-blob (filename/content_type/service/size),
  routing String/Regex/:all + mailbox_for, полный lifecycle статусов
  (delivered/bounced/failed), before_processing с bounced!-haltом,
  unrouted → bounced + RoutingError. Зеркало: `spec/oracle_spec.cr` —
  29/29.
- Реализовано: `mail_parser.cr` (reopen Mail::Message — from_source:
  unfolded-заголовки с downcase-ключами, адресные списки, recipients =
  to+cc+bcc, message_id без угловых скобок), `inbound_email.cr`
  (row-класс на Base.connection: статусы как Rails int-enum 0..4,
  create_and_extract_message_id! c blob-загрузкой, route_later →
  регистр enqueued_jobs, route → ::ApplicationMailbox), `router.cr`
  (Route: String case-insensitive / Regex / Proc / :all по recipients;
  mailbox-класс — compile-time константный lookup через реестр имён),
  `base.cr` (perform_processing: processing! → before_processing
  (halt при bounced) → process → delivered!; исключение → failed!;
  routing-макрос; MAILBOXES-registry + module finished для сборки
  коллбэков — классовый macro finished на подклассы не срабатывает).
- Отклонения от Rails (сознательные, P1+): RoutingJob — регистр имён
  в памяти вместо ActiveJob-интеграции (оракул сам использует :test
  adapter с ручным route); InboundEmail — ручной row-класс (как
  RichText в action_text.cr) из-за кодеген-переопределения методов;
  ingress-контроллеры (relay/postmark/sendgrid/mailgun/mandrill),
  bounce_with/bounce_now_with, IncinerationJob, after/around_processing
  — P1. Таблица в PG — как в миграции гема (int-статус, message_id,
  message_checksum).
- Спеки шарда: `crystal spec` (запуск из корня шарда).

## Фазы

- P0: InboundEmail-модель + routing DSL + `process` + статусы.
- P1: ingress relay/postmark/sendgrid/mailgun, bounce, incinerate.

## Готово, когда

POST ingress-запрос с RFC822-письмом создаёт InboundEmail и направляет
его в mailbox по routing-правилу.

## Зависимости

active_record.cr, active_storage.cr, action_mailer.cr, active_job.cr.
