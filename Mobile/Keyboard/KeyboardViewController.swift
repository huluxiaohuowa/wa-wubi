import SwiftUI
import UIKit

@MainActor final class KeyboardViewController: UIInputViewController {
    private let store = MobileStore()
    private lazy var session = KeyboardSession(store: store)
    private var host: UIHostingController<KeyboardSurface<InputModeButton>>?

    override func viewDidLoad() {
        super.viewDidLoad()
        session.insert = { [weak self] in self?.textDocumentProxy.insertText($0) }
        session.deleteBackward = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        session.adjustCursor = { [weak self] in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: $0) }
        session.playClick = { [weak self] in
            guard self?.store.keySound == true else { return }
            UIDevice.current.playInputClick()
        }

        let content = KeyboardSurface(session: session, store: store,
                                      globe: { [weak self] in InputModeButton(controller: self) },
                                      showGlobe: needsInputModeSwitchKey)
        let host = UIHostingController(rootView: content)
        self.host = host
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 278)
        height.priority = .init(900)
        height.isActive = true
        host.didMove(toParent: self)
        Task { await store.prepare() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.reload()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if let host, host.rootView.showGlobe != needsInputModeSwitchKey {
            host.rootView.showGlobe = needsInputModeSwitchKey
        }
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {
        super.textWillChange(textInput)
        session.reset()
        store.reload()
    }
}

private struct InputModeButton: UIViewRepresentable {
    weak var controller: KeyboardViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.accessibilityLabel = "切换输入法"
        button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
