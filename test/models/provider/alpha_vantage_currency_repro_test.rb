require "test_helper"

class Provider::AlphaVantageCurrencyReproTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::AlphaVantage.new("mock_key")
  end

  test "fetch_security_prices includes currency in Price objects" do
    start_date = Date.parse("2023-01-01")
    end_date = Date.parse("2023-01-01")
    
    overview_json = {
      "Symbol" => "IBM",
      "Currency" => "USD"
    }.to_json

    timeseries_json = {
      "Time Series (Daily)" => {
        "2023-01-01" => { "4. close" => "150.00" }
      }
    }.to_json

    mock_overview_response = mock
    mock_overview_response.stubs(:body).returns(overview_json)

    mock_timeseries_response = mock
    mock_timeseries_response.stubs(:body).returns(timeseries_json)

    @provider.stubs(:client).returns(mock_client = mock)
    # The client is called twice. We return overview first, then timeseries.
    mock_client.stubs(:get).returns(mock_overview_response).then.returns(mock_timeseries_response)

    response = @provider.fetch_security_prices(symbol: "IBM", start_date: start_date, end_date: end_date)

    assert response.success?
    prices = response.data
    assert_not_empty prices
    price = prices.first
    assert_not_nil price.currency, "Currency should not be nil"
    assert_equal "USD", price.currency
  end
end
