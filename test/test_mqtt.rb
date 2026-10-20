# frozen_string_literal: true

require_relative 'helper'

return unless require_optional('mqtt')

require 'refinery/mqtt'

# Replace the gem's own low-level methods so that the refinement's
# `super` lands in instrumented hooks instead of a real socket.  This
# reopens MQTT::Client for the whole process: anything else here that
# wants a real client runs in a child (test_mqtt_broker.rb).
class MQTT::Client
    def publish(topic, message, retain = false, qos = 0) = MQTTTestHooks.publish
    def disconnect(send_msg = true) = MQTTTestHooks.disconnect(send_msg)
    def connect(*)                  = MQTTTestHooks.connect
end

module MQTTTestHooks
    class << self
        attr_accessor :fail_for, :always_fail, :fail_with, :reconnect_delay,
                      :connect_refused

        def reset
            @events          = []
            @mutex           = Mutex.new
            @fail_for        = nil
            @always_fail     = false
            @fail_with       = MQTT::NotConnectedException
            @reconnect_delay = 0
            @connect_refused = 0     # connects refused before one succeeds
        end

        def events = @mutex.synchronize { @events.dup }
        def log(e) = @mutex.synchronize { @events << e }

        def publish
            if @always_fail || Thread.current[:role] == @fail_for
                @fail_for = nil
                log [ :publish_failed, Thread.current[:role] ]
                raise @fail_with
            end
            log [ :write, Thread.current[:role] ]
        end

        def disconnect(send_msg)
            log [ :reconnect_start, send_msg ]
            sleep @reconnect_delay
        end

        def connect
            if @connect_refused.positive?
                @connect_refused -= 1
                log [ :connect_refused ]
                raise Errno::ECONNREFUSED
            end
            log [ :reconnect_end ]
        end
    end
end

class TestMQTTResilient < Minitest::Test
    using Refinery::MQTTResilient

    def setup
        MQTTTestHooks.reset
        @client = MQTT::Client.new
    end

    def teardown = Thread.current[:role] = nil

    def events = MQTTTestHooks.events

    def test_publish_retries_then_raises_when_broker_stays_down
        MQTTTestHooks.always_fail = true
        assert_raises(MQTT::NotConnectedException) do
            @client.publish('t', 'm', retry_delay: 0.01)
        end
        assert_equal 4, events.count { it.first == :publish_failed },
                     'initial try + 3 retries'
        assert_equal 3, events.count { it.first == :reconnect_start },
                     'one reconnect between attempts'
    end

    # Regression: a reconnect refused by the broker escaped the rescue
    # and ended the publish with the retries unspent
    def test_a_refused_reconnect_is_retried
        MQTTTestHooks.fail_for        = :main
        MQTTTestHooks.connect_refused = 1
        Thread.current[:role]         = :main
        @client.publish('t', 'm', retry_delay: 0.01)
        assert_equal [ [ :publish_failed, :main ], [ :reconnect_start, false ],
                       [ :connect_refused ], [ :reconnect_start, false ],
                       [ :write, :main ] ], events
    end

    # ...and once they are spent, the reconnect's error is the one raised
    def test_raises_the_reconnect_error_when_broker_stays_away
        MQTTTestHooks.always_fail     = true
        MQTTTestHooks.connect_refused = 99
        assert_raises(Errno::ECONNREFUSED) do
            @client.publish('t', 'm', retry_delay: 0.01)
        end
        assert_equal 3, events.count([ :connect_refused ]), 'one per retry'
    end

    def test_retry_count_zero_raises_at_once
        MQTTTestHooks.always_fail = true
        assert_raises(MQTT::NotConnectedException) do
            @client.publish('t', 'm', retry_count: 0)
        end
        assert_equal [ [ :publish_failed, nil ] ], events
    end

    def test_publish_recovers_after_one_reconnect
        MQTTTestHooks.fail_for = :main
        Thread.current[:role]  = :main
        @client.publish('t', 'm', retry_delay: 0.01)
        assert_equal [ [ :publish_failed, :main ], [ :reconnect_start, false ],
                       [ :reconnect_end ], [ :write, :main ] ], events
    end

    # A dead socket cannot take a DISCONNECT packet; sending one fails
    # and leaves the socket open
    def test_reconnect_sends_no_disconnect
        @client.reconnect
        assert_equal [ [ :reconnect_start, false ], [ :reconnect_end ] ], events
    end

    def test_retries_over_a_broken_socket
        [ Errno::EPIPE, Errno::ECONNRESET, IOError, MQTT::ProtocolException ]
            .each do |error|
            MQTTTestHooks.reset
            MQTTTestHooks.fail_for  = :main
            MQTTTestHooks.fail_with = error
            Thread.current[:role]   = :main
            @client.publish('t', 'm', retry_delay: 0.01)
            assert_equal [ :write, :main ], events.last, error.name
        end
    end

    def test_does_not_retry_what_is_not_a_broken_connection
        MQTTTestHooks.always_fail = true
        MQTTTestHooks.fail_with   = ArgumentError
        assert_raises(ArgumentError) { @client.publish('t', 'm', retry_delay: 0.01) }
        assert_empty events.select { it.first == :reconnect_start }
    end

    def test_reconnect_excludes_concurrent_publishes
        MQTTTestHooks.fail_for        = :a
        MQTTTestHooks.reconnect_delay = 0.3

        a = Thread.new do
            Thread.current[:role] = :a
            @client.publish('t', 'm', retry_delay: 0.01)
        end
        sleep 0.1                       # land inside A's reconnect window
        b = Thread.new do
            Thread.current[:role] = :b
            @client.publish('t', 'm')
        end
        [ a, b ].each(&:join)

        ev     = events
        start  = ev.index { it.first == :reconnect_start }
        finish = ev.index([ :reconnect_end ])
        refute_nil start
        refute_nil finish
        assert_includes ev, [ :write, :b ]
        assert_empty ev[(start + 1)...finish].select { it.first == :write },
                     "no publish may interleave with a reconnect: #{ev.inspect}"
    end
end
