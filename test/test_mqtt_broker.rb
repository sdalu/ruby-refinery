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

    def test_reconnect_after_unanswered_ping_starts_with_fresh_ping_clocks
        first, second = run_child(<<~RUBY)
            require "refinery/mqtt"
            using Refinery::MQTTResilient

            # CONNACK, and PINGRESP only from the second connection on
            conns = 0
            port, _ = broker do |s|
                n = (conns += 1)
                loop do
                    case MQTT::Packet.read(s)
                    when MQTT::Packet::Connect
                        s.write(MQTT::Packet::Connack.new(return_code: 0))
                    when MQTT::Packet::Pingreq
                        s.write(MQTT::Packet::Pingresp.new) if n > 1
                    end
                end
            end
            c = MQTT::Client.new(host: "127.0.0.1", port: port, keep_alive: 2)

            # What ends a connection held +secs+, if anything
            life = lambda do |secs|
                c.connect { sleep secs }
                "alive"
            rescue Exception => e
                e.class.name
            end
            # The first sends its PINGREQ at 2 s and leaves at 2.4,
            # unanswered; the second follows at once, under the 3 s
            # response timeout counted from its own start
            puts JSON.dump([ life.(2.4), life.(5) ])
        RUBY

        assert_equal 'alive', first
        assert_equal 'alive', second,
                     'a ping unanswered on the last connection ended this one'
    end

    def test_read_error_during_a_write_closes_the_socket
        errors, open = run_child(<<~RUBY)
            require "refinery/mqtt"
            using Refinery::MQTTResilient

            # CONNACK, then a packet of no type 0.5 s later, reading
            # nothing more: the client is writing when its read thread
            # fails, and closes the socket under it.  Hung up 1 s later.
            port, _ = broker do |s|
                MQTT::Packet.read(s)
                s.write(MQTT::Packet::Connack.new(return_code: 0))
                sleep 0.5
                s.write("\\x00\\x00")
                sleep 1
            end
            c   = MQTT::Client.new(host: "127.0.0.1", port: port)
            fds = []
            errors = Array.new(5) do
                c.connect do
                    fds << c.instance_variable_get(:@socket).fileno
                    c.publish("t", "x" * 20_000_000, retry_count: 0)
                end
                "none"
            rescue Exception => e
                e.class.name
            end
            sleep 1.5      # the broker's sockets gone, their fds with them
            open = fds.count { |fd| IO.for_fd(fd, autoclose: false).stat rescue false }
            puts JSON.dump([ errors.uniq, open ])
        RUBY

        refute_includes errors, 'none'
        assert_equal 0, open, 'a socket the client gave up on is still open'
    end
end
