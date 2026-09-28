import Foundation
import Observation

@Observable
@MainActor
final class LaunchIsolationVerification {
    private(set) var notices: Set<UUID> = []
    @ObservationIgnored private var requests: [UUID: Request] = [:]
    @ObservationIgnored private let verifier: IsolationActivityVerifier

    private struct Request {
        let token = UUID()
        let paths: [LaunchIsolationPath]
        let began: Date
        var started = false
        var task: Task<Void, Never>?
    }

    init(verifier: IsolationActivityVerifier = IsolationActivityVerifier()) {
        self.verifier = verifier
    }

    func register(requestID: UUID, paths: [LaunchIsolationPath], began: Date = Date()) {
        remove(requestID: requestID)
        let managed = paths.filter(\.isManaged)
        guard !managed.isEmpty else { return }
        requests[requestID] = Request(paths: managed, began: began)
    }

    @discardableResult
    func running(requestID: UUID) -> Task<Void, Never>? {
        guard var request = requests[requestID] else { return nil }
        guard !request.started else { return request.task }
        request.started = true
        let verifier = verifier
        let paths = request.paths
        let began = request.began
        let token = request.token
        request.task = Task { [weak self] in
            await verifier.verify(paths: paths, since: began) { [weak self] activity in
                await self?.record(activity, requestID: requestID, token: token)
            }
            if self?.requests[requestID]?.token == token {
                self?.requests[requestID] = nil
                self?.notices.remove(requestID)
            }
        }
        requests[requestID] = request
        return request.task
    }

    func remove(requestID: UUID) {
        requests.removeValue(forKey: requestID)?.task?.cancel()
        notices.remove(requestID)
    }

    private func record(_ activity: IsolationFolderActivity, requestID: UUID, token: UUID) {
        guard requests[requestID]?.token == token else { return }
        if activity == .inactive {
            notices.insert(requestID)
        } else {
            notices.remove(requestID)
        }
    }
}
