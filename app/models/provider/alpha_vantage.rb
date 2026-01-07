class Provider::AlphaVantage < Provider
  include ExchangeRateConcept, SecurityConcept

  # Subclass so errors caught in this provider are raised as Provider::AlphaVantage::Error
  Error = Class.new(Provider::Error)
  InvalidExchangeRateError = Class.new(Error)
  InvalidSecurityPriceError = Class.new(Error)

  # API Functions
  FUNC_CURRENCY_EXCHANGE_RATE = "CURRENCY_EXCHANGE_RATE".freeze
  FUNC_FX_DAILY = "FX_DAILY".freeze
  FUNC_SYMBOL_SEARCH = "SYMBOL_SEARCH".freeze
  FUNC_OVERVIEW = "OVERVIEW".freeze
  FUNC_TIME_SERIES_DAILY = "TIME_SERIES_DAILY".freeze

  # Response Keys
  KEY_REALTIME_RATE = "Realtime Currency Exchange Rate".freeze
  KEY_ERROR_MESSAGE = "Error Message".freeze
  KEY_NOTE = "Note".freeze
  KEY_TIME_SERIES_FX = "Time Series FX (Daily)".freeze
  KEY_TIME_SERIES_DAILY = "Time Series (Daily)".freeze
  KEY_BEST_MATCHES = "bestMatches".freeze
  KEY_CLOSE = "4. close".freeze
  KEY_REGION = "4. region".freeze
  KEY_SYMBOL = "1. symbol".freeze
  KEY_NAME = "2. name".freeze
  KEY_TYPE = "3. type".freeze
  KEY_CURRENCY = "8. currency".freeze
  KEY_OVERVIEW_NAME = "Name".freeze
  KEY_OVERVIEW_DESCRIPTION = "Description".freeze
  KEY_OVERVIEW_ASSET_TYPE = "AssetType".freeze
  KEY_OVERVIEW_CURRENCY = "Currency".freeze

  def initialize(api_key)
    @api_key = api_key
  end

  def healthy?
    with_provider_response do
      Rails.logger.info("AlphaVantage: Checking health...")
      begin
        parsed = request_api(
          function: FUNC_CURRENCY_EXCHANGE_RATE,
          from_currency: "USD",
          to_currency: "EUR"
        )
        parsed.key?(KEY_REALTIME_RATE)
      rescue Error
        false
      end
    end
  end


  # ================================
  #          Exchange Rates
  # ================================

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      Rails.logger.info("AlphaVantage: Fetching exchange rate for #{from}/#{to} on #{date}")
      rates_response = fetch_exchange_rates(from: from, to: to, start_date: date, end_date: date)

      if rates_response.success?
        rate = rates_response.data.first
        Rails.logger.info("AlphaVantage: Found rate: #{rate&.rate || 'None'}")
        rate
      else
        Rails.logger.error("AlphaVantage: Failed to fetch single rate: #{rates_response.error}")
        raise rates_response.error
      end
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      if start_date < 100.days.ago.to_date
        Rails.logger.warn("AlphaVantage: start_date (#{start_date}) is older than 100 days. 'compact' output may not contain required data.")
      end

      Rails.logger.info("AlphaVantage: Fetching daily FX for #{from}/#{to} from #{start_date} to #{end_date} (compact)")

      parsed = request_api(
        function: FUNC_FX_DAILY,
        from_symbol: from,
        to_symbol: to,
        outputsize: "compact"
      )

      data = parsed[KEY_TIME_SERIES_FX]
      ensure_data_exists!(data, parsed, InvalidExchangeRateError)

      results = data.map do |date_str, values|
        date = Date.parse(date_str)
        next unless date >= start_date && date <= end_date

        rate = values[KEY_CLOSE]
        if rate.nil? || rate.to_f <= 0
          Rails.logger.warn("AlphaVantage: Invalid rate data for #{from}/#{to} on #{date}: #{rate.inspect}")
          next
        end

        Rate.new(date: date, from: from, to: to, rate: rate.to_f)
      end.compact

      Rails.logger.info("AlphaVantage: Successfully fetched #{results.length} exchange rates")
      results
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      parsed = fetch_symbol_search_raw(symbol)

      data = parsed[KEY_BEST_MATCHES]
      Rails.logger.info("AlphaVantage: Found matches #{data}")
      ensure_data_exists!(data, parsed, Error, "Search yielded no data")

      results = data.map do |security|
        Rails.logger.info("AlphaVantage: Found security #{security}")
        country_code = RegionMapper.to_iso_code(security[KEY_REGION])
        Rails.logger.info("AlphaVantage: Found country #{country_code} for '#{symbol}'")
        Security.new(
          symbol: security[KEY_SYMBOL],
          name: security[KEY_NAME],
          logo_url: nil,
          exchange_operating_mic: nil,
          country_code: country_code
        )
      end

      Rails.logger.info("AlphaVantage: Found #{results.length} matches for '#{symbol}'")
      results
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic:)
    with_provider_response do
      profile = fetch_overview_raw(symbol)

      if profile.empty?
        Rails.logger.info("AlphaVantage: No overview profile found for #{symbol}, trying SYMBOL_SEARCH fallback")
        search_data = fetch_symbol_search_raw(symbol)

        matches = search_data[KEY_BEST_MATCHES]
        match = matches&.find { |m| m[KEY_SYMBOL] == symbol } || matches&.first

        if match
          SecurityInfo.new(
            symbol: match[KEY_SYMBOL],
            name: match[KEY_NAME],
            links: nil,
            logo_url: nil,
            description: nil,
            kind: match[KEY_TYPE],
            exchange_operating_mic: exchange_operating_mic
          )
        else
          Rails.logger.warn("AlphaVantage: No profile data found for #{symbol} (and fallback failed)")
          raise Error, "No profile data found for symbol #{symbol}"
        end
      else
        SecurityInfo.new(
          symbol: symbol,
          name: profile[KEY_OVERVIEW_NAME],
          links: nil,
          logo_url: nil,
          description: profile[KEY_OVERVIEW_DESCRIPTION],
          kind: profile[KEY_OVERVIEW_ASSET_TYPE],
          exchange_operating_mic: exchange_operating_mic
        )
      end
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      Rails.logger.info("AlphaVantage: Fetching security price for #{symbol} on #{date}")
      historical_data_response = fetch_security_prices(symbol: symbol, exchange_operating_mic: exchange_operating_mic, start_date: date, end_date: date)

      if historical_data_response.success?
        prices = historical_data_response.data
        if prices.empty?
          Rails.logger.warn("AlphaVantage: No price found for #{symbol} on #{date}")
          raise InvalidSecurityPriceError, "No prices found for security #{symbol} on date #{date}"
        end
        price = prices.first
        Rails.logger.info("AlphaVantage: Found price: #{price}")
        price
      else
        Rails.logger.error("AlphaVantage: Failed to fetch single price: #{historical_data_response.error}")
        raise historical_data_response.error
      end
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
    # Fetch currency from overview
    profile = fetch_overview_raw(symbol)
    Rails.logger.info("AlphaVantage: profile (#{profile}")

    if profile.empty?
      Rails.logger.info("AlphaVantage: No overview profile found for #{symbol}, trying SYMBOL_SEARCH fallback")
      search_data = fetch_symbol_search_raw(symbol)

      matches = search_data[KEY_BEST_MATCHES]
      match = matches&.find { |m| m[KEY_SYMBOL] == symbol } || matches&.first
      currency = match[KEY_CURRENCY]
    else
      currency = profile[KEY_OVERVIEW_CURRENCY]
    end
    if start_date < 100.days.ago.to_date
      Rails.logger.warn("AlphaVantage: start_date (#{start_date}) for #{symbol} is older than 100 days. 'compact' output may not contain required data.")
    end

    Rails.logger.info("AlphaVantage: Fetching daily time series for #{symbol} from #{start_date} to #{end_date} (compact)")

    parsed = request_api(
      function: FUNC_TIME_SERIES_DAILY,
      symbol: symbol,
      outputsize: "compact"
    )

    values = parsed[KEY_TIME_SERIES_DAILY]
    ensure_data_exists!(values, parsed, InvalidSecurityPriceError, "No time series data")

    results = values.map do |date_str, resp|
      date = Date.parse(date_str)
      next unless date >= start_date && date <= end_date

      price = resp[KEY_CLOSE]
      if price.nil? || price.to_f <= 0
        Rails.logger.warn("AlphaVantage: Invalid price data for #{symbol} on #{date}: #{price.inspect}")
        next
      end

      Price.new(
        symbol: symbol,
        date: date,
        price: price.to_f,
        currency: currency,
        exchange_operating_mic: exchange_operating_mic
      )
    end.compact

    Rails.logger.info("AlphaVantage: Successfully fetched #{results.length} price points for #{symbol}")
    results
  end
