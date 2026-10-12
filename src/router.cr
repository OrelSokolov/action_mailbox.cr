# Router — routes an InboundEmail to the first matching mailbox.
# Addresses: String (case-insensitive exact), Regex, Proc(InboundEmail,
# Bool), or :all — matched against mail.recipients (to + cc + bcc).

module ActionMailbox
  class Router
    class RoutingError < Exception
    end

    alias Address = String | Regex | Proc(InboundEmail, Bool) | Symbol

    class Route
      getter address : Address
      getter mailbox_name : String

      def initialize(@address : Address, @mailbox_name : String)
        ensure_valid_address
      end

      def match?(inbound_email : InboundEmail) : Bool
        case a = @address
        when Symbol
          a == :all
        when String
          wanted = a.downcase
          inbound_email.mail.recipients.any? { |r| r.downcase == wanted }
        when Regex
          inbound_email.mail.recipients.any? { |r| a.match(r) != nil }
        when Proc
          a.call(inbound_email)
        else
          false
        end
      end

      def mailbox_class : Base.class
        Base.mailbox_for_name(mailbox_name)
      end

      private def ensure_valid_address : Nil
        valid = case @address
                when String, Regex, Proc, Symbol then true
                else                                   false
                end
        unless valid
          raise ArgumentError.new(
            "Expected a Symbol, String, Regexp, Proc, or matchable, got #{@address.inspect}")
        end
      end
    end

    @routes = [] of Route

    def add_route(address : Address, to mailbox_name : Symbol | String) : Nil
      @routes << Route.new(address, mailbox_name.to_s)
    end

    def route(inbound_email : InboundEmail) : Nil
      if mailbox = mailbox_for(inbound_email)
        mailbox.receive(inbound_email)
      else
        inbound_email.bounced!
        raise RoutingError.new
      end
    end

    def mailbox_for(inbound_email : InboundEmail) : Base.class | Nil
      @routes.each do |route|
        return route.mailbox_class if route.match?(inbound_email)
      end
      nil
    end
  end
end
