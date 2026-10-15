# Observation

React to depot changes with AsyncSequence, Combine, or SwiftUI property wrappers.

## Overview

DepotKit supports three observation styles, each suited to a different context. All three are driven by the same underlying notification mechanism — when a value changes, every active observer for that key is notified.

Observation delivers the **latest state**, not a log of events. Notifications are delivered in commit order, so once writes have settled every active observer has received the current value. A slow consumer, however, can skip intermediate values: streams keep only the newest pending element, and Combine publishers conflate values while the subscriber has no outstanding demand. If you need every change, record it explicitly — for example by appending to a stored list inside a transaction.

## AsyncSequence

The ``Depot/values(for:initialValue:)`` method returns an `AsyncStream` that emits the current value followed by the latest value after each change. The stream uses `.bufferingNewest(1)`, so slow consumers see the latest value rather than queuing up stale ones.

```swift
for await result in depot.values(for: unitsKey) {
    switch result {
    case .success(let units):
        apply(units)
    case .failure(let error):
        print("Observation error: \(error)")
    }
}
```

Each emission is a `Result<V?, Error>` — `.success(nil)` means the value was removed or has expired, `.failure` means the read or decode failed. Expiry itself does not trigger a notification: observers receive `nil` when an expiry sweep (``Depot/removeExpired()-1gvix``) removes the value, not at the exact expiry time.

The loop runs until the surrounding task is cancelled. Start it in a `Task` you keep a reference to, or in SwiftUI's `.task` modifier, and cancel it when you no longer need updates.

Removal notifications are sent only for keys whose values were actually removed. Removing a pattern that matches no stored value notifies nobody; removing a distinct key always notifies that key's observers. Pattern observers are notified when any removed key matches their pattern, including when the removal used a different, crossing pattern (for example observing `users/*/name` while removing `users/alice/*`).

### Pattern Observation

Observe all values matching a pattern key. The stream emits the full array of matching values whenever any of them changes. The order of the values is unspecified; sort them if you need a stable order:

```swift
for await result in depot.values(for: forecastsKey) {
    switch result {
    case .success(let forecasts):
        // forecasts: [Forecast] — every city's current forecast
        refresh(with: forecasts)
    case .failure(let error):
        print("Observation error: \(error)")
    }
}
```

### Partial-Success Observation

Use ``Depot/availableValues(for:initialValues:)`` when you want per-key error granularity instead of an all-or-nothing array:

```swift
for await result in depot.availableValues(for: forecastsKey) {
    switch result {
    case .success(let available):
        // available.values      → [Forecast] — decoded successfully
        // available.keyedErrors → [DistinctKey: any Error & Sendable] — per-key failures
        refresh(with: available.values)
        for (key, error) in available.keyedErrors {
            print("Failed to decode \(key.keyPath): \(error)")
        }
    case .failure(let error):
        print("Fatal observation error: \(error)")
    }
}
```

``AvailableValuesResult`` also offers ``AvailableValuesResult/keyedValues`` (values by key) and ``AvailableValuesResult/errors`` (errors without their keys).

### Suppressing the Initial Value

By default, streams emit the current value immediately. Pass `initialValue: false` (or `initialValues: false` for pattern keys) to receive only future changes:

```swift
for await result in depot.values(for: unitsKey, initialValue: false) {
    // Only fires on writes that happen after this stream was created
}
```

### Waiting for Observers to Settle

In tests, use ``Depot/waitForPendingObservations()`` to ensure all observer callbacks have been delivered before asserting:

```swift
try await depot.set(value: newUnits, for: unitsKey)
await depot.waitForPendingObservations()
// Now it's safe to assert that the observer received the value
```

## Combine (DepotKitCombine)

The `DepotKitCombine` module provides Combine publishers for depot observation. Import it alongside `DepotKit`:

```swift
import Combine
import DepotKit
import DepotKitCombine
```

