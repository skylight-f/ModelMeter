import Foundation

enum TaskRuntimeSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let now = Date()
        var reducer = TaskRuntimeReducer()
        reducer.replaceThreads([
            [
                "id": "approval-thread",
                "name": "Approval task",
                "updatedAt": Int(now.timeIntervalSince1970),
                "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]
            ],
            [
                "id": "input-thread",
                "updatedAt": Int(now.timeIntervalSince1970),
                "status": ["type": "active", "activeFlags": ["waitingOnUserInput"]]
            ],
            [
                "id": "running-thread",
                "updatedAt": Int(now.timeIntervalSince1970),
                "status": ["type": "active", "activeFlags": []]
            ],
            [
                "id": "record-thread",
                "updatedAt": Int(now.timeIntervalSince1970),
                "status": ["type": "notLoaded"]
            ]
        ], connectionMode: .isolated)

        var snapshot = reducer.snapshot(at: now)
        expect(snapshot.records["approval-thread"]?.state == .waitingApproval, "approval flag should map to waitingApproval")
        expect(snapshot.records["input-thread"]?.state == .waitingInput, "input flag should map to waitingInput")
        expect(snapshot.records["running-thread"]?.state == .running, "active without flags should map to running")
        expect(snapshot.records["record-thread"]?.state == .recorded, "notLoaded should remain recorded")
        expect(snapshot.records["record-thread"]?.isRealtime == false, "notLoaded should not be presented as realtime")

        _ = reducer.applyNotification(method: "item/started", params: [
            "threadId": "approval-thread",
            "turnId": "turn-1",
            "item": [
                "id": "item-1",
                "type": "commandExecution",
                "command": "/usr/bin/git status",
                "commandActions": [["type": "listFiles", "command": "git status"]]
            ]
        ])

        let requestID = CodexRequestID.string("request-1")
        let added = reducer.applyServerRequest(
            requestID: requestID,
            method: "item/commandExecution/requestApproval",
            params: [
                "threadId": "approval-thread",
                "turnId": "turn-1",
                "itemId": "item-1",
                "startedAtMs": Int64(now.timeIntervalSince1970 * 1_000),
                "reason": "Needs access",
                "command": "/usr/bin/git status",
                "availableDecisions": ["accept", "acceptForSession", "decline", "cancel"]
            ]
        )
        expect(added, "owned approval request should be accepted by reducer")
        snapshot = reducer.snapshot(at: now)
        let approval = snapshot.records["approval-thread"]?.approval
        expect(approval?.requestID == requestID, "approval should retain original request id")
        expect(approval?.availableDecisions.contains(.acceptForSession) == true, "server-provided session decision should remain available")
        expect(approval?.summary == "List files", "friendly command action should be preferred")

        expect(reducer.markSubmitting(requestID: requestID, decision: .decline), "valid decision should enter submitting state")
        snapshot = reducer.snapshot(at: now)
        expect(snapshot.records["approval-thread"]?.approval?.submissionState == .submitting, "approval should be submitting")
        expect(!reducer.markSubmitting(requestID: requestID, decision: .accept), "duplicate submission should be rejected")

        expect(reducer.resolve(requestID: requestID), "resolved request should be removed")
        snapshot = reducer.snapshot(at: now)
        expect(snapshot.records["approval-thread"]?.approval == nil, "resolved approval must be cleared")
        expect(snapshot.records["approval-thread"]?.state == .running, "resolved approval should wait in running state for final event")
        expect(!reducer.resolve(requestID: requestID), "duplicate resolved notification should be idempotent")

        let integerRequestID = CodexRequestID.integer(42)
        _ = reducer.applyServerRequest(
            requestID: integerRequestID,
            method: "item/fileChange/requestApproval",
            params: [
                "threadId": "running-thread",
                "turnId": "turn-2",
                "itemId": "item-2",
                "startedAtMs": Int64(now.timeIntervalSince1970 * 1_000)
            ]
        )
        expect(reducer.snapshot().records["running-thread"]?.approval?.requestID == integerRequestID, "integer request id should be preserved")

        reducer.disconnect()
        snapshot = reducer.snapshot(at: now)
        expect(snapshot.connectionMode == .disconnected, "disconnect should publish disconnected mode")
        expect(snapshot.records["running-thread"]?.approval == nil, "disconnect should drop operation ownership")
        expect(snapshot.records["running-thread"]?.state == .disconnected, "active task should become disconnected")

        let attention = TaskAttentionSelector.highestPriority([
            TaskAttentionItem(id: "update", kind: .update, runtimeScope: nil, threadID: nil, title: "Update", since: nil),
            TaskAttentionItem(id: "failure", kind: .failure, runtimeScope: .codex, threadID: "a", title: "Failure", since: now),
            TaskAttentionItem(id: "approval", kind: .approval, runtimeScope: .codex, threadID: "b", title: "Approval", since: now.addingTimeInterval(-10))
        ])
        expect(attention?.id == "approval", "approval must outrank failure and update")

        if failures.isEmpty {
            print("task runtime self-test passed")
            return true
        }
        for failure in failures {
            print("task runtime self-test failed: \(failure)")
        }
        return false
    }
}
