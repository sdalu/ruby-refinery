require 'mqtt'

module Refinery
module MQTTResilient
    refine MQTT::Client do
        def reconnect
            self.disconnect
            self.connect
        end

        def publish(topic, message, retain = false, qos = 0,
                    retry_delay: 5.0, retry_count: 3)
            super(topic, message, retain, qos)
        rescue MQTT::NotConnectedException, MQTT::ProtocolException
            raise if retry_count.zero?
            retry_count -= 1
            sleep(retry_delay / retry_count)
            self.reconnect
            retry
        end
    end
end
end

