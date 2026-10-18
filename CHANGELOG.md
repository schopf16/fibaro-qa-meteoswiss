# Changelog

All notable changes to this QuickApp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- No forecast arrived any more: the service answers in XML unless JSON is
  requested explicitly. The request now asks for JSON, and an answer of
  another content type is rejected with a clear reason.
- A request that never answered could block all further updates. It is now
  abandoned after 30 seconds and retried.

### Changed

- A single failed request is no longer logged as a warning. If no forecast has
  arrived for one hour, one error with the duration, the number of failed
  requests and the last reason is logged, repeated every six hours; the end of
  the outage is logged as well. The status keeps "Forecast updated at ..."
  during shorter interruptions.

## [1.0.1] - 2026-10-06

### Fixed

- A general postal code such as 3000 or 8000, which the forecast service does
  not know, only showed "Forecast unavailable". The QuickApp now shows
  "Postal code unknown - please check" and logs how to choose the code.

## [1.0.0] - 2026-10-06

### Added

- Weather forecasts for a Swiss postal code (data: MeteoSwiss), refreshed every
  five minutes.
- Forecast tables at 10-minute, hourly, three-hour and daily resolution as JSON
  in the QuickApp variables `forecast10m`, `forecastHourly`, `forecast3h` and
  `forecastDaily`, all with the same structure.
- Four child devices for scene triggers: rain expected, strong wind expected,
  nice weather today and tomorrow, with configurable thresholds.
- HC3 weather properties: temperature and gust of the next hour, and a derived
  weather condition.
- User interface in English, German, French and Italian.

[Unreleased]: https://github.com/schopf16/fibaro-qa-meteoswiss/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/schopf16/fibaro-qa-meteoswiss/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/schopf16/fibaro-qa-meteoswiss/releases/tag/v1.0.0
