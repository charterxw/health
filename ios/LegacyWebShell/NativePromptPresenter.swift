import UIKit

@MainActor
final class NativePromptPresenter {
    weak var host: UIViewController?
    private weak var alert: UIAlertController?
    private var completion: (([String: Any]) -> Void)?
    private var cancelled: [String: Any] = [:]

    private func present(_ controller: UIAlertController, cancel: [String: Any], completion: @escaping ([String: Any]) -> Void) throws {
        guard self.completion == nil, UIApplication.shared.applicationState == .active,
              let root = host?.view.window?.rootViewController else { throw BridgeFailure.busy }
        var parent = root
        while let presented = parent.presentedViewController { parent = presented }
        guard !(parent is UIAlertController), !parent.isBeingDismissed else { throw BridgeFailure.busy }
        self.completion = completion; cancelled = cancel; alert = controller
        if let popover = controller.popoverPresentationController {
            popover.sourceView = parent.view
            popover.sourceRect = CGRect(x: parent.view.bounds.midX, y: parent.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        // UIAlertController owns its presentation delegate. Its cancel action also handles taps outside a popover.
        parent.present(controller, animated: true)
    }
    private func finish(_ result: [String: Any]) {
        let reply = completion
        completion = nil; alert = nil
        reply?(result)
    }
    func cancel() {
        let current = alert
        finish(cancelled)
        current?.dismiss(animated: false)
    }
    func menu(_ request: NativeMenuRequest, completion: @escaping ([String: Any]) -> Void) throws {
        let menu = try request.validated()
        let controller = UIAlertController(title: menu.title, message: nil, preferredStyle: .actionSheet)
        for item in menu.actions {
            controller.addAction(UIAlertAction(title: item.title, style: .default) { [weak self] _ in self?.finish(["selected": item.id]) })
        }
        controller.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.finish(["selected": NSNull()]) })
        try present(controller, cancel: ["selected": NSNull()], completion: completion)
    }
    func confirmation(_ request: NativeConfirmationRequest, completion: @escaping ([String: Any]) -> Void) throws {
        let value = try request.validated()
        let controller = UIAlertController(title: value.title, message: value.message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "继续记录", style: .cancel) { [weak self] _ in self?.finish(["confirmed": false]) })
        controller.addAction(UIAlertAction(title: value.confirmLabel, style: value.destructive ? .destructive : .default) { [weak self] _ in self?.finish(["confirmed": true]) })
        try present(controller, cancel: ["confirmed": false], completion: completion)
    }
    func rename(title: String, completion: @escaping (String) -> Void) throws {
        let controller = UIAlertController(title: "训练名称", message: nil, preferredStyle: .alert)
        controller.addTextField { field in field.text = title; field.clearButtonMode = .whileEditing; field.returnKeyType = .done }
        controller.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.finish([:]) })
        controller.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak controller] _ in
            let title = controller?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.finish(title.isEmpty ? [:] : ["title": String(title.prefix(100))])
        })
        try present(controller, cancel: [:]) { value in if let title = value["title"] as? String { completion(title) } }
    }
}
