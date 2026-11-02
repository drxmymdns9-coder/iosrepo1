#if canImport(UIKit)
import AVFoundation
import AVKit
import AnililiCore
import SwiftUI
import UIKit

/// How the picture fills the player (Android's "Screen size").
enum ScreenSize: String, CaseIterable, Identifiable {
    /// Android's `PlayerContentScale` values: Crop fills the screen without stretching, Fill
    /// stretches the picture to its edges.
    case fit, crop, fill
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "Fit"
        case .crop: return "Crop"
        case .fill: return "Fill"
        }
    }
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .crop: return .resizeAspectFill
        case .fill: return .resize
        }
    }

    /// The stored choice; "zoom" is what earlier iOS builds called Crop.
    static func stored(_ value: String) -> ScreenSize {
        value == "zoom" ? .crop : ScreenSize(rawValue: value) ?? .fit
    }
}

/// A view whose layer is the player's `AVPlayerLayer`, so the app draws its own controls over the
/// picture. It also owns Picture in Picture, which needs that layer.
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private(set) var pictureInPicture: AVPictureInPictureController?

    func attach(_ player: AVPlayer) {
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
        backgroundColor = .black
        if AVPictureInPictureController.isPictureInPictureSupported(), pictureInPicture == nil {
            pictureInPicture = AVPictureInPictureController(playerLayer: playerLayer)
            pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline =
                UserDefaults.standard.object(forKey: Setting.pictureInPicture) as? Bool ?? true
        }
    }
}

/// The handle the controls use to start Picture in Picture on the surface they sit over.
@MainActor
final class PictureInPictureHandle {
    weak var view: PlayerLayerView?

    var isPossible: Bool { view?.pictureInPicture?.isPictureInPicturePossible == true }

    func toggle() {
        guard let controller = view?.pictureInPicture else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let pictureInPicture: PictureInPictureHandle

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.attach(player)
        view.playerLayer.videoGravity = gravity
        pictureInPicture.view = view
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.attach(player)
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
        pictureInPicture.view = view
    }
}

/// The system AirPlay button, tinted to sit in the player's control row.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Which way the app may turn. Portrait everywhere but the player, which may go landscape and does
/// for fullscreen (Android's phone layout).
enum OrientationLock {
    @MainActor static var allowed: UIInterfaceOrientationMask = .portrait

    @MainActor static func allow(_ mask: UIInterfaceOrientationMask, turnTo orientation: UIInterfaceOrientationMask? = nil) {
        allowed = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if let orientation {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { error in
                Log.warning("player", "orientation change refused: \(error.localizedDescription)")
            }
        }
    }
}
#endif
