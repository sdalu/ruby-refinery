require 'mqtt'

module Refinery
module MQTTResilient
    # One process-wide lock serializing publish attempts and reconnects:
    # reconnect tears down and replaces the client socket, and neither
    # the gem's disconnect nor connect takes its @write_semaphore, so an
    # unsynchronized reconnect can yank the socket from under another
    # thread's in-flight publish.  (Module-level constant rather than a
    # lazy per-client mutex: `@lock ||= Mutex.new` has its own
    # initialization race.)
    LOCK = Mutex.new

    refine MQTT::Client do
        # A handshake failing partway (the broker hangs up or stalls
        # before CONNACK) leaves the gem's socket open: connected? stays
        # true, the next connect returns without connecting, and every
        # write then fails with EPIPE.  Drop the socket on any failure
        # so that a retry connects afresh.
        #
        # The gem sets its ping clocks only in initialize: once a ping
        # has gone unanswered, every later connection inherits the stale
        # @last_ping_response, and its read thread raises "No Ping
        # Response" on its first pass, the subscriber's SUBSCRIBE often
        # still being written.  A new connection starts them afresh.
        #
        # With a block, the gem's own `ensure disconnect` is bypassed:
        # see drop_connection.
        def connect(*args, &block)
            unless connected?
                @last_ping_request = @last_ping_response = current_time
            end
            begin
                super(*args, &nil)
            rescue ::Exception
                drop_connection
                raise
            end
            return unless block

            begin
                yield(self)
            ensure
                drop_connection(goodbye: true)
            end
        end

        # Close, sending DISCONNECT only if +goodbye+: on a dead socket
        # the gem's disconnect fails writing it and never closes the
        # socket.
        #
        # The socket is closed here, and the read thread, woken by it,
        # left to finish rather than killed.  The read thread closes the
        # socket itself on an error, and Ruby's IO#close waits there for
        # any thread still writing to it (a SUBSCRIBE, a publish): that
        # writer gets "stream closed in another thread", and the gem's
        # disconnect, run as it unwinds, kills the read thread inside
        # that wait.  On Ruby 3.4 the socket is then closed? and never
        # closed: still subscribed, unread, one more each time.  The
        # read thread's own raise into this one is held until the end,
        # and dropped with the rest.
        def drop_connection(goodbye: false)
            Thread.handle_interrupt(Object => :never) do
                reader, socket = @read_thread, @socket
                if goodbye && connected?
                    begin
                        send_packet(MQTT::Packet::Disconnect.new)
                    rescue StandardError, MQTT::Exception
                        nil
                    end
                end
                begin
                    socket&.close
                rescue StandardError
                    nil
                end
                if reader&.alive? && !reader.equal?(Thread.current)
                    reader.join(2) or reader.kill
                end
                self.disconnect(false)
            end
        rescue StandardError, MQTT::Exception
            nil
        end

        def reconnect
            self.drop_connection
            self.connect
        end

        # Retries +retry_count+ times over a broken connection,
        # reconnecting in between, then raises: the last reconnect's
        # error if it failed, else the publish's.
        def publish(topic, message = '', retain = false, qos = 0,   # as the gem
                    retry_delay: 5.0, retry_count: 3)
            # Checked before the first attempt: a fractional count never
            # reached zero, a negative one or delay raised from sleep
            unless retry_count.is_a?(Integer) && !retry_count.negative?
                raise ArgumentError, "retry_count: expected an Integer >= 0, got #{retry_count.inspect}"
            end
            unless retry_delay.is_a?(Numeric) && retry_delay.finite? && !retry_delay.negative?
                raise ArgumentError, "retry_delay: expected seconds >= 0, got #{retry_delay.inspect}"
            end
            reconnect_error = nil
            # The same pause before each retry, retry_delay in all
            pause = retry_count.zero? ? 0 : retry_delay.to_f / retry_count
            begin
                LOCK.synchronize { super(topic, message, retain, qos) }
            rescue MQTT::NotConnectedException, MQTT::ProtocolException,
                   Errno::EPIPE, Errno::ECONNRESET, IOError => e
                raise reconnect_error || e if retry_count.zero?
                sleep(pause)
                retry_count -= 1
                # A broker still away refuses the reconnect: that spends
                # a retry rather than ending the publish
                reconnect_error = begin
                                      LOCK.synchronize { self.reconnect }
                                      nil
                                  rescue SystemCallError, SocketError, IOError,
                                         Timeout::Error, MQTT::Exception => re
                                      re
                                  end
                retry
            end
        end
    end
end
end
