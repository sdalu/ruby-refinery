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
        # reconnecting in between, then raises.
        def publish(topic, message, retain = false, qos = 0,
                    retry_delay: 5.0, retry_count: 3)
            LOCK.synchronize { super(topic, message, retain, qos) }
        rescue MQTT::NotConnectedException, MQTT::ProtocolException,
               Errno::EPIPE, Errno::ECONNRESET, IOError
            raise if retry_count.zero?
            sleep(retry_delay / retry_count)
            retry_count -= 1
            LOCK.synchronize { self.reconnect }
            retry
        end
    end
end
end
