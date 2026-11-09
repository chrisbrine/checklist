import Foundation
@testable import ChecklistCore

/// Shares only immutable worker validation schemas from the loaded test image.
/// Every request still runs the production field/type/role validation and all
/// current store, session, scope and grant checks. Advertised catalogs stay real.
public enum ValidationCatalogFixture {
    private static let workerCatalogs = WorkerCatalogs()

    public static func configure(_ router: CommandRouter) {
        router.fixtureValidationCatalog = { [weak router] caller, includingHookOnly in
            guard let router else { return [] }
            guard caller.role == "worker" else {
                return router.toolCatalog(caller,includingHookOnly:includingHookOnly)
            }
            return workerCatalogs.catalog(router:router,caller:caller,includingHookOnly:includingHookOnly)
        }
    }

    // Worker toolCatalog depends only on its role and hook visibility, never
    // installation/session/workspace/project identity. Assistants are excluded:
    // their readable projects and per-project grants change catalog membership.
    private final class WorkerCatalogs: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool: [[String: Any]]] = [:]

        func catalog(router: CommandRouter, caller: Caller, includingHookOnly: Bool) -> [[String: Any]] {
            lock.withLock {
                if let value = values[includingHookOnly] { return value }
                let value = router.toolCatalog(caller,includingHookOnly:includingHookOnly)
                values[includingHookOnly] = value
                return value
            }
        }
    }
}