### Single-Value Publisher

The basic publisher emits a `Result` and never fails — you handle errors in the `Result`:

```swift
var cancellables = Set<AnyCancellable>()

depot.published(valueFor: themeKey)
    .receive(on: DispatchQueue.main)
    .compactMap { try? $0.get() }
    .sink { theme in
        applyTheme(theme)
    }
    .store(in: &cancellables)
```

### Error-Handling Publisher

The error-handling variant unwraps the `Result` for you. An `ErrorHandlingDecision` closure decides how to handle each error. Its second parameter is `true` when the error belongs to the first element delivered to the subscriber, which already reflects changes made before it was delivered, and always `false` with `initialValue: false`:

```swift
depot.published(
    valueFor: themeKey,
    errorHandler: { error, isInitial in
        if isInitial {
            return .replaceWith("light")   // default theme on first read
        }
        return .skip                       // ignore later errors
    }
)
.receive(on: DispatchQueue.main)
.sink(
    receiveCompletion: { completion in
        // Only reached after a `.complete(_:)` decision.
    },
    receiveValue: { theme in
        applyTheme(theme)
    }
)
.store(in: &cancellables)
```

Because a `.complete(_:)` decision can end the stream with an error, the publisher's `Failure` type is `Error`; subscribe with `sink(receiveCompletion:receiveValue:)`.

The three decisions are:
- `.skip` — swallow the error, emit nothing
- `.replaceWith(_:)` — emit a fallback value
- `.complete(_:)` — terminate the publisher

### Multi-Value Publisher

Observe all values matching a pattern:

```swift
depot.published(valuesFor: forecastsKey)
    .receive(on: DispatchQueue.main)
    .sink { result in
        switch result {
        case .success(let forecasts):
            refresh(with: forecasts)
        case .failure(let error):
            print("Observation error: \(error)")
        }
    }
    .store(in: &cancellables)
```

### Feeding @Published Properties

```swift
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var theme: String?

    init(depot: Depot, themeKey: TypedDistinctKey<String>) {
        depot.published(valueFor: themeKey)
            .receive(on: DispatchQueue.main)
            .map { result in try? result.get() }   // nil when missing or unreadable
            .assign(to: &$theme)
    }
}
```

`assign(to:)` requires a publisher that never fails, so the example maps the `Result` instead of using the error-handling variant.

> Important: Depot publishers may emit on **any thread**. When driving UI or calling main-actor code, put `.receive(on: DispatchQueue.main)` **directly after** the depot publisher. In main-actor-isolated code — SwiftUI views, `@MainActor` types, or modules that default to main-actor isolation — Swift treats the closures you pass to Combine operators as main-actor isolated and checks this at run time, so a `map` or `compactMap` placed before `receive(on:)` would run off the main thread and trap.

### Demand and Back-Pressure

Depot publishers honor subscriber demand and never emit more values than requested. Observation of the depot starts with the first positive demand. Because every emission describes the *current state* of a key or pattern, changes that occur while the outstanding demand is zero are **conflated**: only the newest value is kept, replacing any older pending one, and it is delivered as soon as the subscriber requests more. Intermediate states are dropped rather than buffered.

Completions (from a `.complete(_:)` decision, or because the depot was deallocated) do not need demand. A pending value is delivered before the completion if demand allows; otherwise it is discarded.

Subscribers that request `.unlimited` demand — such as `sink` and `assign` — receive every emission.

## SwiftUI (DepotKitObservation)

The `DepotKitObservation` module provides two property wrappers that bridge depot observation directly into SwiftUI's view update cycle. Pass the depot into the view and create the wrappers in the initializer.

### @DepotValue — Single Value

`@DepotValue` observes a single distinct key and triggers view updates when the value changes:

