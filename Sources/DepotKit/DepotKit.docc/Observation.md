# Observation

React to depot changes with AsyncSequence, Combine, or SwiftUI property wrappers.

## Overview

DepotKit supports three observation styles, each suited to a different context. All three are driven by the same underlying notification mechanism — when a value changes, every active observer for that key is notified.

## AsyncSequence

The ``Depot/values(for:initialValue:)`` method returns an `AsyncStream` that emits the current value followed by every subsequent change. The stream uses `.bufferingNewest(1)`, so slow consumers always see the latest value rather than queuing up stale ones.

```swift
for await result in depot.values(for: currentForecastKey) {
    switch result {
    case .success(let forecast):
        updateWidget(with: forecast)
    case .failure(let error):
        log("Observation error: \(error)")
    }
}
```

Each emission is a `Result<V?, Error>` — `.success(nil)` means the value was removed or expired, `.failure` means the read or decode failed.

### Pattern Observation

Observe all values matching a pattern key. The stream emits the full array of matching values whenever any of them changes:

```swift
for await result in depot.values(for: allForecastsKey) {
    switch result {
    case .success(let forecasts):
        // forecasts: [Forecast] — every location's current forecast
        refreshUI(with: forecasts)
    case .failure(let error):
        log("Observation error: \(error)")
    }
}
```

### Partial-Success Observation

Use ``Depot/availableValues(for:initialValues:)`` when you want per-key error granularity instead of an all-or-nothing array:

```swift
for await result in depot.availableValues(for: allForecastsKey) {
    switch result {
    case .success(let available):
        // available.values  → [Forecast] — decoded successfully
        // available.errors  → [DistinctKey: Error] — per-key failures
        refreshUI(with: available.values)
        for (key, error) in available.keyedErrors {
            log("Failed to decode \(key.keyPath): \(error)")
        }
    case .failure(let error):
        log("Fatal observation error: \(error)")
    }
}
```

### Suppressing the Initial Value

By default, streams emit the current value immediately. Pass `initialValue: false` (or `initialValues: false` for pattern keys) to receive only future changes:

```swift
for await result in depot.values(for: key, initialValue: false) {
    // Only fires on writes that happen after this stream was created
}
```

### Waiting for Observers to Settle

In tests, use ``Depot/waitForPendingObservations()`` to ensure all observer callbacks have been delivered before asserting:

```swift
try await depot.set(value: newForecast, for: forecastKey)
await depot.waitForPendingObservations()
// Now it's safe to assert that the observer received the value
```

## Combine (DepotKitCombine)

The `DepotKitCombine` module provides Combine publishers for depot observation. Import it alongside `DepotKit`:

```swift
import DepotKit
import DepotKitCombine
```

### Single-Value Publisher

```swift
var cancellables = Set<AnyCancellable>()

// Raw Result publisher — never fails, you handle errors in the Result
depot.published(valueFor: themeKey)
    .compactMap { try? $0.get() }
    .receive(on: DispatchQueue.main)
    .sink { theme in
        self.applyTheme(theme)
    }
    .store(in: &cancellables)
```

### Error-Handling Publisher

The error-handling variant unwraps the `Result` for you. An `ErrorHandlingDecision` closure decides how to handle each error:

```swift
depot.published(
    valueFor: themeKey,
    errorHandler: { error, isInitial in
        if isInitial {
            return .replaceWith("light")   // default theme on first read
        }
        return .skip                       // ignore transient errors
    }
)
.receive(on: DispatchQueue.main)
.assign(to: &$theme)
```

The three decisions are:
- `.skip` — swallow the error, emit nothing
- `.replaceWith(_:)` — emit a fallback value
- `.complete(_:)` — terminate the publisher

### Multi-Value Publisher

Observe all values matching a pattern:

```swift
depot.published(valuesFor: allForecastsKey)
    .receive(on: DispatchQueue.main)
    .sink(
        receiveCompletion: { _ in },
        receiveValue: { result in
            switch result {
            case .success(let forecasts):
                self.forecasts = forecasts
            case .failure(let error):
                self.handleError(error)
            }
        }
    )
    .store(in: &cancellables)
```

### Feeding @Published Properties

```swift
class SettingsViewModel: ObservableObject {
    @Published var theme: String?

    init(depot: Depot, themeKey: TypedDistinctKey<String>) {
        depot.published(valueFor: themeKey, errorHandler: { _, isInitial in
            isInitial ? .replaceWith(nil) : .skip
        })
        .receive(on: DispatchQueue.main)
        .assign(to: &$theme)
    }
}
```

> Important: Depot publishers may emit on **any thread**. Always use `.receive(on: DispatchQueue.main)` when driving UI.

## SwiftUI (DepotKitObservation)

The `DepotKitObservation` module provides two property wrappers that bridge depot observation directly into SwiftUI's view update cycle.

### @DepotValue — Single Value

`@DepotValue` observes a single distinct key and triggers view updates when the value changes:

```swift
import DepotKit
import DepotKitObservation

struct WeatherCard: View {
    @DepotValue(key: conditionsKey, depot: depot)
    var conditions: WeatherConditions?

    var body: some View {
        Text(conditions?.temperature.formatted() ?? "—")
    }
}
```

The `$` projected value is a `Binding<Value?>`, suitable for two-way bindings:

```swift
struct SettingsView: View {
    @DepotValue(key: notificationsKey, depot: depot)
    var enabled: Bool?

    var body: some View {
        Toggle("Notifications", isOn: Binding(
            get: { enabled ?? false },
            set: { $enabled.wrappedValue = $0 }
        ))
    }
}
```

Writing through the binding dispatches an asynchronous write. If the write fails, the error is available on the `error` property.

You can also initialise from a ``KeyDefinition``, which registers the key automatically:

```swift
@DepotValue(definition: WeatherKeys.units, depot: depot)
var units: UnitPreferences?
```

### @DepotValues — Multiple Values

`@DepotValues` observes a pattern key and delivers all matching values as an array:

```swift
struct ForecastList: View {
    @DepotValues(key: allForecastsKey, depot: depot)
    var forecasts: [Forecast]

    var body: some View {
        List(forecasts, id: \.locationId) { forecast in
            ForecastRow(forecast: forecast)
        }
    }
}
```

Like `@DepotValue`, it supports initialisation from a ``PatternKeyDefinition``:

```swift
@DepotValues(definition: WeatherKeys.forecast, depot: depot)
var forecasts: [Forecast]
```

### Error Handling in SwiftUI

Both wrappers expose an `error` property. Access it through the underscore-prefixed storage:

```swift
struct WeatherCard: View {
    @DepotValue(key: conditionsKey, depot: depot)
    var conditions: WeatherConditions?

    var body: some View {
        if let error = _conditions.error {
            Text("Error: \(error.localizedDescription)")
        } else {
            Text(conditions?.temperature.formatted() ?? "Loading…")
        }
    }
}
```

> Important: The key must be registered with the depot **before** the view is created, unless you use the `definition:` initialiser which registers it for you.
