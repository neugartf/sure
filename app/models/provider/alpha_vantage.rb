class Provider::AlphaVantage < Provider
  include ExchangeRateConcept, SecurityConcept

  # Subclass so errors caught in this provider are raised as Provider::AlphaVantage::Error
  Error = Class.new(Provider::Error)
  InvalidExchangeRateError = Class.new(Error)
  InvalidSecurityPriceError = Class.new(Error)

  def initialize(api_key)
    @api_key = api_key
  end

  def healthy?
    with_provider_response do
      Rails.logger.info("AlphaVantage: Checking health...")
      response = client.get("/query") do |req|
        req.params["function"] = "CURRENCY_EXCHANGE_RATE"
        req.params["from_currency"] = "USD"
        req.params["to_currency"] = "EUR"
      end

      parsed = JSON.parse(response.body)
      is_healthy = parsed.key?("Realtime Currency Exchange Rate") && !parsed.key?("Error Message")
      Rails.logger.info("AlphaVantage: Health check result: #{is_healthy}")
      is_healthy
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

      sleep(1.1) # Get around 1 req/s limitations
      Rails.logger.info("AlphaVantage: Fetching daily FX for #{from}/#{to} from #{start_date} to #{end_date} (compact)")
      response = client.get("/query") do |req|
        req.params["function"] = "FX_DAILY"
        req.params["from_symbol"] = from
        req.params["to_symbol"] = to
        req.params["outputsize"] = "compact"
      end

      parsed = JSON.parse(response.body)

      if parsed["Error Message"]
        Rails.logger.error("AlphaVantage: API Error - #{parsed['Error Message']}")
        raise InvalidExchangeRateError, "API error: #{parsed['Error Message']}"
      end

      data = parsed["Time Series FX (Daily)"]

      if data.nil?
        message = parsed["Note"] || "No data returned"
        Rails.logger.warn("AlphaVantage: No data or rate limited - #{message}")
        raise InvalidExchangeRateError, "API error: #{message}"
      end

      results = data.map do |date_str, values|
        date = Date.parse(date_str)
        next unless date >= start_date && date <= end_date

        rate = values["4. close"]
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

      if parsed["Error Message"]
        Rails.logger.error("AlphaVantage: Search Error - #{parsed['Error Message']}")
        raise Error, "API error: #{parsed['Error Message']}"
      end

      data = parsed["bestMatches"]

      if data.nil?
        message = parsed["Note"] || "No data returned"
        Rails.logger.warn("AlphaVantage: Search yielded no data - #{message}")
        raise Error, "API error: #{message}"
      end

      results = data.map do |security|
        country = ISO3166::Country.find_country_by_any_name(security["4. region"])

        Security.new(
          symbol: security["1. symbol"],
          name: security["2. name"],
          logo_url: nil,
          exchange_operating_mic: nil,
          country_code: country ? country.alpha2 : nil
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

        if search_data["Error Message"]
          Rails.logger.error("AlphaVantage: Search Error (Fallback) - #{search_data['Error Message']}")
          raise Error, "API error: #{search_data['Error Message']}"
        end

        matches = search_data["bestMatches"]
        match = matches&.find { |m| m["1. symbol"] == symbol } || matches&.first

        if match
          SecurityInfo.new(
            symbol: match["1. symbol"],
            name: match["2. name"],
            links: nil,
            logo_url: nil,
            description: nil,
            kind: match["3. type"],
            exchange_operating_mic: exchange_operating_mic
          )
        else
          Rails.logger.warn("AlphaVantage: No profile data found for #{symbol} (and fallback failed)")
          raise Error, "No profile data found for symbol #{symbol}"
        end
      elsif profile["Error Message"]
        Rails.logger.error("AlphaVantage: Info Error - #{profile['Error Message']}")
        raise Error, "API error: #{profile['Error Message']}"
      else
        SecurityInfo.new(
          symbol: symbol,
          name: profile["Name"],
          links: nil,
          logo_url: nil,
          description: profile["Description"],
          kind: profile["AssetType"],
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
        Rails.logger.info("AlphaVantage: Found price: #{price.price}")
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
      currency = profile["Currency"]

      if start_date < 100.days.ago.to_date
        Rails.logger.warn("AlphaVantage: start_date (#{start_date}) for #{symbol} is older than 100 days. 'compact' output may not contain required data.")
      end

      sleep(1.1) # Get around 1 req/s limitations
      Rails.logger.info("AlphaVantage: Fetching daily time series for #{symbol} from #{start_date} to #{end_date} (compact)")
      response = client.get("/query") do |req|
        req.params["function"] = "TIME_SERIES_DAILY"
        req.params["symbol"] = symbol
        req.params["outputsize"] = "compact"
      end

      parsed = JSON.parse(response.body)

      if parsed["Error Message"]
        Rails.logger.error("AlphaVantage: Time Series Error - #{parsed['Error Message']}")
        raise InvalidSecurityPriceError, "API error: #{parsed['Error Message']}"
      end

      values = parsed["Time Series (Daily)"]

      if values.nil?
        message = parsed["Note"] || "No data returned"
        Rails.logger.warn("AlphaVantage: No time series data - #{message}")
        raise InvalidSecurityPriceError, "API error: #{message}"
      end

      results = values.map do |date_str, resp|
        date = Date.parse(date_str)
        next unless date >= start_date && date <= end_date

        price = resp["4. close"]
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
      sleep(1.1) # Get around 1 req/s limitations
      Rails.logger.info("AlphaVantage: Fetching security info (overview) for #{symbol}")
      response = client.get("/query") do |req|
        req.params["function"] = "OVERVIEW"
        req.params["symbol"] = symbol
      end

      JSON.parse(response.body)
    end

    def fetch_symbol_search_raw(symbol)
      sleep(1.1) # Get around 1 req/s limitations
      Rails.logger.info("AlphaVantage: Searching securities for keywords: #{symbol}")
      response = client.get("/query") do |req|
        req.params["function"] = "SYMBOL_SEARCH"
        req.params["keywords"] = symbol
      end

      JSON.parse(response.body)
    end

    def base_url
      ENV["ALPHA_VANTAGE_URL"] || "https://www.alphavantage.co"
    end

    def client
      @client ||= Faraday.new(url: base_url) do |faraday|
        # Retry must be first (outermost) to catch errors from inner middlewares
        faraday.request(:retry, {
          max: 5, # Increased from 2 to handle rate limits better
          interval: 1.1, # Increased to > 1s to respect "1 request per second"
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: [ Faraday::ConnectionFailed, Faraday::TimeoutError ]
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
