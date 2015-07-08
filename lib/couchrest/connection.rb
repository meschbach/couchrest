module CouchRest

  # CouchRest Connection
  #
  # Handle connections to the CouchDB server and provide a set of HTTP based methods to
  # perform requests.
  #
  # All connection are persistent. A connection cannot be re-used to connect to other servers.
  #
  # Six types of REST requests are supported: get, put, post, delete, copy and head.
  #
  # Requests that do not have a payload, get, delete and copy, accept the URI and options parameters,
  # where as put and post both expect a document as the second parameter.
  #
  # The API will share the options between the Net::HTTP connection and JSON parser.
  #
  # The following options will be recognised as header options and automatically added
  # to the header hash:
  #
  #  * `:content_type`, type of content to be sent, especially useful when sending files as this will set the file type. The default is :json.
  #  * `:accept`, the content type to accept in the response. This should pretty much always be `:json`.
  #
  # The following request options are supported:
  #
  #  * `:payload` override the document or data sent in the message body (only PUT or POST).
  #  * `:headers` any additional headers (overrides :content_type and :accept)
  #  * `:timeout` (or `:read_timeout`) and `:open_timeout` the time in miliseconds to wait for the request, see the [Net HTTP Persistent documentation](http://docs.seattlerb.org/net-http-persistent/Net/HTTP/Persistent.html#attribute-i-read_timeout) for more details.
  # * `:verify_ssl`, `:ssl_client_cert`, `:ssl_client_key`, and `:ssl_ca_file`, SSL handling methods.
  #
  # When :raw is true in PUT and POST requests, no attempt will be made to convert the document payload to JSON. This is
  # not normally necessary as IO and Tempfile objects will not be parsed anyway. The result of the request will
  # *always* be parsed.
  #
  # For all other requests, mainly GET, the :raw option will make no attempt to parse the result. This
  # is useful for receiving files from the database.
  #
  class Connection

    HEADER_CONTENT_SYMBOL_MAP = {
      :content_type => 'Content-Type',
      :accept       => 'Accept' 
    }

    DEFAULT_HEADERS = {
      'Content-Type' => 'application/json',
      'Accept'       => 'application/json'
    }

    KNOWN_PARSER_OPTIONS = [
      :max_nesting, :allow_nan, :quirks_mode, :create_additions
    ]

    SUCCESS_RESPONSE_CODES = [200, 201, 202, 204]

    attr_reader :uri, :http, :last_response

    def initialize(uri, options = {})
      raise "CouchRest::Connection.new requires URI::HTTP(S) parameter" unless uri.is_a?(URI::HTTP)
      @uri = clean_uri(uri)
      prepare_http_connection(options)
    end

    # Send a GET request.
    def get(path, options = {}, &block)
      execute(:get, path, options, nil, &block)
    end

    # Send a PUT request.
    def put(path, doc = nil, options = {})
      execute(:put, path, options, doc)
    end

    # Send a POST request.
    def post(path, doc = nil, options = {}, &block)
      execute(:post, path, options, doc, &block)
    end

    # Send a DELETE request.
    def delete(path, options = {})
      execute(:delete, path, options)
    end

    # Send a COPY request to the URI provided.
    def copy(path, destination, options = {})
      opts = options.nil? ? {} : options.dup
      opts[:headers] = options[:headers].nil? ? {} : options[:headers].dup
      opts[:headers]['Destination'] = destination
      execute(:copy, path, opts)
    end

    # Send a HEAD request.
    def head(path, options = {})
      options = options.merge(:raw => true) # No parsing!
      execute(:head, path, options)
    end

    # Close the connection. This will happen automatically if the current thread is
    # killed, so shouldn't be used under normal circumstances.
    def close
      http.shutdown
    end

    protected

    # Duplicate and remove excess baggage from the provided URI
    def clean_uri(uri)
      uri = uri.dup
      uri.path     = ""
      uri.query    = nil
      uri.fragment = nil
      uri
    end

    # Take a look at the options povided and try to apply them to the HTTP conneciton.
    # We try to maintain RestClient compatability as this is what we used before.
    def prepare_http_connection(opts)
      http_opts = {
        :persistent  => true,
        :tcp_nodelay => true
      }

      # SSL Certificate option mapping
      http_opts[:ssl_verify_peer] = opts[:verify_ssl] if opts.include?(:verify_ssl)
      http_opts[:client_cert]     = opts[:ssl_client_cert] if opts.include?(:ssl_client_cert)
      http_opts[:client_key]      = opts[:ssl_client_key] if opts.include?(:ssl_client_key)
      http_opts[:client_key_pass] = opts[:ssl_client_key_pass] if opts.include?(:ssl_client_key_pass)

      # Timeout options
      http_opts[:connect_timeout] = opts[:timeout] if opts.include?(:timeout)
      http_opts[:read_timeout]    = opts[:read_timeout] if opts.include?(:read_timeout)
      http_opts[:open_timeout]    = opts[:open_timeout] if opts.include?(:open_timeout)

      @http = Excon.new(uri.to_s, http_opts)
    end

    def execute(method, path, options, payload = nil, &block)
      req = {
        :method => method,
        :path   => path
      }

      # Prepare the request headers
      DEFAULT_HEADERS.merge(parse_and_convert_request_headers(options)).each do |key, value|
        req[:headers] ||= {}
        req[:headers][key] = value
      end

      # Prepare the request body, if provided
      unless payload.nil?
        req[:body] = payload_from_doc(req, payload, options)
      end

      send_and_parse_response(req, options, &block)
    end

    def send_and_parse_response(req, options, &block)
      if block_given?
        parser = CouchRest::StreamRowParser.new
        streamer = lambda do |chunk, remaining_bytes, total_bytes|
          parser.parse(chunk) do |doc|
            block.call(parse_body(doc, options))
          end
        end
        response = send_request(req.merge(:response_block => streamer))
        handle_response_code(response)
        parse_body(parser.header, options)
      else
        response = send_request(req)
        handle_response_code(response)
        parse_body(response.body, options)
      end
    end

    # Send request, and leave a reference to the response for debugging purposes
    def send_request(req)
      @last_response = http.request(req)
    end

    def handle_response_code(response)
      raise_response_error(response) unless SUCCESS_RESPONSE_CODES.include?(response.status)
    end

    def parse_body(body, opts)
      if opts[:raw]
        # passthru
        body
      else
        MultiJson.load(body, prepare_json_load_options(opts))
      end
    end

    # Check if the provided doc is nil or special IO device or temp file. If not,
    # encode it into a string.
    #
    # The options supported are:
    # * :raw TrueClass, if true the payload will not be altered.
    #
    def payload_from_doc(req, doc, opts = {})
      if doc.is_a?(IO) || doc.is_a?(Tempfile)
        req[:headers]['Content-Type'] = mime_for(req[:path])
        doc.read
      elsif opts[:raw] || doc.nil?
        doc
      else
        MultiJson.encode(doc.respond_to?(:as_couch_json) ? doc.as_couch_json : doc)
      end
    end

    def mime_for(path)
      mime = MIME::Types.type_for path
      mime.empty? ? 'text/plain' : mime[0].content_type
    end

    def raise_response_error(response)
      exp = CouchRest::Exceptions::EXCEPTIONS_MAP[response.status]
      exp ||= CouchRest::RequestFailed
      raise exp.new(response)
    end

    def prepare_json_load_options(opts = {})
      options = {
        :create_additions => CouchRest.decode_json_objects, # For object conversion, if required
        :max_nesting      => false
      }
      KNOWN_PARSER_OPTIONS.each do |k|
        options[k] = opts[k] if opts.include?(k)
      end
      options
    end

    def parse_and_convert_request_headers(options)
      headers = options.include?(:headers) ? options[:headers].dup : {}
      HEADER_CONTENT_SYMBOL_MAP.each do |sym, key|
        if options.include?(sym)
          headers[key] = convert_content_type(options[sym])
        end
      end
      headers
    end

    def convert_content_type(type)
      if type.is_a?(Symbol)
        case type
        when :json
          'application/json'
        end
      else
        type
      end
    end

  end
end
