# frozen_string_literal: true

require_relative 'helper'
require 'json'

return unless require_optional('mqtt')

# Against the real gem and a fake broker on a local port, in a child
# process: test_mqtt.rb replaces MQTT::Client's connect and publish for
# the whole test process.
class TestMQTTBrokerDrop < Minitest::Test
    include Subprocess

    BROKER = <<~RUBY
        require "socket"
        require "json"
        require "mqtt"

        # A broker on 127.0.0.1 counting connections; +session+ gets
        # each accepted socket, which is closed after it.
        def broker(&session)
            server  = TCPServer.new("127.0.0.1", 0)
            accepts = Queue.new
            Thread.new do
                loop do
                    s = server.accept
                    accepts << 1
                    Thread.new(s) do |sock|
                        session.(sock)
                    rescue StandardError, MQTT::Exception
                    ensure
                        sock.close
                    end
                end
            end
            [ server.addr[1], accepts ]
        end

        def wait_for(seconds)
            deadline = Time.now + seconds
            sleep 0.05 until yield || Time.now > deadline
        end
    RUBY

    # The child's last line of output, as JSON
    def run_child(script)
        out, err, st = ruby_run(BROKER + script)
        assert st.success?, "child failed: #{err}"
        JSON.parse(out.lines.last)
    end

    def test_connect_failing_before_connack_leaves_client_reconnectable
        first, connected, second, accepts = run_child(<<~RUBY)
            require "refinery/mqtt"
            using Refinery::MQTTResilient

            # Reads CONNECT, hangs up without CONNACK.  The gem's
            # exceptions derive from ::Exception, hence the rescue.
            port, accepts = broker { |s| MQTT::Packet.read(s) }
            c = MQTT::Client.new(host: "127.0.0.1", port: port, ack_timeout: 2)
            first     = begin c.connect; "ok"; rescue Exception => e; e.class.name; end
            connected = c.connected?
            second    = begin c.connect; "ok"; rescue Exception => e; e.class.name; end
            wait_for(2) { accepts.size >= 2 }
            puts JSON.dump([ first, connected, second, accepts.size ])
        RUBY

        refute_equal 'ok', first
        refute connected, 'a failed handshake must drop the socket'
        refute_equal 'ok', second, 'a retry must connect again, not return'
        assert_equal 2, accepts
    end
end
