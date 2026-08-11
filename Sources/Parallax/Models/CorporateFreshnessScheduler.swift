import Foundation

@MainActor
protocol CorporateFreshnessScheduling: AnyObject {
    func schedule(_ invalidate: @escaping @MainActor () -> Void)
}

private final class CorporateFreshnessTimerToken: @unchecked Sendable {
    let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    deinit {
        timer.invalidate()
    }
}

@MainActor
final class CorporateTimerFreshnessScheduler: CorporateFreshnessScheduling {
    private var token: CorporateFreshnessTimerToken?

    func schedule(_ invalidate: @escaping @MainActor () -> Void) {
        token = nil
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        token = CorporateFreshnessTimerToken(timer: timer)
    }
}