```swift
import DepotKit
import DepotKitObservation
import SwiftUI

struct UnitsLabel: View {
    @DepotValue var units: UnitPreferences?

    init(depot: Depot, unitsKey: TypedDistinctKey<UnitPreferences>) {
        _units = DepotValue(key: unitsKey, depot: depot)
    }

    var body: some View {
        Text(units?.temperature.rawValue ?? "—")
    }
}
```

The `$` projected value is a `Binding<Value?>`, suitable for two-way bindings:

```swift
struct NotificationsToggle: View {
    @DepotValue var enabled: Bool?

    init(depot: Depot, notificationsKey: TypedDistinctKey<Bool>) {
        _enabled = DepotValue(key: notificationsKey, depot: depot)
    }

    var body: some View {
        Toggle("Notifications", isOn: Binding(
            get: { enabled ?? false },
            set: { $enabled.wrappedValue = $0 }
        ))
    }
}
```

Writing through the binding starts an asynchronous write and returns immediately. The wrapped value changes when the depot delivers the written value back to the observer, not at the moment you set it. If the write fails, the stored value — and therefore the displayed value — stays unchanged and the error is available on the `error` property.

You can also initialize the wrapper from a ``KeyDefinition``, which registers the key for you:

```swift
struct UnitsSummary: View {
    @DepotValue var units: UnitPreferences?

    init(depot: Depot) {
        _units = DepotValue(definition: WeatherKeys.units, depot: depot)
    }

    var body: some View {
        Text(units?.temperature.rawValue ?? "—")
    }
}
```

The `definition:` initializers register the definition right before the wrapper starts observing, not when the wrapper is created (see "Wrapper Lifecycle" below). Registering a path again replaces its registration, so keep one definition per path.

### @DepotValues — Multiple Values

`@DepotValues` observes a pattern key and delivers all matching values as an array, in unspecified order — sort them for display:

```swift
struct ForecastList: View {
    @DepotValues var forecasts: [Forecast]

    init(depot: Depot, forecastsKey: TypedKey<Forecast>) {
        _forecasts = DepotValues(key: forecastsKey, depot: depot)
    }

    var body: some View {
        List(forecasts.sorted { $0.city < $1.city }, id: \.city) { forecast in
            Text(forecast.city)
        }
    }
}
```

Like `@DepotValue`, it supports initialization from a ``PatternKeyDefinition``:

```swift
_forecasts = DepotValues(definition: WeatherKeys.forecasts, depot: depot)
```

### Wrapper Lifecycle

SwiftUI creates a new view value — and with it new wrappers — every time a parent view re-evaluates its `body`, and keeps the state of the view that is already on screen. Creating a wrapper is therefore cheap and free of side effects: it only stores the depot, the key or definition, and the initial-delivery flag. It does not read from the depot, start an observation, or register anything.

The work starts when SwiftUI installs the view and updates it before evaluating its `body` for the first time: a `definition:` wrapper registers its definition, then the wrapper starts observing the key, and the current value (or values) arrives asynchronously unless you pass `initialValue: false` (`initialValues: false`). Re-creating the view with the same key and depot neither registers again nor starts another observation.

If the parent later passes a key with a different path or a different depot, the wrapper cancels its observation and starts a new one for the new configuration before the next `body` evaluation, registering the new definition first if it was created from one. The wrapped value is reset — to `nil` for `@DepotValue`, to an empty array for `@DepotValues` — and `error` to `nil`, and the new key's value arrives asynchronously like the initial value. Writes already made through the binding still complete for the key they were made for.

### Error Handling in SwiftUI

Both wrappers expose an `error` property. Access it through the underscore-prefixed storage:

```swift
var body: some View {
    if let error = _units.error {
        Text("Error: \(error.localizedDescription)")
    } else {
        Text(units?.temperature.rawValue ?? "Loading…")
    }
}
```

> Important: With the `key:` initializers, the key — or a pattern that covers it — must be registered with the depot **before** the view is displayed. The `definition:` initializers register it for you when the view is first displayed.
