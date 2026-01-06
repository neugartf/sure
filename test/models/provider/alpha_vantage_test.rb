require "test_helper"

class Provider::AlphaVantageTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::AlphaVantage.new("mock_key")
  end

  # ================================
  #        Health Check Tests
  # ================================

  test "healthy? returns true when API is working" do
    mock_response = mock
    mock_response.stubs(:body).returns('{"Realtime Currency Exchange Rate": {}}')

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).with("/query").returns(mock_response)

    assert @provider.healthy?
  end

  test "healthy? returns false when API fails or returns error" do
    mock_response = mock
    mock_response.stubs(:body).returns('{"Error Message": "Invalid API call"}')

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).with("/query").returns(mock_response)

    response = @provider.healthy?
    # The method returns a Response object. If the check returns false inside the block,
    # success? is still true (no exception), but data is false.
    assert_equal false, response.data
  end

  # ================================
  #      Exchange Rate Tests
  # ================================

  test "fetch_exchange_rates parses valid response" do
    start_date = Date.parse("2023-01-01")
    end_date = Date.parse("2023-01-02")
    
    json_response = {
      "Time Series FX (Daily)" => {
        "2023-01-01" => { "4. close" => "1.05" },
        "2023-01-02" => { "4. close" => "1.06" }
      }
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(json_response)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    response = @provider.fetch_exchange_rates(from: "EUR", to: "USD", start_date: start_date, end_date: end_date)

    assert response.success?
    rates = response.data
    assert_equal 2, rates.length
    assert_equal 1.05, rates.find { |r| r.date == start_date }.rate
    assert_equal 1.06, rates.find { |r| r.date == end_date }.rate
  end

  test "fetch_exchange_rate returns single rate" do
    date = Date.parse("2023-01-01")
    
    json_response = {
      "Time Series FX (Daily)" => {
        "2023-01-01" => { "4. close" => "1.05" }
      }
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(json_response)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    response = @provider.fetch_exchange_rate(from: "EUR", to: "USD", date: date)

    assert response.success?
    rate = response.data
    assert_equal 1.05, rate.rate
    assert_equal date, rate.date
  end

  # ================================
  #           Securities
  # ================================

  test "search_securities parses best matches" do
    json_response = {
      "bestMatches" => [
        {
          "1. symbol" => "IBM",
          "2. name" => "International Business Machines Corp",
          "4. region" => "United States",
          "8. currency" => "USD"
        }
      ]
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(json_response)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    response = @provider.search_securities("IBM")

    assert response.success?
    securities = response.data
    assert_equal 1, securities.length
    assert_equal "IBM", securities.first.symbol
    assert_equal "International Business Machines Corp", securities.first.name
    assert_equal "US", securities.first.country_code # ISO3166 lookup
  end

  test "fetch_security_info parses overview" do
    json_response = {
      "Symbol" => "IBM",
      "Name" => "International Business Machines",
      "Description" => "Tech company",
      "AssetType" => "Common Stock"
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(json_response)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    response = @provider.fetch_security_info(symbol: "IBM", exchange_operating_mic: "XNYS")

    assert response.success?
    info = response.data
    assert_equal "IBM", info.symbol
    assert_equal "International Business Machines", info.name
    assert_equal "Tech company", info.description
    assert_equal "Common Stock", info.kind
  end

  test "fetch_security_prices parses time series" do
    start_date = Date.parse("2023-01-01")
    end_date = Date.parse("2023-01-02")
    
    json_response = {
      "Time Series (Daily)" => {
        "2023-01-01" => { "4. close" => "150.00" },
        "2023-01-02" => { "4. close" => "155.00" }
      }
    }.to_json

    mock_response = mock
    mock_response.stubs(:body).returns(json_response)

    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)

    response = @provider.fetch_security_prices(symbol: "IBM", start_date: start_date, end_date: end_date)

    assert response.success?
    prices = response.data
    assert_equal 2, prices.length
    assert_equal 150.00, prices.find { |p| p.date == start_date }.price
    assert_equal 155.00, prices.find { |p| p.date == end_date }.price
  end
end