end

  private
    attr_reader :api_key

    def fetch_overview_raw(symbol)
      Rails.logger.info("AlphaVantage: Fetching security info (overview) for #{symbol}")
      request_api(function: FUNC_OVERVIEW, symbol: symbol)
    end

    def fetch_symbol_search_raw(symbol)
      Rails.logger.info("AlphaVantage: Searching securities for keywords: #{symbol}")
      request_api(function: FUNC_SYMBOL_SEARCH, keywords: symbol)
    end

    def request_api(function:, **params)
      sleep(1.1) # Get around 1 req/s limitations

      response = client.get("/query") do |req|
        req.params["function"] = function
        params.each { |k, v| req.params[k.to_s] = v }
      end

      parsed = JSON.parse(response.body)

      if parsed[KEY_ERROR_MESSAGE]
        Rails.logger.error("AlphaVantage: API Error - #{parsed[KEY_ERROR_MESSAGE]}")
        raise Error, "API error: #{parsed[KEY_ERROR_MESSAGE]}"
      end

      parsed
    end

    def ensure_data_exists!(data, parsed, error_class = Error, default_message = "No data returned")
      if data.nil?
        message = parsed[KEY_NOTE] || default_message
        Rails.logger.warn("AlphaVantage: #{default_message} - #{message}")
        raise error_class, "API error: #{message}"
      end
    end

    def base_url
      ENV["ALPHA_VANTAGE_URL"] || "https://www.alphavantage.co"
    end

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        # Retry must be first (outermost) to catch errors from inner middlewares
        faraday.request(:retry, {
          max: 2,
          interval: 1.1, # Increased to > 1s to respect "1 request per second"
          interval_randomness: 0.5,
          backoff_factor: 2
        })

        faraday.request :json

        # Response middleware stack (Execution order on return: Bottom -> Top)

        # 2. RaiseError (Checks Status)
        faraday.response :raise_error

        # 1. Logger (Logs String) - Runs first on return (closest to network)
        faraday.response :logger, Rails.logger, { headers: true, bodies: true } do |logger|
          logger.filter(/apikey=([^&]+)/, "apikey=[FILTERED]")
        end

        faraday.params["apikey"] = api_key
      end
    end
end


