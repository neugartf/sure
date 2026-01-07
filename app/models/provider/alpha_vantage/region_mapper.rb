require "countries"

module Provider::AlphaVantage::RegionMapper
  # Manual mapping for cases where Alpha Vantage returns a city or exchange name
  EXCHANGE_MAPPING = {
    "Frankfurt"      => "DE",
    "XETRA"          => "DE",
    "Dusseldorf"     => "DE",
    "Berlin"         => "DE",
    "Munich"         => "DE",
    "Stuttgart"      => "DE",
    "Tokyo"          => "JP",
    "London"         => "GB",
    "Toronto"        => "CA",
    "Paris"          => "FR",
    "Amsterdam"      => "NL",
    "Brussels"       => "BE",
    "Lisbon"         => "PT",
    "Hong Kong"      => "HK",
    "Shanghai"       => "CN",
    "Shenzhen"       => "CN",
    "Bolsa de Madrid"=> "ES",
    "Milan"          => "IT",
    "Sao Paulo"      => "BR",
    "Mexico"         => "MX",
    "Mumbai"         => "IN"
  }.freeze

  def self.to_iso_code(region_string)
    return nil if region_string.nil? || region_string.empty?

    # 1. Check if it's a known city/exchange in our manual map
    return EXCHANGE_MAPPING[region_string] if EXCHANGE_MAPPING.key?(region_string)
    # 2. Try to find it as a standard country name using the 'countries' gem
    country = ISO3166::Country.find_country_by_any_name(region_string)
    return country.alpha2 if country

    # 3. Fallback: Handle common variations manually or return the original
    case region_string
    when "USA", "United States" then "US"
    when "UK" then "GB"
    else nil # Or handle unknown regions
    end
  end
end

