require 'socket'
require 'SecureRandom'
require 'ssdp'

module SSDP
  class Producer
    attr_accessor :services

    def initialize(options = {})
      @uuid = SecureRandom.uuid
      @services = {}
      @listener = { :socket => nil, :thread => nil }
      @notifier = { :thread => nil }
      @options = SSDP::DEFAULTS.merge options
    end

    def running?
      @listener[:thread] != nil
    end

    def start
      start_notifier if @options[:notifier]
      start_listener
    end

    def stop(bye_bye = true)
      @services.each { |type, params| send_bye_bye type, params } if bye_bye

      if @listener[:thread] != nil
        @listener[:thread].exit
        @listener[:thread] = nil
      end
      if @notifier[:thread] != nil
        @notifier[:thread].exit
        @notifier[:thread] = nil
      end
    end

    def add_service(type, location_or_param_hash)
      params = {}
      if location_or_param_hash.is_a? Hash
        params = location_or_param_hash
      else
        params['AL']       = location_or_param_hash
        params['LOCATION'] = location_or_param_hash
      end

      @services[type] = params
      send_notification type, params if @options[:notifier]
    end

    private

    def process_ssdp(message, consumer)
      ssdp = SSDP.parse_ssdp message
      return unless ssdp[:status].start_with? 'M-SEARCH * HTTP'

      return if ssdp[:params]['ST'].nil?
      return if @services[ssdp[:params]['ST']].nil?
      send_response ssdp[:params]['ST'], consumer
    end

    def send_response(type, consumer)
      params = @services[type]
      response_body = "HTTP/1.1 200 OK\r\n"    \
                      "ST: #{type}\r\n"        \
                      "USN: uuid:#{@uuid}\r\n" +
                      params.map { |k, v| "#{k}: #{v}" }.join("\r\n") +
                      "\r\n\r\n"
      send_direct_packet response_body, consumer
    end

    def send_notification(type, params)
      notify_body = "NOTIFY * HTTP/1.1\r\n"                                \
                    "Host: #{@options[:broadcast]}:#{@options[:port]}\r\n" \
                    "NTS: ssdp:alive\r\n"                                  \
                    "NT: #{type}\r\n"                                      \
                    "USN: uuid:#{@uuid}\r\n" +
                    params.map { |k, v| "#{k}: #{v}" }.join("\r\n") +
                    "\r\n\r\n"

      send_broadcast_packet notify_body
    end

    def send_bye_bye(type, params)
      bye_bye_body = "NOTIFY * HTTP/1.1\r\n"                                \
                     "Host: #{@options[:broadcast]}:#{@options[:port]}\r\n" \
                     "NTS: ssdp:byebye\r\n"                                 \
                     "NT: #{type}\r\n"                                      \
                     "USN: uuid:#{@uuid}\r\n" +
                     params.map { |k, v| "#{k}: #{v}" }.join("\r\n") +
                     "\r\n\r\n"

      send_broadcast_packet bye_bye_body
    end

    def send_direct_packet(body, endpoint)
      udp_socket = UDPSocket.new
      udp_socket.send body, 0, endpoint[:address], endpoint[:port]
      udp_socket.close
    end

    def send_broadcast_packet(body)
      broadcaster = SSDP.create_broadcaster
      broadcaster.send body, 0, @options[:broadcast], @options[:port]
      broadcaster.close
    end

    def start_listener
      @listener[:socket] = SSDP.create_listener @options
      @listener[:thread] = Thread.new do
        begin
          while true
            message, consumer = @listener[:socket].recvfrom @options[:maxpack]
            process_ssdp message, { :address => consumer[3], :port => consumer[1] } unless @services.count == 0
          end
        ensure
          @listener[:socket].close
        end
      end
    end

    def start_notifier
      @notifier[:thread] = Thread.new do
        while true
          sleep @options[:interval]
          @services.each { |type, params| send_notification type, params }
        end
      end
    end

  end
end