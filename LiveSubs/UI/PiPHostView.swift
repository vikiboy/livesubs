import AVFoundation
import ReplayKit
import SwiftUI

/// Hosts the subtitle AVSampleBufferDisplayLayer in-app. This is both the live
/// preview and the PiP source — PiP requires the layer to be in a visible view.
struct PiPHostView: UIViewRepresentable {
    let pip: SubtitlePiPController

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.layer.addSublayer(pip.displayLayer)
        v.onLayout = { [weak v] in
            guard let v else { return }
            pip.displayLayer.frame = v.bounds
        }
        DispatchQueue.main.async { pip.prepare() }
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}

    final class LayerView: UIView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            onLayout?()
            CATransaction.commit()
        }
    }
}

/// The system "Start Broadcast" picker, pre-targeted at our extension. Kept nearly
/// invisible; LiveSession taps its button programmatically when Start is pressed.
struct BroadcastPickerView: UIViewRepresentable {
    let session: LiveSession

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".BroadcastExtension"
        picker.showsMicrophoneButton = false
        session.broadcastPicker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        session.broadcastPicker = uiView
    }
}
