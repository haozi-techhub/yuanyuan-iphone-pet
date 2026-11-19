import Foundation

nonisolated struct PetWeather {
    static let cityPreference = "pet.weatherCity"

    enum Period: Int, Sendable {
        case now = -1, today = 0, tomorrow, dayAfterTomorrow

        var label: String {
            switch self {
            case .now: "现在"
            case .today: "今天"
            case .tomorrow: "明天"
            case .dayAfterTomorrow: "后天"
            }
        }
    }

    struct Query: Sendable {
        var city: String?
        let period: Period
    }

    enum LookupError: Error {
        case cityNotFound, noForecast
    }

    private struct CitySearch: Decodable {
        let results: [City]?
    }

    private struct City: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let timezone: String
    }

    private struct Forecast: Decodable {
        struct Properties: Decodable {
            let timeseries: [Point]
        }

        struct Point: Decodable {
            struct Data: Decodable {
                struct Instant: Decodable {
                    struct Details: Decodable { let air_temperature: Double }
                    let details: Details
                }

                struct Window: Decodable {
                    struct Summary: Decodable { let symbol_code: String }
                    struct Details: Decodable {
                        let precipitation_amount: Double?
                        let air_temperature_min: Double?
                        let air_temperature_max: Double?
                    }
                    let summary: Summary?
                    let details: Details?
                }

                let instant: Instant
                let next_1_hours: Window?
                let next_6_hours: Window?
            }

            let time: Date
            let data: Data
        }

        let properties: Properties
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    static func query(in text: String) -> Query? {
        let phrase = text.replacingOccurrences(of: #"[\s，,。.!！?？]+"#, with: "", options: .regularExpression)
        let pattern = #/^(?:(?:请问|请|帮我|给我|想知道|查一下|查查|看看|查))*(?<first>今天|明天|后天|现在|目前)?(?<city>[\p{Han}A-Za-z·]{1,24}?)?(?<second>今天|明天|后天|现在|目前)?(?:的)?(?:天气(?:预报|怎么样|如何|好不好|是什么)?|气温(?:多少度|多少|怎么样)?|多少度|(?:会不会|会|要)?下[雨雪](?:吗|不|了没)?|要(?:不要)?带伞)(?:呀|啊|呢|吗)?$/#
        guard let match = phrase.wholeMatch(of: pattern) else { return nil }
        let period: Period = switch match.first ?? match.second {
        case "明天": Period.tomorrow
        case "后天": Period.dayAfterTomorrow
        case "今天": Period.today
        case "现在", "目前": Period.now
        default: phrase.contains("下雨") || phrase.contains("下雪") || phrase.contains("带伞") ? .today : .now
        }
        let city = match.city.flatMap { cityName(in: String($0)) }
        return Query(city: city, period: period)
    }

    static func cityName(in text: String) -> String? {
        var city = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if city.hasPrefix("我在") { city.removeFirst(2) }
        if city.hasSuffix("市"), city.count > 2 { city.removeLast() }
        guard !["本地", "当地", "这里", "这儿", "我这", "我这里", "我这边", "我们这", "我们这里", "我们这边"].contains(city),
              city.wholeMatch(of: #/[\p{Han}A-Za-z·][\p{Han}A-Za-z· .-]{1,29}/#) != nil else { return nil }
        return city
    }

    static func fetch(city name: String, period: Period) async throws -> String {
        let taiwanCities = [
            "台北": "Taipei", "新北": "Banqiao", "桃园": "Taoyuan", "台中": "Taichung",
            "台南": "Tainan", "高雄": "Kaohsiung", "基隆": "Keelung", "新竹": "Hsinchu",
            "嘉义": "Chiayi", "花莲": "Hualien", "台东": "Taitung", "宜兰": "Yilan"
        ]
        let taiwanName = taiwanCities[name.replacingOccurrences(of: "臺", with: "台")]
        var locationQuery = ["name": taiwanName ?? name, "count": "1", "language": "zh"]
        if taiwanName != nil { locationQuery["countryCode"] = "TW" }
        let search: CitySearch = try await get("https://geocoding-api.open-meteo.com/v1/search", query: locationQuery)
        guard let city = search.results?.first else { throw LookupError.cityNotFound }
        let displayName = taiwanName == nil ? city.name : name

        guard let timezone = TimeZone(identifier: city.timezone) else { throw LookupError.noForecast }
        let forecastQuery = ["lat": coordinate(city.latitude), "lon": coordinate(city.longitude)]
        let response: Forecast = try await get("https://api.met.no/weatherapi/locationforecast/2.0/compact",
                                              query: forecastQuery)
        return try summary(response.properties.timeseries, city: displayName, period: period,
                           timezone: timezone, now: Date())
    }

    private static func summary(_ points: [Forecast.Point], city: String, period: Period,
                                timezone: TimeZone, now: Date) throws -> String {
        if period == .now {
            guard let closest = points.min(by: { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) }),
                  abs(closest.time.timeIntervalSince(now)) <= 3_600 else { throw LookupError.noForecast }
            let weather = condition(closest.data.next_1_hours?.summary?.symbol_code
                                    ?? closest.data.next_6_hours?.summary?.symbol_code)
            let temperature = degrees(closest.data.instant.details.air_temperature)
            return "\(city)现在预报\(weather)，约\(temperature)度。"
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        guard let date = calendar.date(byAdding: .day, value: period.rawValue, to: now),
              let day = calendar.dateInterval(of: .day, for: date) else { throw LookupError.noForecast }
        let start = period == .today ? now : day.start
        var temperatures: [Double] = []
        var rainAmounts: [Double] = []
        var symbols: [String] = []
        for point in points where point.time < day.end {
            if point.time >= start { temperatures.append(point.data.instant.details.air_temperature) }
            let isHourly = point.data.next_1_hours != nil
            let hours: TimeInterval = isHourly ? 3_600 : 21_600
            guard point.time.addingTimeInterval(hours) > start,
                  let window = point.data.next_1_hours ?? point.data.next_6_hours else { continue }
            if let symbol = window.summary?.symbol_code { symbols.append(symbol) }
            if let amount = window.details?.precipitation_amount { rainAmounts.append(amount) }
            if point.time >= start, point.time.addingTimeInterval(hours) <= day.end {
                if let low = window.details?.air_temperature_min { temperatures.append(low) }
                if let high = window.details?.air_temperature_max { temperatures.append(high) }
            }
        }
        let label = period == .today ? "今天接下来" : period.label
        let weather: String
        if symbols.contains(where: { $0.contains("thunder") }) {
            weather = "可能有雷雨"
        } else if symbols.contains(where: { $0.contains("snow") || $0.contains("sleet") }) {
            weather = "可能有雨雪"
        } else if symbols.contains(where: { $0.contains("rain") }) || rainAmounts.contains(where: { $0 > 0 }) {
            weather = "可能有雨"
        } else {
            weather = condition(symbols.first)
        }
        if let low = temperatures.min(), let high = temperatures.max() {
            let range = degrees(low) == degrees(high)
                ? "约\(degrees(low))度"
                : "\(degrees(low))到\(degrees(high))度"
            return "\(city)\(label)\(weather)，\(range)。"
        }
        guard !symbols.isEmpty else { throw LookupError.noForecast }
        return "\(city)\(label)\(weather)。"
    }

    private static func coordinate(_ number: Double) -> String {
        let truncated = (number * 10_000).rounded(.towardZero) / 10_000
        return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), truncated)
    }

    private static func degrees(_ temperature: Double) -> String {
        let value = Int(temperature.rounded())
        return value < 0 ? "零下\(-value)" : String(value)
    }

    private static func get<T: Decodable>(_ endpoint: String, query: [String: String]) async throws -> T {
        var url = URLComponents(string: endpoint)!
        url.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        guard let requestURL = url.url else { throw LookupError.noForecast }
        var request = URLRequest(url: requestURL)
        request.setValue("YuanyuanDesktopPet/1.0 (https://github.com/haozi-techhub/yuanyuan-iphone-pet)",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw LookupError.noForecast }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private static func condition(_ code: String?) -> String {
        guard let code else { return "天气状况暂不明确" }
        if code.contains("thunder") { return "有雷雨" }
        if code.contains("sleet") { return "有雨夹雪" }
        if code.contains("snow") { return "有雪" }
        if code.contains("rain") { return "有雨" }
        if code.contains("cloudy") { return "多云" }
        if code.contains("fog") { return "有雾" }
        if code.contains("clearsky") || code.contains("fair") { return "晴" }
        return "天气状况暂不明确"
    }
}
