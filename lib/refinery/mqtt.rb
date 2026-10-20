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
        def connect(*args, &block)
            super
        rescue ::Exception
            drop_connection
            raise
        end

        # Close without sending DISCONNECT: on a dead socket the gem's
        # disconnect fails writing it and never closes the socket.
        def drop_connection
            self.disconnect(false)
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
