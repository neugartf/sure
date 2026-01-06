require "test_helper"

class Provider::AlphaVantageEtfTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::AlphaVantage.new("mock_key")
  end

  test "fetch_security_info falls back to SYMBOL_SEARCH when OVERVIEW is empty (e.g. for ETFs)" do
    symbol = "VTI"
    
    # Mock OVERVIEW returning empty (as it might for some ETFs or if not supported)
    mock_overview_response = mock
    mock_overview_response.stubs(:body).returns("{}")

    # Mock SYMBOL_SEARCH finding the ETF
    json_search_response = {
      "bestMatches" => [
        {
          "1. symbol" => "VTI",
          "2. name" => "Vanguard Total Stock Market ETF",
          "3. type" => "ETF",
          "4. region" => "United States",
          "8. currency" => "USD"
        }
      ]
    }.to_json

    mock_search_response = mock
    mock_search_response.stubs(:body).returns(json_search_response)

    @provider.stubs(:client).returns(mock_client = mock)

    # We expect two calls. 
    # The mocks just return the responses in sequence.
    # We rely on the implementation calling them in order: OVERVIEW first, then SYMBOL_SEARCH.
    mock_client.stubs(:get).returns(mock_overview_response).then.returns(mock_search_response)

    response = @provider.fetch_security_info(symbol: symbol, exchange_operating_mic: "XNYS")

    assert response.success?
    info = response.data
    assert_equal "VTI", info.symbol
    assert_equal "Vanguard Total Stock Market ETF", info.name
    assert_equal "ETF", info.kind
    assert_nil info.description # fallback won't have description
  end
end