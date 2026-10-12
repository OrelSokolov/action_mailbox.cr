# action_mailbox_cr — port of ActionMailbox (P0): InboundEmail (AR row +
# raw_email blob), Router (String/Regex/Proc/:all addresses), mailbox
# Base with the processing status lifecycle and the routing DSL.

require "openssl"
require "active_record_cr"
require "active_storage_cr"
require "action_mailer_cr"

require "./mail_parser"
require "./inbound_email"
require "./router"
require "./base"
