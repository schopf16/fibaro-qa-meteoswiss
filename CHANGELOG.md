# Changelog

All notable changes to this QuickApp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/schopf16/fibaro-qa-meteoswiss/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/schopf16/fibaro-qa-meteoswiss/releases/tag/v1.0.0
