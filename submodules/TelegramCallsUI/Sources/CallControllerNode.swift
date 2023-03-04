import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import TelegramAudio
import AccountContext
import LocalizedPeerData
import PhotoResources
import CallsEmoji
import TooltipUI
import AlertUI
import PresentationDataUtils
import DeviceAccess
import ContextUI
import AudioBlob
import GradientBackground
import TelegramAnimatedStickerNode
import AnimatedStickerNode
import AppBundle

private func interpolateFrame(from fromValue: CGRect, to toValue: CGRect, t: CGFloat) -> CGRect {
    return CGRect(x: floorToScreenPixels(toValue.origin.x * t + fromValue.origin.x * (1.0 - t)), y: floorToScreenPixels(toValue.origin.y * t + fromValue.origin.y * (1.0 - t)), width: floorToScreenPixels(toValue.size.width * t + fromValue.size.width * (1.0 - t)), height: floorToScreenPixels(toValue.size.height * t + fromValue.size.height * (1.0 - t)))
}

private func interpolate(from: CGFloat, to: CGFloat, value: CGFloat) -> CGFloat {
    return (1.0 - value) * from + value * to
}

private final class CallVideoNode: ASDisplayNode, PreviewVideoNode {
    private let videoTransformContainer: ASDisplayNode
    private let videoView: PresentationCallVideoView
    
    private var effectView: UIVisualEffectView?
    private let videoPausedNode: ImmediateTextNode
    
    private var isBlurred: Bool = false
    private var currentCornerRadius: CGFloat = 0.0
    
    private let isReadyUpdated: () -> Void
    private(set) var isReady: Bool = false
    private var isReadyTimer: SwiftSignalKit.Timer?
    
    private let readyPromise = ValuePromise(false)
    var ready: Signal<Bool, NoError> {
        return self.readyPromise.get()
    }
    
    private let isFlippedUpdated: (CallVideoNode) -> Void
    
    private(set) var currentOrientation: PresentationCallVideoView.Orientation
    private(set) var currentAspect: CGFloat = 0.0
    
    private var previousVideoHeight: CGFloat?
    
    init(videoView: PresentationCallVideoView, disabledText: String?, assumeReadyAfterTimeout: Bool, isReadyUpdated: @escaping () -> Void, orientationUpdated: @escaping () -> Void, isFlippedUpdated: @escaping (CallVideoNode) -> Void) {
        self.isReadyUpdated = isReadyUpdated
        self.isFlippedUpdated = isFlippedUpdated
        
        self.videoTransformContainer = ASDisplayNode()
        self.videoView = videoView
        videoView.view.clipsToBounds = true
        videoView.view.backgroundColor = .black
        
        self.currentOrientation = videoView.getOrientation()
        self.currentAspect = videoView.getAspect()
        
        self.videoPausedNode = ImmediateTextNode()
        self.videoPausedNode.alpha = 0.0
        self.videoPausedNode.maximumNumberOfLines = 3
        
        super.init()
        
        self.backgroundColor = .black
        self.clipsToBounds = true
        
        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
        }
        
        self.videoTransformContainer.view.addSubview(self.videoView.view)
        self.addSubnode(self.videoTransformContainer)
        
        if let disabledText = disabledText {
            self.videoPausedNode.attributedText = NSAttributedString(string: disabledText, font: Font.regular(17.0), textColor: .white)
            self.addSubnode(self.videoPausedNode)
        }
        
        self.videoView.setOnFirstFrameReceived { [weak self] aspectRatio in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                if !strongSelf.isReady {
                    strongSelf.isReady = true
                    strongSelf.readyPromise.set(true)
                    strongSelf.isReadyTimer?.invalidate()
                    strongSelf.isReadyUpdated()
                }
            }
        }
        
        self.videoView.setOnOrientationUpdated { [weak self] orientation, aspect in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                if strongSelf.currentOrientation != orientation || strongSelf.currentAspect != aspect {
                    strongSelf.currentOrientation = orientation
                    strongSelf.currentAspect = aspect
                    orientationUpdated()
                }
            }
        }
        
        self.videoView.setOnIsMirroredUpdated { [weak self] _ in
            Queue.mainQueue().async {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.isFlippedUpdated(strongSelf)
            }
        }
        
        if assumeReadyAfterTimeout {
            self.isReadyTimer = SwiftSignalKit.Timer(timeout: 3.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                if !strongSelf.isReady {
                    strongSelf.isReady = true
                    strongSelf.readyPromise.set(true)
                    strongSelf.isReadyUpdated()
                }
            }, queue: .mainQueue())
        }
        self.isReadyTimer?.start()
    }
    
    deinit {
        self.isReadyTimer?.invalidate()
    }
    
    override func didLoad() {
        super.didLoad()
        
        if #available(iOS 13.0, *) {
            self.layer.cornerCurve = .continuous
        }
    }
    
    func animateRadialMask(from fromRect: CGRect, to toRect: CGRect) {
        let maskLayer = CAShapeLayer()
        maskLayer.frame = fromRect
        
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(origin: CGPoint(), size: fromRect.size))
        maskLayer.path = path
        
        self.layer.mask = maskLayer
        
        let topLeft = CGPoint(x: 0.0, y: 0.0)
        let topRight = CGPoint(x: self.bounds.width, y: 0.0)
        let bottomLeft = CGPoint(x: 0.0, y: self.bounds.height)
        let bottomRight = CGPoint(x: self.bounds.width, y: self.bounds.height)
        
        func distance(_ v1: CGPoint, _ v2: CGPoint) -> CGFloat {
            let dx = v1.x - v2.x
            let dy = v1.y - v2.y
            return sqrt(dx * dx + dy * dy)
        }
        
        var maxRadius = distance(toRect.center, topLeft)
        maxRadius = max(maxRadius, distance(toRect.center, topRight))
        maxRadius = max(maxRadius, distance(toRect.center, bottomLeft))
        maxRadius = max(maxRadius, distance(toRect.center, bottomRight))
        maxRadius = ceil(maxRadius)
        
        let targetFrame = CGRect(origin: CGPoint(x: toRect.center.x - maxRadius, y: toRect.center.y - maxRadius), size: CGSize(width: maxRadius * 2.0, height: maxRadius * 2.0))
        
        let transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .easeInOut)
        transition.updatePosition(layer: maskLayer, position: targetFrame.center)
        transition.updateTransformScale(layer: maskLayer, scale: maxRadius * 2.0 / fromRect.width, completion: { [weak self] _ in
            self?.layer.mask = nil
        })
    }
    
    func updateLayout(size: CGSize, layoutMode: VideoNodeLayoutMode, transition: ContainedViewLayoutTransition) {
        self.updateLayout(size: size, cornerRadius: self.currentCornerRadius, isOutgoing: true, deviceOrientation: .portrait, isCompactLayout: false, transition: transition)
    }
    
    func updateLayout(size: CGSize, cornerRadius: CGFloat, isOutgoing: Bool, deviceOrientation: UIDeviceOrientation, isCompactLayout: Bool, transition: ContainedViewLayoutTransition) {
        self.currentCornerRadius = cornerRadius
        
        var rotationAngle: CGFloat
        if false && isOutgoing && isCompactLayout {
            rotationAngle = CGFloat.pi / 2.0
        } else {
            switch self.currentOrientation {
            case .rotation0:
                rotationAngle = 0.0
            case .rotation90:
                rotationAngle = CGFloat.pi / 2.0
            case .rotation180:
                rotationAngle = CGFloat.pi
            case .rotation270:
                rotationAngle = -CGFloat.pi / 2.0
            }
            
            var additionalAngle: CGFloat = 0.0
            switch deviceOrientation {
            case .portrait:
                additionalAngle = 0.0
            case .landscapeLeft:
                additionalAngle = CGFloat.pi / 2.0
            case .landscapeRight:
                additionalAngle = -CGFloat.pi / 2.0
            case .portraitUpsideDown:
                rotationAngle = CGFloat.pi
            default:
                additionalAngle = 0.0
            }
            rotationAngle += additionalAngle
            if abs(rotationAngle - CGFloat.pi * 3.0 / 2.0) < 0.01 {
                rotationAngle = -CGFloat.pi / 2.0
            }
            if abs(rotationAngle - (-CGFloat.pi)) < 0.01 {
                rotationAngle = -CGFloat.pi + 0.001
            }
        }
        
        let rotateFrame = abs(rotationAngle.remainder(dividingBy: CGFloat.pi)) > 1.0
        let fittingSize: CGSize
        if rotateFrame {
            fittingSize = CGSize(width: size.height, height: size.width)
        } else {
            fittingSize = size
        }
        
        let unboundVideoSize = CGSize(width: self.currentAspect * 10000.0, height: 10000.0)
        
        var fittedVideoSize = unboundVideoSize.fitted(fittingSize)
        if fittedVideoSize.width < fittingSize.width || fittedVideoSize.height < fittingSize.height {
            let isVideoPortrait = unboundVideoSize.width < unboundVideoSize.height
            let isFittingSizePortrait = fittingSize.width < fittingSize.height
            
            if isCompactLayout && isVideoPortrait == isFittingSizePortrait {
                fittedVideoSize = unboundVideoSize.aspectFilled(fittingSize)
            } else {
                let maxFittingEdgeDistance: CGFloat
                if isCompactLayout {
                    maxFittingEdgeDistance = 200.0
                } else {
                    maxFittingEdgeDistance = 400.0
                }
                if fittedVideoSize.width > fittingSize.width - maxFittingEdgeDistance && fittedVideoSize.height > fittingSize.height - maxFittingEdgeDistance {
                    fittedVideoSize = unboundVideoSize.aspectFilled(fittingSize)
                }
            }
        }
        
        let rotatedVideoHeight: CGFloat = max(fittedVideoSize.height, fittedVideoSize.width)
        
        let videoFrame: CGRect = CGRect(origin: CGPoint(), size: fittedVideoSize)
        
        let videoPausedSize = self.videoPausedNode.updateLayout(CGSize(width: size.width - 16.0, height: 100.0))
        transition.updateFrame(node: self.videoPausedNode, frame: CGRect(origin: CGPoint(x: floor((size.width - videoPausedSize.width) / 2.0), y: floor((size.height - videoPausedSize.height) / 2.0)), size: videoPausedSize))
        
        self.videoTransformContainer.bounds = CGRect(origin: CGPoint(), size: videoFrame.size)
        if transition.isAnimated && !videoFrame.height.isZero, let previousVideoHeight = self.previousVideoHeight, !previousVideoHeight.isZero {
            let scaleDifference = previousVideoHeight / rotatedVideoHeight
            if abs(scaleDifference - 1.0) > 0.001 {
                transition.animateTransformScale(node: self.videoTransformContainer, from: scaleDifference, additive: true)
            }
        }
        self.previousVideoHeight = rotatedVideoHeight
        transition.updatePosition(node: self.videoTransformContainer, position: CGPoint(x: size.width / 2.0, y: size.height / 2.0))
        transition.updateTransformRotation(view: self.videoTransformContainer.view, angle: rotationAngle)
        
        let localVideoFrame = CGRect(origin: CGPoint(), size: videoFrame.size)
        self.videoView.view.bounds = localVideoFrame
        self.videoView.view.center = localVideoFrame.center
        // TODO: properly fix the issue
        // On iOS 13 and later metal layer transformation is broken if the layer does not require compositing
        self.videoView.view.alpha = 0.995
        
        if let effectView = self.effectView {
            transition.updateFrame(view: effectView, frame: localVideoFrame)
        }
        
        transition.updateCornerRadius(layer: self.layer, cornerRadius: self.currentCornerRadius)
    }
    
    func updateIsBlurred(isBlurred: Bool, light: Bool = false, animated: Bool = true) {
        if self.hasScheduledUnblur {
            self.hasScheduledUnblur = false
        }
        if self.isBlurred == isBlurred {
            return
        }
        self.isBlurred = isBlurred
        
        if isBlurred {
            if self.effectView == nil {
                let effectView = UIVisualEffectView()
                self.effectView = effectView
                effectView.frame = self.videoTransformContainer.bounds
                self.videoTransformContainer.view.addSubview(effectView)
            }
            if animated {
                UIView.animate(withDuration: 0.3, animations: {
                    self.videoPausedNode.alpha = 1.0
                    self.effectView?.effect = UIBlurEffect(style: light ? .light : .dark)
                })
            } else {
                self.effectView?.effect = UIBlurEffect(style: light ? .light : .dark)
            }
        } else if let effectView = self.effectView {
            self.effectView = nil
            UIView.animate(withDuration: 0.3, animations: {
                self.videoPausedNode.alpha = 0.0
                effectView.effect = nil
            }, completion: { [weak effectView] _ in
                effectView?.removeFromSuperview()
            })
        }
    }
    
    private var hasScheduledUnblur = false
    func flip(withBackground: Bool) {
        if withBackground {
            self.backgroundColor = .black
        }
        UIView.transition(with: withBackground ? self.videoTransformContainer.view : self.view, duration: 0.4, options: [.transitionFlipFromLeft, .curveEaseOut], animations: {
            UIView.performWithoutAnimation {
                self.updateIsBlurred(isBlurred: true, light: false, animated: false)
            }
        }) { finished in
            self.backgroundColor = nil
            self.hasScheduledUnblur = true
            Queue.mainQueue().after(0.5) {
                if self.hasScheduledUnblur {
                    self.updateIsBlurred(isBlurred: false)
                }
            }
        }
    }
}

private let blueVioletGradientColors: [UIColor] = [.init(hexString: "#5295D6"), .init(hexString: "#616AD5"), .init(hexString: "#AC65D4"), .init(hexString: "#7261DA")].compactMap({ $0 })
private let blueGreenGradientColors: [UIColor] = [.init(hexString: "#53A6DE"), .init(hexString: "#398D6F"), .init(hexString: "#BAC05D"), .init(hexString: "#3C9C8F")].compactMap({ $0 })
private let orangeRedGradientColors: [UIColor] = [.init(hexString: "#B84498"), .init(hexString: "#F4992E"), .init(hexString: "#C94986"), .init(hexString: "#FF7E46")].compactMap({ $0 })
var latestHasVideoState = false

final class CallControllerNode: ViewControllerTracingNode, CallControllerNodeProtocol {
    private enum VideoNodeCorner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }
    
    private let sharedContext: SharedAccountContext
    private let account: Account
    
    private let statusBar: StatusBar
    
    private var presentationData: PresentationData
    private var peer: Peer?
    private let debugInfo: Signal<(String, String), NoError>
    private var forceReportRating = false
    private let easyDebugAccess: Bool
    private let call: PresentationCall
    
    private let containerTransformationNode: ASDisplayNode
    let containerNode: ASDisplayNode
    private let videoContainerNode: PinchSourceContainerNode
    
    private let gradientBackgroundNode: GradientBackgroundNode
    private var shouldActivateGradientBackroundNodeAnimationLoop: Bool = true
    
    private let voiceBlobNode: VoiceBlobNode
    private let imageNode: TransformImageNode
    private let dimNode: ASImageNode
    
    private var candidateIncomingVideoNodeValue: CallVideoNode?
    private var incomingVideoNodeValue: CallVideoNode?
    private var incomingVideoViewRequested: Bool = false
    private var candidateOutgoingVideoNodeValue: CallVideoNode?
    private var outgoingVideoNodeValue: CallVideoNode?
    private var outgoingVideoViewRequested: Bool = false
    
    private var removedMinimizedVideoNodeValue: CallVideoNode?
    private var removedExpandedVideoNodeValue: CallVideoNode?
    
    private var isRequestingVideo: Bool = false
    private var animateRequestedVideoOnce: Bool = false
    
    private var hiddenUIForActiveVideoCallOnce: Bool = false
    private var hideUIForActiveVideoCallTimer: SwiftSignalKit.Timer?
    
    private var displayedCameraConfirmation: Bool = false
    private var displayedCameraTooltip: Bool = false
        
    private var expandedVideoNode: CallVideoNode? {
        didSet {
            self.dismissKeyTooltipNode()
        }
    }
    
    private var minimizedVideoNode: CallVideoNode? {
        didSet {
            print(minimizedVideoNode as Any)
        }
    }
    
    private var disableAnimationForExpandedVideoOnce: Bool = false
    private var animationForExpandedVideoSnapshotView: UIView? = nil
    private var animationForMinimazedVideoSnapshotView: UIView? = nil
    
    private var outgoingVideoNodeCorner: VideoNodeCorner = .bottomRight
    private let backButtonArrowNode: ASImageNode
    private let backButtonNode: HighlightableButtonNode
    private let statusNode: CallControllerStatusNode
    private let toastNode: CallControllerToastContainerNode
    let buttonsNode: CallControllerButtonsNode
    private var keyPreviewNode: CallControllerKeyPreviewNode?
    
    private var debugNode: CallDebugNode?
    
    private var keyTextData: (Data, String)?
    private let keyButtonNode: CallControllerKeyButton
    
    private var validLayout: (ContainerViewLayout, CGFloat)?
    private var disableActionsUntilTimestamp: Double = 0.0
    
    private var displayedVersionOutdatedAlert: Bool = false
    
    var isMuted: Bool = false {
        didSet {
            self.buttonsNode.isMuted = self.isMuted
            self.updateToastContent()
            if let (layout, navigationBarHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
        }
    }
    
    private var shouldStayHiddenUntilConnection: Bool = false
    
    private var audioOutputState: ([AudioSessionOutput], currentOutput: AudioSessionOutput?)?
    private var callState: PresentationCallState?
    
    var toggleMute: (() -> Void)?
    var setCurrentAudioOutput: ((AudioSessionOutput) -> Void)?
    var beginAudioOuputSelection: ((Bool) -> Void)?
    var acceptCall: (() -> Void)?
    var endCall: (() -> Void)?
    var back: (() -> Void)?
    var presentCallRating: ((CallId, Bool) -> Void)?
    var callEnded: ((Bool) -> Void)?
    var dismissedInteractively: (() -> Void)?
    var present: ((ViewController) -> Void)?
    var dismissAllTooltips: (() -> Void)?
    
    private var toastContent: CallControllerToastContent?
    private var displayToastsAfterTimestamp: Double?
    
    private var buttonsMode: CallControllerButtonsMode?
    
    private var isUIHidden: Bool = false
    private var isVideoPaused: Bool = false
    private var isVideoPinched: Bool = false
    
    private enum PictureInPictureGestureState {
        case none
        case collapsing(didSelectCorner: Bool)
        case dragging(initialPosition: CGPoint, draggingPosition: CGPoint)
    }
    
    private var pictureInPictureGestureState: PictureInPictureGestureState = .none
    private var pictureInPictureCorner: VideoNodeCorner = .topRight
    private var pictureInPictureTransitionFraction: CGFloat = 0.0
    
    private var deviceOrientation: UIDeviceOrientation = .portrait
    private var orientationDidChangeObserver: NSObjectProtocol?
    
    private var currentRequestedAspect: CGFloat?
    private var audioLevelDisposable: Disposable?
    
    private var animatedEmojiStickersDisposable: Disposable?
    private var animatedEmojiStickers: [String: [StickerPackItem]] = [:]
    
    init(sharedContext: SharedAccountContext, account: Account, presentationData: PresentationData, statusBar: StatusBar, debugInfo: Signal<(String, String), NoError>, shouldStayHiddenUntilConnection: Bool = false, easyDebugAccess: Bool, call: PresentationCall) {
        latestHasVideoState = false
        self.sharedContext = sharedContext
        self.account = account
        self.presentationData = presentationData
        self.statusBar = statusBar
        self.debugInfo = debugInfo
        self.shouldStayHiddenUntilConnection = shouldStayHiddenUntilConnection
        self.easyDebugAccess = easyDebugAccess
        self.call = call
        
        self.containerTransformationNode = ASDisplayNode()
        self.containerTransformationNode.clipsToBounds = true
        
        self.containerNode = ASDisplayNode()
        
        self.videoContainerNode = PinchSourceContainerNode()
        
        self.gradientBackgroundNode = GradientBackgroundNode(colors: blueVioletGradientColors, useSharedAnimationPhase: false)
        self.voiceBlobNode = VoiceBlobNode(maxLevel: 0.3, smallBlobRange: (0, 0), mediumBlobRange: (0.7, 0.8), bigBlobRange: (0.8, 0.9))
        self.voiceBlobNode.setColor(.white)
        self.voiceBlobNode.startAnimating()
        self.imageNode = TransformImageNode()
        self.imageNode.contentAnimations = [.subsequentUpdates]
        self.dimNode = ASImageNode()
        self.dimNode.contentMode = .scaleToFill
        self.dimNode.isUserInteractionEnabled = false
        self.dimNode.backgroundColor = UIColor(white: 0.0, alpha: 0.3)
        
        self.backButtonArrowNode = ASImageNode()
        self.backButtonArrowNode.displayWithoutProcessing = true
        self.backButtonArrowNode.displaysAsynchronously = false
        self.backButtonArrowNode.image = NavigationBarTheme.generateBackArrowImage(color: .white)
        self.backButtonNode = HighlightableButtonNode()
        
        self.statusNode = CallControllerStatusNode()
        
        self.buttonsNode = CallControllerButtonsNode(strings: self.presentationData.strings)
        self.toastNode = CallControllerToastContainerNode(strings: self.presentationData.strings)
        self.keyButtonNode = CallControllerKeyButton()
        self.keyButtonNode.accessibilityElementsHidden = false
        
        super.init()
        
        self.containerNode.backgroundColor = .black
        
        self.addSubnode(self.containerTransformationNode)
        self.containerTransformationNode.addSubnode(self.containerNode)
        
        self.backButtonNode.setTitle(presentationData.strings.Common_Back, with: Font.regular(17.0), with: .white, for: [])
        self.backButtonNode.accessibilityLabel = presentationData.strings.Call_VoiceOver_Minimize
        self.backButtonNode.accessibilityTraits = [.button]
        self.backButtonNode.hitTestSlop = UIEdgeInsets(top: -8.0, left: -20.0, bottom: -8.0, right: -8.0)
        self.backButtonNode.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    strongSelf.backButtonNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.backButtonArrowNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.backButtonNode.alpha = 0.4
                    strongSelf.backButtonArrowNode.alpha = 0.4
                } else {
                    strongSelf.backButtonNode.alpha = 1.0
                    strongSelf.backButtonArrowNode.alpha = 1.0
                    strongSelf.backButtonNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                    strongSelf.backButtonArrowNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        
        self.containerNode.addSubnode(self.gradientBackgroundNode)
        self.containerNode.addSubnode(self.voiceBlobNode)
        self.containerNode.addSubnode(self.imageNode)
        self.containerNode.addSubnode(self.videoContainerNode)
//        self.containerNode.addSubnode(self.dimNode)
        self.containerNode.addSubnode(self.buttonsNode)
        self.containerNode.addSubnode(self.statusNode)
        self.containerNode.addSubnode(self.toastNode)
        self.containerNode.addSubnode(self.keyButtonNode)
        self.containerNode.addSubnode(self.backButtonArrowNode)
        self.containerNode.addSubnode(self.backButtonNode)
        
        self.audioLevelDisposable = (call.audioLevel |> deliverOnMainQueue).start(next: { [weak self] level in
            self?.voiceBlobNode.updateLevel(CGFloat(level))
        })
        
        self.buttonsNode.mute = { [weak self] in
            self?.toggleMute?()
            self?.cancelScheduledUIHiding()
        }
        
        self.buttonsNode.speaker = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.beginAudioOuputSelection?(strongSelf.hasVideoNodes)
            strongSelf.cancelScheduledUIHiding()
        }
                
        self.buttonsNode.acceptOrEnd = { [weak self] in
            guard let strongSelf = self, let callState = strongSelf.callState else {
                return
            }
            switch callState.state {
            case .active, .connecting, .reconnecting:
                strongSelf.endCall?()
                strongSelf.cancelScheduledUIHiding()
            case .requesting:
                strongSelf.endCall?()
            case .ringing:
                strongSelf.acceptCall?()
            default:
                break
            }
        }
        
        self.buttonsNode.decline = { [weak self] in
            self?.endCall?()
        }
        
        self.buttonsNode.toggleVideo = { [weak self] in
            guard let strongSelf = self, let callState = strongSelf.callState else {
                return
            }
            switch callState.state {
            case .active:
                var isScreencastActive = false
                switch callState.videoState {
                case .active(true), .paused(true):
                    isScreencastActive = true
                default:
                    break
                }

                if isScreencastActive {
                    (strongSelf.call as! PresentationCallImpl).disableScreencast()
                } else if strongSelf.outgoingVideoNodeValue == nil {
                    DeviceAccess.authorizeAccess(to: .camera(.videoCall), onlyCheck: true, presentationData: strongSelf.presentationData, present: { [weak self] c, a in
                        if let strongSelf = self {
                            strongSelf.present?(c)
                        }
                    }, openSettings: { [weak self] in
                        self?.sharedContext.applicationBindings.openSettings()
                    }, _: { [weak self] ready in
                        guard let strongSelf = self, ready else {
                            return
                        }
                        let proceed: (CallVideoNode) -> Void = { previewVideoNode in
                            strongSelf.displayedCameraConfirmation = true
                            strongSelf.candidateOutgoingVideoNodeValue = previewVideoNode
                            if strongSelf.expandedVideoNode == nil {
                                strongSelf.statusNode.layer.animateAlpha(from: 0, to: 1, duration: 0.6)
                                strongSelf.toastNode.layer.animateAlpha(from: 0, to: 1, duration: 0.6)
                                strongSelf.buttonsNode.layer.animateAlpha(from: 0, to: 1, duration: 0.6)
                                strongSelf.keyButtonNode.layer.animateAlpha(from: 0, to: 1, duration: 0.6)
                                strongSelf.backButtonNode.layer.animateAlpha(from: 0, to: 1, duration: 0.6)
                                strongSelf.backButtonArrowNode.layer.animateAlpha(from: 0, to: 1, duration: 0.6)
                            }
                            
                            switch callState.videoState {
                            case .inactive:
                                strongSelf.isRequestingVideo = true
                                strongSelf.updateButtonsMode()
                            default:
                                break
                            }
                            
                            strongSelf.call.requestVideo()
                        }
                        
                        strongSelf.call.makeOutgoingVideoView(completion: { [weak self] outgoingVideoView in
                            guard let strongSelf = self else {
                                return
                            }
                            
                            if let outgoingVideoView = outgoingVideoView {
                                outgoingVideoView.view.backgroundColor = .black
                                outgoingVideoView.view.clipsToBounds = true
                                
                                var updateLayoutImpl: ((ContainerViewLayout, CGFloat) -> Void)?
                                
                                let outgoingVideoNode = CallVideoNode(videoView: outgoingVideoView, disabledText: nil, assumeReadyAfterTimeout: true, isReadyUpdated: {
                                    guard let strongSelf = self, let (layout, navigationBarHeight) = strongSelf.validLayout else {
                                        return
                                    }
                                    updateLayoutImpl?(layout, navigationBarHeight)
                                }, orientationUpdated: {
                                    guard let strongSelf = self, let (layout, navigationBarHeight) = strongSelf.validLayout else {
                                        return
                                    }
                                    updateLayoutImpl?(layout, navigationBarHeight)
                                }, isFlippedUpdated: { _ in
                                    guard let strongSelf = self, let (layout, navigationBarHeight) = strongSelf.validLayout else {
                                        return
                                    }
                                    updateLayoutImpl?(layout, navigationBarHeight)
                                })
                                
                                let controller = VoiceChatCameraPreviewController(sharedContext: strongSelf.sharedContext, cameraNode: outgoingVideoNode, shareCamera: { previewVideoNode, _ in
                                    proceed(previewVideoNode as! CallVideoNode)
                                }, switchCamera: { [weak self] in
                                    Queue.mainQueue().after(0.1) {
                                        self?.call.switchVideoCamera()
                                    }
                                }, fromFrame: { [weak self] in
                                    guard let strongSelf = self else {
                                        return nil
                                    }
                                    
                                    return strongSelf.buttonsNode.videoButtonFrame().flatMap({ strongSelf.buttonsNode.view.convert($0, to: self?.view) })
                                }, toFrame: { [weak self] in
                                    guard let strongSelf = self, let (layout, navigationBarHeight) = strongSelf.validLayout else {
                                        return nil
                                    }
                                    
                                    if strongSelf.expandedVideoNode == nil {
                                        return CGRect(origin: .zero, size: layout.size)
                                    } else {
                                        return strongSelf.calculatePreviewVideoRect(layout: layout, navigationHeight: navigationBarHeight)
                                    }
                                })
                                strongSelf.present?(controller)
                                
                                updateLayoutImpl = { [weak controller] layout, navigationBarHeight in
                                    controller?.containerLayoutUpdated(layout, transition: .immediate)
                                }
                            }
                        })
                    })
                } else {
                    strongSelf.call.disableVideo()
                    strongSelf.cancelScheduledUIHiding()
                }
            default:
                break
            }
        }
        
        self.buttonsNode.rotateCamera = { [weak self] in
            guard let strongSelf = self, !strongSelf.areUserActionsDisabledNow() else {
                return
            }
            strongSelf.disableActionsUntilTimestamp = CACurrentMediaTime() + 1.0
            if let outgoingVideoNode = strongSelf.outgoingVideoNodeValue {
                outgoingVideoNode.flip(withBackground: outgoingVideoNode !== strongSelf.minimizedVideoNode)
            }
            strongSelf.call.switchVideoCamera()
            if let _ = strongSelf.outgoingVideoNodeValue {
                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                }
            }
            strongSelf.cancelScheduledUIHiding()
        }
        
        self.keyButtonNode.addTarget(self, action: #selector(self.keyPressed), forControlEvents: .touchUpInside)
        
        self.backButtonNode.addTarget(self, action: #selector(self.backPressed), forControlEvents: .touchUpInside)
        
        if shouldStayHiddenUntilConnection {
            self.containerNode.alpha = 0.0
            Queue.mainQueue().after(3.0, { [weak self] in
                self?.containerNode.alpha = 1.0
                self?.animateIn()
            })
        } else if call.isVideo && call.isOutgoing {
            self.containerNode.alpha = 0.0
            Queue.mainQueue().after(1.0, { [weak self] in
                self?.containerNode.alpha = 1.0
                self?.animateIn()
            })
        }
        
        self.orientationDidChangeObserver = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: nil, using: { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            let deviceOrientation = UIDevice.current.orientation
            if strongSelf.deviceOrientation != deviceOrientation {
                strongSelf.deviceOrientation = deviceOrientation
                if let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                }
            }
        })
        
        self.videoContainerNode.activate = { [weak self] sourceNode in
            guard let strongSelf = self else {
                return
            }
            let pinchController = PinchController(sourceNode: sourceNode, getContentAreaInScreenSpace: {
                return UIScreen.main.bounds
            })
            strongSelf.sharedContext.mainWindow?.presentInGlobalOverlay(pinchController)
            strongSelf.isVideoPinched = true
            
            strongSelf.videoContainerNode.contentNode.clipsToBounds = true
            strongSelf.videoContainerNode.backgroundColor = .black
            
            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                strongSelf.videoContainerNode.contentNode.cornerRadius = layout.deviceMetrics.screenCornerRadius
                
                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
            }
        }
        
        self.videoContainerNode.animatedOut = { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isVideoPinched = false
            
            strongSelf.videoContainerNode.backgroundColor = .clear
            strongSelf.videoContainerNode.contentNode.cornerRadius = 0.0
            
            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
        }
        
        self.animatedEmojiStickersDisposable = (TelegramEngine(account: account).stickers.loadedStickerPack(reference: .animatedEmoji, forceActualized: false)
        |> map { animatedEmoji -> [String: [StickerPackItem]] in
            var animatedEmojiStickers: [String: [StickerPackItem]] = [:]
            switch animatedEmoji {
                case let .result(_, items, _):
                    for item in items {
                        if let emoji = item.getStringRepresentationsOfIndexKeys().first {
                            animatedEmojiStickers[emoji.basicEmoji.0] = [item]
                            let strippedEmoji = emoji.basicEmoji.0.strippedEmoji
                            if animatedEmojiStickers[strippedEmoji] == nil {
                                animatedEmojiStickers[strippedEmoji] = [item]
                            }
                        }
                    }
                default:
                    break
            }
            return animatedEmojiStickers
        }
        |> deliverOnMainQueue).start(next: { [weak self] stickers in
            guard let strongSelf = self else {
                return
            }
            strongSelf.animatedEmojiStickers = stickers
        })
        
//        AnimatedStickerResourceSource(account: account, resource: self.animatedEmojiStickers[""]![0].file.resource)
//        AnimatedStickerResourceSource(a)
//        animationNode.setup(source: AnimatedStickerResourceSource(account: item.context.account, resource: file.resource, fitzModifier: fitzModifier, isVideo: file.mimeType == "video/webm"), width: Int(fittedSize.width), height: Int(fittedSize.height), playbackMode: playbackMode, mode: mode)
    }
    
    deinit {
        self.audioLevelDisposable?.dispose()
        self.audioLevelDisposable = nil
        if let orientationDidChangeObserver = self.orientationDidChangeObserver {
            NotificationCenter.default.removeObserver(orientationDidChangeObserver)
        }
    }
    
    func displayCameraTooltip() {
        guard self.pictureInPictureTransitionFraction.isZero, let location = self.buttonsNode.videoButtonFrame().flatMap({ frame -> CGRect in
            return self.buttonsNode.view.convert(frame, to: self.view)
        }) else {
            return
        }
                
        self.present?(TooltipScreen(account: self.account, text: self.presentationData.strings.Call_CameraOrScreenTooltip, style: .light, icon: nil, location: .point(location.offsetBy(dx: 0.0, dy: -14.0), .bottom), displayDuration: .custom(5.0), shouldDismissOnTouch: { _ in
            return .dismiss(consume: false)
        }))
    }
    
    var backgroundAnimationActive: Bool = false
    func activateGradientBackgroundNodeAnimationLoop() {
        self.backgroundAnimationActive = true
        self.gradientBackgroundNode.animateEvent(transition: .animated(duration: 0.7, curve: .linear), extendAnimation: false, backwards: false, completion: { [weak self] in
            if self?.backgroundAnimationActive == true {
                self?.activateGradientBackgroundNodeAnimationLoop()
            }
        })
    }
    
    override func didLoad() {
        super.didLoad()
        
        let panRecognizer = CallPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        panRecognizer.shouldBegin = { [weak self] _ in
            guard let strongSelf = self else {
                return false
            }
            if strongSelf.areUserActionsDisabledNow() {
                return false
            }
            return true
        }
        self.view.addGestureRecognizer(panRecognizer)
        
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        self.view.addGestureRecognizer(tapRecognizer)
    }
    
    func updatePeer(accountPeer: Peer, peer: Peer, hasOther: Bool) {
        if !arePeersEqual(self.peer, peer) {
            self.peer = peer
            if let peerReference = PeerReference(peer), !peer.profileImageRepresentations.isEmpty {
                let representations: [ImageRepresentationWithReference] = peer.profileImageRepresentations.map({ ImageRepresentationWithReference(representation: $0, reference: .avatar(peer: peerReference, resource: $0.resource)) })
                self.imageNode.setSignal(chatAvatarGalleryPhoto(account: self.account, representations: representations, immediateThumbnailData: nil, autoFetchFullSize: true))
                self.dimNode.isHidden = false
            } else {
                self.imageNode.setSignal(callDefaultBackground())
                self.dimNode.isHidden = true
            }
            
            self.toastNode.title = EnginePeer(peer).compactDisplayTitle
            self.statusNode.title = EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
            if hasOther {
                self.statusNode.subtitle = self.presentationData.strings.Call_AnsweringWithAccount(EnginePeer(accountPeer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                
                if let callState = self.callState {
                    self.updateCallState(callState)
                }
            }
            
            if let (layout, navigationBarHeight) = self.validLayout {
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
            }
        }
    }
    
    func updateAudioOutputs(availableOutputs: [AudioSessionOutput], currentOutput: AudioSessionOutput?) {
        if self.audioOutputState?.0 != availableOutputs || self.audioOutputState?.1 != currentOutput {
            self.audioOutputState = (availableOutputs, currentOutput)
            self.updateButtonsMode()
            
            self.setupAudioOutputs()
        }
    }
    
    private func setupAudioOutputs() {
        if self.outgoingVideoNodeValue != nil || self.incomingVideoNodeValue != nil || self.candidateOutgoingVideoNodeValue != nil || self.candidateIncomingVideoNodeValue != nil {
            if let audioOutputState = self.audioOutputState, let currentOutput = audioOutputState.currentOutput {
                switch currentOutput {
                case .headphones, .speaker:
                    break
                case let .port(port) where port.type == .bluetooth || port.type == .wired:
                    break
                default:
                    self.setCurrentAudioOutput?(.speaker)
                }
            }
        }
    }
    
    var latestCallStateTimestamp: Double?
    func updateCallState(_ callState: PresentationCallState) {
        self.callState = callState
        
        var hasVideo: Bool = false
        switch callState.videoState {
        case .active:
            hasVideo = true
        default:
            switch callState.remoteVideoState {
            case .active:
                hasVideo = true
            default:
                break
            }
        }
        
        func changeAllBlurEffects(view: UIView) {
            if view === self.keyPreviewNode?.view {
                return
            }
            
            if view === self.videoContainerNode.view {
                return
            }
            
            if let effectView = view as? UIVisualEffectView {
                setBlurEffect(view: effectView, hasVideo: hasVideo)
            } else {
                for subview in view.subviews {
                    changeAllBlurEffects(view: subview)
                }
            }
        }
        
        latestHasVideoState = hasVideo
        changeAllBlurEffects(view: self.view)
        
        let statusValue: CallControllerStatusValue
        var statusReception: Int32?
        
        switch callState.remoteVideoState {
        case .active, .paused:
            if !self.incomingVideoViewRequested {
                self.incomingVideoViewRequested = true
                let delayUntilInitialized = true
                self.call.makeIncomingVideoView(completion: { [weak self] incomingVideoView in
                    guard let strongSelf = self else {
                        return
                    }
                    if let incomingVideoView = incomingVideoView {
                        incomingVideoView.view.backgroundColor = .black
                        incomingVideoView.view.clipsToBounds = true
                        
                        let applyNode: () -> Void = {
                            guard let strongSelf = self, let incomingVideoNode = strongSelf.candidateIncomingVideoNodeValue else {
                                return
                            }
                            strongSelf.candidateIncomingVideoNodeValue = nil
                            
                            strongSelf.incomingVideoNodeValue = incomingVideoNode
                            if let expandedVideoNode = strongSelf.expandedVideoNode {
                                strongSelf.minimizedVideoNode = expandedVideoNode
                                strongSelf.videoContainerNode.contentNode.insertSubnode(incomingVideoNode, belowSubnode: expandedVideoNode)
                            } else {
                                strongSelf.videoContainerNode.contentNode.addSubnode(incomingVideoNode)
                            }
                            strongSelf.expandedVideoNode = incomingVideoNode
                            strongSelf.updateButtonsMode(transition: .animated(duration: 0.4, curve: .spring))
                            
                            strongSelf.updateDimVisibility()
                            strongSelf.maybeScheduleUIHidingForActiveVideoCall()
                        }
                        
                        let incomingVideoNode = CallVideoNode(videoView: incomingVideoView, disabledText: strongSelf.presentationData.strings.Call_RemoteVideoPaused(strongSelf.peer.flatMap(EnginePeer.init)?.compactDisplayTitle ?? "").string, assumeReadyAfterTimeout: false, isReadyUpdated: {
                            if delayUntilInitialized {
                                Queue.mainQueue().after(0.1, {
                                    applyNode()
                                })
                            }
                        }, orientationUpdated: {
                            guard let strongSelf = self else {
                                return
                            }
                            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                            }
                        }, isFlippedUpdated: { _ in
                        })
                        strongSelf.candidateIncomingVideoNodeValue = incomingVideoNode
                        strongSelf.setupAudioOutputs()
                        
                        if !delayUntilInitialized {
                            applyNode()
                        }
                    }
                })
            }
        case .inactive:
            self.candidateIncomingVideoNodeValue = nil
            if let incomingVideoNodeValue = self.incomingVideoNodeValue {
                if self.minimizedVideoNode == incomingVideoNodeValue {
                    self.minimizedVideoNode = nil
                    self.removedMinimizedVideoNodeValue = incomingVideoNodeValue
                }
                if self.expandedVideoNode == incomingVideoNodeValue {
                    self.expandedVideoNode = nil
                    self.removedExpandedVideoNodeValue = incomingVideoNodeValue
                    
                    if let minimizedVideoNode = self.minimizedVideoNode {
                        self.expandedVideoNode = minimizedVideoNode
                        self.minimizedVideoNode = nil
                    }
                }
                self.incomingVideoNodeValue = nil
                self.incomingVideoViewRequested = false
            }
        }
        
        switch callState.videoState {
        case .active(false), .paused(false):
            if !self.outgoingVideoViewRequested {
                self.outgoingVideoViewRequested = true
                let delayUntilInitialized = self.isRequestingVideo
                let applyNode: () -> Void = { [weak self] in
                    guard let strongSelf = self, let outgoingVideoNode = strongSelf.candidateOutgoingVideoNodeValue else {
                        return
                    }
                    strongSelf.candidateOutgoingVideoNodeValue = nil
                    
                    if strongSelf.isRequestingVideo {
                        strongSelf.isRequestingVideo = false
                        strongSelf.animateRequestedVideoOnce = true
                    }

                    strongSelf.outgoingVideoNodeValue = outgoingVideoNode
                    if let expandedVideoNode = strongSelf.expandedVideoNode {
                        strongSelf.minimizedVideoNode = outgoingVideoNode
                        strongSelf.videoContainerNode.contentNode.insertSubnode(outgoingVideoNode, aboveSubnode: expandedVideoNode)
                    } else {
                        strongSelf.expandedVideoNode = outgoingVideoNode
                        strongSelf.videoContainerNode.contentNode.addSubnode(outgoingVideoNode)
                    }
                    strongSelf.updateButtonsMode(transition: .animated(duration: 0.4, curve: .spring))
                    
                    strongSelf.updateDimVisibility()
                    strongSelf.maybeScheduleUIHidingForActiveVideoCall()
                }
                
                if self.candidateOutgoingVideoNodeValue != nil {
                    applyNode()
                    break
                }
                
                self.call.makeOutgoingVideoView(completion: { [weak self] outgoingVideoView in
                    guard let strongSelf = self else {
                        return
                    }
                    
                    if let outgoingVideoView = outgoingVideoView {
                        outgoingVideoView.view.backgroundColor = .black
                        outgoingVideoView.view.clipsToBounds = true
                        
                        let outgoingVideoNode = CallVideoNode(videoView: outgoingVideoView, disabledText: nil, assumeReadyAfterTimeout: true, isReadyUpdated: {
                            if delayUntilInitialized {
                                Queue.mainQueue().after(0.4, {
                                    applyNode()
                                })
                            }
                        }, orientationUpdated: {
                            guard let strongSelf = self else {
                                return
                            }
                            if let (layout, navigationBarHeight) = strongSelf.validLayout {
                                strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                            }
                        }, isFlippedUpdated: { videoNode in
                            guard let _ = self else {
                                return
                            }
                            /*if videoNode === strongSelf.minimizedVideoNode, let tempView = videoNode.view.snapshotView(afterScreenUpdates: true) {
                                videoNode.view.superview?.insertSubview(tempView, aboveSubview: videoNode.view)
                                videoNode.view.frame = videoNode.frame
                                let transitionOptions: UIView.AnimationOptions = [.transitionFlipFromRight, .showHideTransitionViews]

                                UIView.transition(with: tempView, duration: 1.0, options: transitionOptions, animations: {
                                    tempView.isHidden = true
                                }, completion: { [weak tempView] _ in
                                    tempView?.removeFromSuperview()
                                })

                                videoNode.view.isHidden = true
                                UIView.transition(with: videoNode.view, duration: 1.0, options: transitionOptions, animations: {
                                    videoNode.view.isHidden = false
                                })
                            }*/
                        })
                        
                        strongSelf.candidateOutgoingVideoNodeValue = outgoingVideoNode
                        strongSelf.setupAudioOutputs()
                        
                        if !delayUntilInitialized {
                            applyNode()
                        }
                    }
                })
            }
        default:
            self.candidateOutgoingVideoNodeValue = nil
            if let outgoingVideoNodeValue = self.outgoingVideoNodeValue {
                if self.minimizedVideoNode == outgoingVideoNodeValue {
                    self.minimizedVideoNode = nil
                    self.removedMinimizedVideoNodeValue = outgoingVideoNodeValue
                }
                if self.expandedVideoNode == self.outgoingVideoNodeValue {
                    self.expandedVideoNode = nil
                    self.removedExpandedVideoNodeValue = outgoingVideoNodeValue
                    
                    if let minimizedVideoNode = self.minimizedVideoNode {
                        self.expandedVideoNode = minimizedVideoNode
                        self.minimizedVideoNode = nil
                    }
                }
                self.outgoingVideoNodeValue = nil
                self.outgoingVideoViewRequested = false
            }
        }
        
        if let incomingVideoNode = self.incomingVideoNodeValue {
            switch callState.state {
            case .terminating, .terminated:
                break
            default:
                let isActive: Bool
                switch callState.remoteVideoState {
                case .inactive, .paused:
                    isActive = false
                case .active:
                    isActive = true
                }
                incomingVideoNode.updateIsBlurred(isBlurred: !isActive)
            }
        }
        
        switch callState.state {
            case .waiting, .connecting:
                statusValue = .text(string: self.presentationData.strings.Call_StatusConnecting, displayLogo: false, displayLoadingIndicator: true, displayEndIndicator: false)
            case let .requesting(ringing):
                if ringing {
                    statusValue = .text(string: self.presentationData.strings.Call_StatusRinging, displayLogo: false, displayLoadingIndicator: true, displayEndIndicator: false)
                } else {
                    statusValue = .text(string: self.presentationData.strings.Call_StatusRequesting, displayLogo: false, displayLoadingIndicator: true, displayEndIndicator: false)
                }
            case .terminating:
                self.call.disableVideo()
                self.dismissAllTooltips?()
                self.cancelScheduledUIHiding()
                statusValue = self.statusNode.status //.text(string: self.presentationData.strings.Call_StatusEnded, displayLogo: false, displayLoadingIndicator: false, displayEndIndicator: true)
            case let .terminated(_, reason, _):
                if self.keyPreviewNode != nil {
                    self.backPressed()
                }
                if let reason = reason {
                    switch reason {
                        case let .ended(type):
                            switch type {
                                case .busy:
                                    statusValue = .text(string: self.presentationData.strings.Call_StatusBusy, displayLogo: false, displayLoadingIndicator: false, displayEndIndicator: true)
                                case .missed:
                                    statusValue = .text(string: self.presentationData.strings.Call_StatusEnded, displayLogo: false, displayLoadingIndicator: false, displayEndIndicator: true)
                                case .hungUp:
                                    if let duration = self.latestCallStateTimestamp.map({ Int32(CFAbsoluteTimeGetCurrent() - $0) }), duration > 0 {
                                        let durationString: String
                                        if duration > 60 * 60 {
                                            durationString = String(format: "%02d:%02d:%02d", arguments: [duration / 3600, (duration / 60) % 60, duration % 60])
                                        } else {
                                            durationString = String(format: "%02d:%02d", arguments: [(duration / 60) % 60, duration % 60])
                                        }
                                        statusValue = .text(string: durationString, displayLogo: false, displayLoadingIndicator: false, displayEndIndicator: true)
                                    } else {
                                        statusValue = .text(string: self.presentationData.strings.Call_StatusEnded, displayLogo: false, displayLoadingIndicator: false, displayEndIndicator: true)
                                    }
                            }
                        case let .error(error):
                            let text = self.presentationData.strings.Call_StatusFailed
                            switch error {
                            case let .notSupportedByPeer(isVideo):
                                if !self.displayedVersionOutdatedAlert, let peer = self.peer {
                                    self.displayedVersionOutdatedAlert = true
                                    
                                    let text: String
                                    if isVideo {
                                        text = self.presentationData.strings.Call_ParticipantVideoVersionOutdatedError(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                                    } else {
                                        text = self.presentationData.strings.Call_ParticipantVersionOutdatedError(EnginePeer(peer).displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)).string
                                    }
                                    
                                    self.present?(textAlertController(sharedContext: self.sharedContext, title: nil, text: text, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {
                                    })]))
                                }
                            default:
                                break
                            }
                            statusValue = .text(string: text, displayLogo: false, displayLoadingIndicator: false, displayEndIndicator: true)
                    }
                } else {
                    statusValue = .text(string: self.presentationData.strings.Call_StatusEnded, displayLogo: false, displayLoadingIndicator: false, displayEndIndicator: true)
                }
            case .ringing:
                var text: String
                if self.call.isVideo {
                    text = self.presentationData.strings.Call_IncomingVideoCall
                } else {
                    text = self.presentationData.strings.Call_IncomingVoiceCall
                }
                if !self.statusNode.subtitle.isEmpty {
                    text += "\n\(self.statusNode.subtitle)"
                }
                statusValue = .text(string: text, displayLogo: false, displayLoadingIndicator: true, displayEndIndicator: false)
            case .active(let timestamp, let reception, let keyVisualHash), .reconnecting(let timestamp, let reception, let keyVisualHash):
                self.latestCallStateTimestamp = timestamp
                let strings = self.presentationData.strings
                var isReconnecting = false
                if case .reconnecting = callState.state {
                    isReconnecting = true
                }
                if self.keyTextData?.0 != keyVisualHash {
                    let text = stringForEmojiHashOfData(keyVisualHash, 4)!
                    self.keyTextData = (keyVisualHash, text)

                    let keyTextSize = self.keyButtonNode.measure(CGSize(width: 200.0, height: 200.0))
                    self.keyButtonNode.frame = CGRect(origin: self.keyButtonNode.frame.origin, size: keyTextSize)
                    self.keyButtonNode.setup(key: text, account: self.account, animatedEmojiStickers: self.animatedEmojiStickers)
                    self.keyButtonNode.animateIn()
                    
                    if UserDefaults.standard.value(forKey: "didTapCallKeyTooltipNode") == nil {
                        let keyTooltipNode = CallKeyTooltipNode()
                        keyTooltipNode.onTap = { [weak self] in
                            UserDefaults.standard.set(true, forKey: "didTapCallKeyTooltipNode")
                            self?.keyPressed()
                        }
                        
                        self.containerNode.insertSubnode(keyTooltipNode, belowSubnode: self.keyButtonNode)
                        self.keyTooltipNode = keyTooltipNode
                        
                        Queue.mainQueue().after(2.0 * UIView.animationDurationFactor()) { [weak self] in
                            if let strongSelf = self {
                                strongSelf.dismissKeyTooltipNode()
                            }
                        }
                    }
                    
                    if let (layout, navigationBarHeight) = self.validLayout {
                        self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
                    }
                }
                
                statusValue = .timer({ value, measure in
                    if isReconnecting || (self.outgoingVideoViewRequested && value == "00:00" && !measure) {
                        return strings.Call_StatusConnecting
                    } else {
                        return value
                    }
                }, timestamp)
                if case .active = callState.state {
                    statusReception = reception
                }
        }
        if self.shouldStayHiddenUntilConnection {
            switch callState.state {
                case .connecting, .active:
                    self.containerNode.alpha = 1.0
                default:
                    break
            }
        }
        self.statusNode.status = statusValue
        self.statusNode.reception = statusReception
        
        if let callState = self.callState {
            switch callState.state {
            case .active, .connecting, .reconnecting:
                break
            default:
                self.isUIHidden = false
            }
        }
        
        switch callState.state {
        case .connecting, .requesting, .ringing, .waiting, .terminated, .terminating:
            self.gradientBackgroundNode.updateColors(colors: blueVioletGradientColors, invalidate: false)
        case .active(_, let reception, _), .reconnecting(_, let reception, _):
            if let reception = reception, reception <= 1 {
                self.gradientBackgroundNode.updateColors(colors: orangeRedGradientColors, invalidate: false)
            } else {
                self.gradientBackgroundNode.updateColors(colors: blueGreenGradientColors, invalidate: false)
            }
        }
        
        self.updateToastContent()
        self.updateButtonsMode()
        self.updateDimVisibility()
        
        if self.incomingVideoViewRequested || self.outgoingVideoViewRequested {
            if self.incomingVideoViewRequested && self.outgoingVideoViewRequested {
                self.displayedCameraTooltip = true
            }
            self.displayedCameraConfirmation = true
        }
        if self.incomingVideoViewRequested && !self.outgoingVideoViewRequested && !self.displayedCameraTooltip && (self.toastContent?.isEmpty ?? true) {
            self.displayedCameraTooltip = true
            Queue.mainQueue().after(2.0) {
                self.displayCameraTooltip()
            }
        }
        
        if case let .terminated(id, _, reportRating) = callState.state, let callId = id {
            let presentRating = reportRating || self.forceReportRating
            if presentRating {
                if self.waitRateCall == false {
                    self.waitRateCall = true
                    self.waitRateCallId = callId
                    self.presentRateCallNode()
                }
//                self.presentCallRating?(callId, self.call.isVideo)
            }
            self.callEnded?(presentRating)
        }
        
        let hasIncomingVideoNode = self.incomingVideoNodeValue != nil && self.expandedVideoNode === self.incomingVideoNodeValue
        self.videoContainerNode.isPinchGestureEnabled = hasIncomingVideoNode
    }
    
    var keyTooltipNode: CallKeyTooltipNode?
    
    func dismissKeyTooltipNode() {
        guard let keyTooltipNode = self.keyTooltipNode else {
            return
        }
        
        self.keyTooltipNode = nil
        keyTooltipNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        keyTooltipNode.layer.animateScale(from: 1.0, to: 0.3, duration: 0.3, removeOnCompletion: false)
        keyTooltipNode.layer.animatePosition(from: keyTooltipNode.layer.position, to: self.keyButtonNode.layer.position.offsetBy(dx: -20.0, dy: 20.0), duration: 0.3, removeOnCompletion: false) { [weak keyTooltipNode] _ in
            keyTooltipNode?.removeFromSupernode()
        }
    }
    
    class CallKeyTooltipNode: ASDisplayNode {
        
        let containerNode: ASDisplayNode
        let notchNode: ASImageNode
        let textNode: ImmediateTextNode
        let imageNode: ASImageNode
        
        var onTap: (() -> Void)?
        
        override init() {
            self.containerNode = ASDisplayNode()
            self.notchNode = ASImageNode()
            self.textNode = ImmediateTextNode()
            self.imageNode = ASImageNode()
            
            super.init()
            
            self.notchNode.image = UIImage(bundleImageName: "CallKeyNotch")
            self.textNode.attributedText = NSAttributedString(string: "Encryption key of this call", font: Font.regular(15.0), textColor: .white)
            self.imageNode.image = UIImage(bundleImageName: "CallKeyIcon")
            self.containerNode.backgroundColor = UIColor.white.withAlphaComponent(0.25)
            self.containerNode.cornerRadius = 14.0
            
            self.containerNode.addSubnode(self.textNode)
            self.containerNode.addSubnode(self.imageNode)
            self.addSubnode(self.containerNode)
            self.addSubnode(self.notchNode)
            
            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
            self.view.addGestureRecognizer(tapRecognizer)
        }
        
        @objc func tapGesture(_ sender: UITapGestureRecognizer) {
            self.onTap?()
        }
        
        override func layout() {
            super.layout()
            
            let notchNodeSize = CGSize(width: 19.0, height: 8.0)
            self.notchNode.frame = CGRect(x: self.bounds.width - notchNodeSize.width - 38.0, y: 0.0, width: notchNodeSize.width, height: notchNodeSize.height)
            
            let containerNodeSize = CGSize(width: self.bounds.width, height: self.bounds.height - notchNodeSize.height)
            self.containerNode.frame = CGRect(x: 0.0, y: notchNodeSize.height, width: containerNodeSize.width, height: containerNodeSize.height)
            
            let textNodeSize = self.textNode.updateLayout(self.containerNode.bounds.size)
            self.textNode.frame = CGRect(x: self.containerNode.bounds.width - textNodeSize.width - 16.0, y: (self.containerNode.bounds.height - textNodeSize.height) / 2.0, width: textNodeSize.width, height: textNodeSize.height)
            
            let imageNodeSize = CGSize(width: 9.0, height: 19.0)
            self.imageNode.frame = CGRect(x: 16.0, y: (self.containerNode.bounds.height - imageNodeSize.height) / 2.0, width: imageNodeSize.width, height: imageNodeSize.height)
        }
    }
    
    func presentRateCallNode() {
        let rateCallNode = RateCallNode()
        let rateCallSize = CGSize(width: min(self.bounds.width - 44.0 * 2.0, 304.0), height: 142.0)
        let rateCallFrame = CGRect(x: (self.containerNode.bounds.width - rateCallSize.width) / 2.0, y: self.statusNode.frame.maxY + 50.0, width: rateCallSize.width, height: rateCallSize.height)
        rateCallNode.frame = rateCallFrame
        rateCallNode.rateCall = { [weak self] starsCount in
            if let strongSelf = self, strongSelf.waitRateCall {
                if let callId = strongSelf.waitRateCallId {
                    _ = rateCallAndSendLogs(engine: TelegramEngine(account: strongSelf.account), callId: callId, starsCount: starsCount, comment: "", userInitiated: false, includeLogs: false)
                }
                strongSelf.waitRateCall = false
                strongSelf.back?()
            }
        }
        
        self.containerNode.addSubnode(rateCallNode)
        rateCallNode.layoutIfNeeded()
        rateCallNode.layer.animateScale(from: 0.7, to: 1.0, duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring)
        rateCallNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
        
        let endButtonFrame = self.buttonsNode.endButtonFrame().map({ self.convert($0, from: self.buttonsNode) }) ?? self.buttonsNode.frame
        let rateCallButtonNode = RateCallButtonNode()
        let rateCallButtonSize = CGSize(width: rateCallSize.width, height: 50.0)
        let rateCallButtonFrame = CGRect(x: (self.containerNode.bounds.width - rateCallButtonSize.width) / 2.0, y: endButtonFrame.minY + (endButtonFrame.height - rateCallButtonSize.height) / 2.0, width: rateCallButtonSize.width, height: rateCallButtonSize.height)
        rateCallButtonNode.frame = rateCallButtonFrame
        rateCallButtonNode.timerExpired = { [weak self] in
            if let strongSelf = self, strongSelf.waitRateCall {
                strongSelf.waitRateCall = false
                strongSelf.back?()
            }
        }
        
        self.containerNode.addSubnode(rateCallButtonNode)
        rateCallButtonNode.layoutIfNeeded()
        rateCallButtonNode.animateIn(from: endButtonFrame)
        
        self.backButtonNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.4, removeOnCompletion: false)
        self.backButtonArrowNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.4, removeOnCompletion: false)
        self.keyButtonNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.4, removeOnCompletion: false)
        self.buttonsNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.4, removeOnCompletion: false)
        self.voiceBlobNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.4, removeOnCompletion: false)
        self.toastNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.4, removeOnCompletion: false)
        self.keyPreviewNode?.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.4, removeOnCompletion: false)
    }
    
    class RateCallButtonNode: ASDisplayNode {
        
        let backgroundLayer = CAShapeLayer()
        let progressLayer = CAShapeLayer()
        let containerLayer = CALayer()
        let textLayer = CALayer()
        
        var timerExpired: (() -> Void)?
        
        override init() {
            super.init()
            
            self.progressLayer.fillColor = UIColor.white.cgColor
            self.backgroundLayer.fillColor = UIColor.white.withAlphaComponent(0.25).cgColor
            
            self.layer.addSublayer(self.containerLayer)
            self.containerLayer.addSublayer(self.backgroundLayer)
            self.containerLayer.addSublayer(self.progressLayer)
            self.layer.addSublayer(self.textLayer)
            
            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
            self.view.addGestureRecognizer(tapRecognizer)
        }
        
        @objc func tapGesture(_ sender: UITapGestureRecognizer) {
            self.timerExpired?()
        }
        
        override func layout() {
            super.layout()
            
            self.containerLayer.frame = self.bounds
            self.progressLayer.frame = self.containerLayer.bounds
            self.backgroundLayer.frame = self.containerLayer.bounds
            self.textLayer.frame = self.bounds
            
            let offset = CGFloat(64.0)
            let textMaskFrame = CGRect(
                x: self.bounds.minX - offset / 2.0,
                y: self.bounds.minY - offset / 2.0,
                width: self.bounds.width + offset,
                height: self.bounds.height + offset
            )
            
            let textMaskImage = textImage(frame: textMaskFrame, inverted: true)
            let containerLayerMask = CAShapeLayer()
            containerLayerMask.frame = textMaskFrame
            containerLayerMask.contents = textMaskImage.cgImage
            self.containerLayer.mask = containerLayerMask
            
            let textLayerImage = textImage(frame: self.textLayer.bounds, inverted: false)
            self.textLayer.contents = textLayerImage.cgImage
            
            let textLayerMask = CALayer()
            textLayerMask.backgroundColor = UIColor.white.cgColor
            textLayerMask.frame = .zero
            self.textLayer.mask = textLayerMask
        }
        
        func textImage(frame: CGRect, inverted: Bool) -> UIImage {
            let text = NSAttributedString(string: "Close", font: Font.semibold(17.0), textColor: .white)
            let textSize = text.size()
            let textFrame = CGRect(
                x: (frame.width - textSize.width) / 2.0,
                y: (frame.height - textSize.height) / 2.0,
                width: textSize.width,
                height: textSize.height
            )
            
            let textImage = UIGraphicsImageRenderer(size: frame.size).image { _ in guard let context = UIGraphicsGetCurrentContext() else { return }
                if inverted {
                    context.setFillColor(UIColor.white.cgColor)
                    context.fill(CGRect(origin: .zero, size: frame.size))
                    context.setBlendMode(.clear)
                }
                text.draw(in: textFrame)
            }
            
            return textImage
        }
        
        func animateIn(from rect: CGRect) {
            let rect = self.supernode?.convert(rect, to: self) ?? rect
            let fromPath = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2.0).cgPath
            let toPath = UIBezierPath(roundedRect: self.bounds, cornerRadius: 14.0).cgPath
            self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
            self.progressLayer.path = toPath
            self.progressLayer.animate(from: UIColor.red.cgColor, to: UIColor.white.cgColor, keyPath: "fillColor", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.4)
            self.progressLayer.animate(from: fromPath, to: toPath, keyPath: "path", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.4) { [weak self] _ in
                self?.backgroundLayer.path = toPath
                self?.animateOut()
            }
        }
        
        func animateOut() {
            let progressMaskLayer = CAShapeLayer()
            progressMaskLayer.frame = self.bounds
            progressMaskLayer.path = self.progressLayer.path
            self.progressLayer.mask = progressMaskLayer
            self.textLayer.mask?.animateFrame(from: CGRect(origin: .zero, size: CGSize(width: 0.0, height: self.bounds.width)), to: self.bounds, duration: 5.0, timingFunction: CAMediaTimingFunctionName.linear.rawValue, removeOnCompletion: false)
            progressMaskLayer.animatePosition(from: progressMaskLayer.position, to: progressMaskLayer.position.offsetBy(dx: progressMaskLayer.bounds.width, dy: 0.0), duration: 5.0, timingFunction: CAMediaTimingFunctionName.linear.rawValue, removeOnCompletion: false) { [weak self] _ in
                self?.timerExpired?()
                self?.timerExpired = nil
            }
        }
    }
    
    class RateCallNode: ASDisplayNode {
        
        let titleNode: ImmediateTextNode
        let textNode: ImmediateTextNode
        let starNodes: [ASImageNode]
        
        var rateCall: ((Int) -> Void)?
        
        override init() {
            self.titleNode = ImmediateTextNode()
            self.textNode = ImmediateTextNode()
            self.starNodes = (0..<5).map { _ in
                let node = ASImageNode()
                node.image = UIImage(bundleImageName: "RateCallStarEmpty")
                return node
            }
            super.init()
            
            self.addSubnode(self.titleNode)
            self.addSubnode(self.textNode)
            self.starNodes.forEach {
                self.addSubnode($0)
            }
            
            self.titleNode.attributedText = NSAttributedString(string: "Rate This Call", font: Font.semibold(16.0), textColor: .white)
            self.textNode.attributedText = NSAttributedString(string: "Please rate the quality of this call.", font: Font.regular(16.0), textColor: .white)
            
            self.backgroundColor = UIColor.white.withAlphaComponent(0.25)
            self.layer.cornerRadius = 20.0
            
            let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
            self.view.addGestureRecognizer(tapRecognizer)
        }
        
        @objc func tapGesture(_ sender: UITapGestureRecognizer) {
            let point = sender.location(in: sender.view)
            guard self.starNodes.contains(where: { $0.frame.contains(point ) }) else {
                return
            }
            
            for (index, node) in self.starNodes.enumerated() {
                node.image = UIImage(bundleImageName: "RateCallStarFilled")
                node.layer.animateKeyframes(values: [NSNumber(1.0), NSNumber(1.1), NSNumber(1.0)], duration: 0.2, keyPath: "transform.scale")
                if node.frame.contains(point) {
                    if (index + 1) >= 4 {
                        let animatedNode = DirectAnimatedStickerNode()
                        let animatedNodeSize = CGSize(width: 132.0, height: 132.0)
                        animatedNode.visibility = true
                        animatedNode.frame.size = animatedNodeSize
                        animatedNode.layer.position = node.layer.position
                        self.addSubnode(animatedNode)
                        let animatedNodeSource = AnimatedStickerNodeLocalFileSource(name: "RateCallAnimation")
                        animatedNode.setup(source: animatedNodeSource, width: Int(animatedNodeSize.width * UIScreenScale), height: Int(animatedNodeSize.height * UIScreenScale), playbackMode: .once, mode: .direct(cachePathPrefix: nil))
                    }
                    
                    Queue.mainQueue().after(1.0) { [weak self] in
                        self?.rateCall?(index + 1)
                        self?.rateCall = nil
                    }
                    
                    break
                }
            }
        }
        
        override func layout() {
            super.layout()
            
            let titleNodeSize = self.titleNode.updateLayout(self.bounds.size)
            self.titleNode.frame = CGRect(x: (self.bounds.width - titleNodeSize.width) / 2.0, y: 20.0, width: titleNodeSize.width, height: titleNodeSize.height)
            
            let textNodeSize = self.textNode.updateLayout(self.bounds.size)
            self.textNode.frame = CGRect(x: (self.bounds.width - textNodeSize.width) / 2.0, y: self.titleNode.frame.maxY + 10.0, width: textNodeSize.width, height: textNodeSize.height)
            
            let starNodeSize = CGSize(width: 42.0, height: 42.0)
            let starNodeSpacing = CGFloat(4.0)
            let starNodeRowWidth = starNodeSize.width * 5.0 + starNodeSpacing * 4.0
            let starNodeRowOffsetY = self.textNode.frame.maxY + 10.0
            let starNodeRowOffsetX = (self.bounds.width - starNodeRowWidth) / 2.0
            self.starNodes.enumerated().forEach { (index, node) in
                node.frame = CGRect(x: starNodeRowOffsetX + CGFloat(index) * starNodeSize.width + CGFloat(index) * starNodeSpacing, y: starNodeRowOffsetY, width: starNodeSize.width, height: starNodeSize.height)
            }
        }
    }
    
    private func updateToastContent() {
        guard let callState = self.callState else {
            return
        }
        if case .terminating = callState.state {
        } else if case .terminated = callState.state {
        } else {
            var toastContent: CallControllerToastContent = []
            if case .active = callState.state {
                if let displayToastsAfterTimestamp = self.displayToastsAfterTimestamp {
                    if CACurrentMediaTime() > displayToastsAfterTimestamp {
                        if case .inactive = callState.remoteVideoState, self.hasVideoNodes {
                            toastContent.insert(.camera)
                        }
                        if case .muted = callState.remoteAudioState {
                            toastContent.insert(.microphone)
                        }
                        if case .low = callState.remoteBatteryLevel {
                            toastContent.insert(.battery)
                        }
                    }
                } else {
                    self.displayToastsAfterTimestamp = CACurrentMediaTime() + 1.5
                }
            }
            if self.isMuted, let (availableOutputs, _) = self.audioOutputState, availableOutputs.count > 0 {
                toastContent.insert(.mute)
            }
            self.toastContent = toastContent
        }
    }
    
    private func updateDimVisibility(transition: ContainedViewLayoutTransition = .animated(duration: 0.3, curve: .easeInOut)) {
        if self.keyPreviewNode == nil {
            transition.updateTransformScale(node: self.imageNode, scale: 1.0)
            transition.updateAlpha(node: self.imageNode, alpha: 1.0)
            transition.updateTransformScale(node: self.voiceBlobNode, scale: 1.0)
            transition.updateAlpha(node: self.voiceBlobNode, alpha: 1.0)
        } else {
            transition.updateTransformScale(node: self.imageNode, scale: 0.1)
            transition.updateAlpha(node: self.imageNode, alpha: 0.0)
            transition.updateTransformScale(node: self.voiceBlobNode, scale: 0.1)
            transition.updateAlpha(node: self.voiceBlobNode, alpha: 0.0)
        }
//        guard let callState = self.callState else {
//            return
//        }
        
//        let visible = true
//        if case .active = callState.state, self.incomingVideoNodeValue != nil || self.outgoingVideoNodeValue != nil {
//            visible = false
//        }
        
//        let currentVisible = self.dimNode.image == nil
//        if visible != currentVisible {
//            let color = visible ? UIColor(rgb: 0x000000, alpha: 0.3) : UIColor.clear
//            let image: UIImage? = visible ? nil : generateGradientImage(size: CGSize(width: 1.0, height: 640.0), colors: [UIColor.black.withAlphaComponent(0.3), UIColor.clear, UIColor.clear, UIColor.black.withAlphaComponent(0.3)], locations: [0.0, 0.22, 0.7, 1.0])
//            if case let .animated(duration, _) = transition {
//                UIView.transition(with: self.dimNode.view, duration: duration, options: .transitionCrossDissolve, animations: {
//                    self.dimNode.backgroundColor = color
//                    self.dimNode.image = image
//                }, completion: nil)
//            } else {
//                self.dimNode.backgroundColor = color
//                self.dimNode.image = image
//            }
//        }
//        self.statusNode.setVisible(visible || self.keyPreviewNode != nil, transition: transition)
    }
    
    private func maybeScheduleUIHidingForActiveVideoCall() {
        guard let callState = self.callState, case .active = callState.state, self.incomingVideoNodeValue != nil && self.outgoingVideoNodeValue != nil, !self.hiddenUIForActiveVideoCallOnce && self.keyPreviewNode == nil else {
            return
        }
        
        let timer = SwiftSignalKit.Timer(timeout: 3.0, repeat: false, completion: { [weak self] in
            if let strongSelf = self {
                var updated = false
                if let callState = strongSelf.callState, !strongSelf.isUIHidden {
                    switch callState.state {
                        case .active, .connecting, .reconnecting:
                            strongSelf.isUIHidden = true
                            updated = true
                        default:
                            break
                    }
                }
                if updated, let (layout, navigationBarHeight) = strongSelf.validLayout {
                    strongSelf.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                }
                strongSelf.hideUIForActiveVideoCallTimer = nil
            }
        }, queue: Queue.mainQueue())
        timer.start()
        self.hideUIForActiveVideoCallTimer = timer
        self.hiddenUIForActiveVideoCallOnce = true
    }
    
    private func cancelScheduledUIHiding() {
        self.hideUIForActiveVideoCallTimer?.invalidate()
        self.hideUIForActiveVideoCallTimer = nil
    }
    
    private var buttonsTerminationMode: CallControllerButtonsMode?
    
    private func updateButtonsMode(transition: ContainedViewLayoutTransition = .animated(duration: 0.6, curve: .spring)) {
        guard let callState = self.callState else {
            return
        }
        
        var mode: CallControllerButtonsSpeakerMode = .none
        var hasAudioRouteMenu: Bool = false
        if let (availableOutputs, maybeCurrentOutput) = self.audioOutputState, let currentOutput = maybeCurrentOutput {
            hasAudioRouteMenu = availableOutputs.count > 2
            switch currentOutput {
                case .builtin:
                    mode = .builtin
                case .speaker:
                    mode = .speaker
                case .headphones:
                    mode = .headphones
                case let .port(port):
                    var type: CallControllerButtonsSpeakerMode.BluetoothType = .generic
                    let portName = port.name.lowercased()
                    if portName.contains("airpods pro") {
                        type = .airpodsPro
                    } else if portName.contains("airpods") {
                        type = .airpods
                    }
                    mode = .bluetooth(type)
            }
            if availableOutputs.count <= 1 {
                mode = .none
            }
        }
        var mappedVideoState = CallControllerButtonsMode.VideoState(isAvailable: false, isCameraActive: self.outgoingVideoNodeValue != nil, isScreencastActive: false, canChangeStatus: false, hasVideo: self.outgoingVideoNodeValue != nil || self.incomingVideoNodeValue != nil, isInitializingCamera: self.isRequestingVideo)
        switch callState.videoState {
        case .notAvailable:
            break
        case .inactive:
            mappedVideoState.isAvailable = true
            mappedVideoState.canChangeStatus = true
        case .active(let isScreencast), .paused(let isScreencast):
            mappedVideoState.isAvailable = true
            mappedVideoState.canChangeStatus = true
            if isScreencast {
                mappedVideoState.isScreencastActive = true
                mappedVideoState.hasVideo = true
            }
        }
        
        switch callState.state {
        case .ringing:
            self.buttonsMode = .incoming(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            self.buttonsTerminationMode = buttonsMode
        case .waiting, .requesting:
            self.buttonsMode = .outgoingRinging(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            self.buttonsTerminationMode = buttonsMode
        case .active, .connecting, .reconnecting:
            self.buttonsMode = .active(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            self.buttonsTerminationMode = buttonsMode
        case .terminating, .terminated:
            if let buttonsTerminationMode = self.buttonsTerminationMode {
                self.buttonsMode = buttonsTerminationMode
            } else {
                self.buttonsMode = .active(speakerMode: mode, hasAudioRouteMenu: hasAudioRouteMenu, videoState: mappedVideoState)
            }
        }
                
        if let (layout, navigationHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: transition)
        }
    }
    
    func animateIn() {
        if !self.containerNode.alpha.isZero {
            var bounds = self.bounds
            bounds.origin = CGPoint()
            self.bounds = bounds
            self.layer.removeAnimation(forKey: "bounds")
            self.statusBar.layer.removeAnimation(forKey: "opacity")
            self.containerNode.layer.removeAnimation(forKey: "opacity")
            self.containerNode.layer.removeAnimation(forKey: "scale")
            self.statusBar.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            if !self.shouldStayHiddenUntilConnection {
                self.containerNode.layer.animateScale(from: 1.04, to: 1.0, duration: 0.3)
                self.containerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
        }
    }
    
    var waitRateCall = false
    var waitRateCallId: CallId?
    func animateOut(completion: @escaping () -> Void) {
        if self.waitRateCall {
            return
        }
        
        self.statusBar.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        if !self.shouldStayHiddenUntilConnection || self.containerNode.alpha > 0.0 {
            self.containerNode.layer.allowsGroupOpacity = true
            self.containerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak self] _ in
                self?.containerNode.layer.allowsGroupOpacity = false
            })
            self.containerNode.layer.animateScale(from: 1.0, to: 1.04, duration: 0.3, removeOnCompletion: false, completion: { _ in
                completion()
            })
        } else {
            completion()
        }
    }
    
    func expandFromPipIfPossible() {
        if self.pictureInPictureTransitionFraction.isEqual(to: 1.0), let (layout, navigationHeight) = self.validLayout {
            self.pictureInPictureTransitionFraction = 0.0
            
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
        }
    }
    
    private func calculatePreviewVideoRect(layout: ContainerViewLayout, navigationHeight: CGFloat) -> CGRect {
        let buttonsHeight: CGFloat = self.buttonsNode.bounds.height
        let toastHeight: CGFloat = self.toastNode.bounds.height
        let toastInset = (toastHeight > 0.0 ? toastHeight + 22.0 : 0.0)
        
        var fullInsets = layout.insets(options: .statusBar)
    
        var cleanInsets = fullInsets
        cleanInsets.bottom = max(layout.intrinsicInsets.bottom, 20.0) + toastInset
        cleanInsets.left = 20.0
        cleanInsets.right = 20.0
        
        fullInsets.top += 44.0 + 8.0
        fullInsets.bottom = buttonsHeight + 22.0 + toastInset
        fullInsets.left = 20.0
        fullInsets.right = 20.0
        
        var insets: UIEdgeInsets = self.isUIHidden ? cleanInsets : fullInsets
        
        let expandedInset: CGFloat = 16.0
        
        insets.top = interpolate(from: expandedInset, to: insets.top, value: 1.0 - self.pictureInPictureTransitionFraction)
        insets.bottom = interpolate(from: expandedInset, to: insets.bottom, value: 1.0 - self.pictureInPictureTransitionFraction)
        insets.left = interpolate(from: expandedInset, to: insets.left, value: 1.0 - self.pictureInPictureTransitionFraction)
        insets.right = interpolate(from: expandedInset, to: insets.right, value: 1.0 - self.pictureInPictureTransitionFraction)
        
//        let previewVideoSide = interpolate(from: 300.0, to: 150.0, value: 1.0 - self.pictureInPictureTransitionFraction)
        let previewVideoSide = interpolate(from: 300.0, to: self.isUIHidden ? 140.0 : 240.0, value: 1.0 - self.pictureInPictureTransitionFraction)
        var previewVideoSize = layout.size.aspectFitted(CGSize(width: previewVideoSide, height: previewVideoSide))
//        previewVideoSize = CGSize(width: 30.0, height: 45.0).aspectFitted(previewVideoSize)
        previewVideoSize = CGSize(width: 138.0, height: 240.0).aspectFitted(previewVideoSize)
        if let minimizedVideoNode = self.minimizedVideoNode {
            var aspect = minimizedVideoNode.currentAspect
            var rotationCount = 0
            if minimizedVideoNode === self.outgoingVideoNodeValue {
//                aspect = 3.0 / 4.0
                aspect = 138.0 / 240.0
            } else {
                if aspect < 1.0 {
//                    aspect = 3.0 / 4.0
                    aspect = 138.0 / 240.0
                } else {
//                    aspect = 4.0 / 3.0
                    aspect = 240.0 / 138.0
                }
                
                switch minimizedVideoNode.currentOrientation {
                case .rotation90, .rotation270:
                    rotationCount += 1
                default:
                    break
                }
                
                var mappedDeviceOrientation = self.deviceOrientation
                if case .regular = layout.metrics.widthClass, case .regular = layout.metrics.heightClass {
                    mappedDeviceOrientation = .portrait
                }
                
                switch mappedDeviceOrientation {
                case .landscapeLeft, .landscapeRight:
                    rotationCount += 1
                default:
                    break
                }
                
                if rotationCount % 2 != 0 {
                    aspect = 1.0 / aspect
                }
            }
            
            let unboundVideoSize = CGSize(width: aspect * 10000.0, height: 10000.0)
            
            previewVideoSize = unboundVideoSize.aspectFitted(CGSize(width: previewVideoSide, height: previewVideoSide))
        }
        let previewVideoY: CGFloat
        let previewVideoX: CGFloat
        
        switch self.outgoingVideoNodeCorner {
        case .topLeft:
            previewVideoX = insets.left
            previewVideoY = insets.top
        case .topRight:
            previewVideoX = layout.size.width - previewVideoSize.width - insets.right
            previewVideoY = insets.top
        case .bottomLeft:
            previewVideoX = insets.left
            previewVideoY = layout.size.height - insets.bottom - previewVideoSize.height
        case .bottomRight:
            previewVideoX = layout.size.width - previewVideoSize.width - insets.right
            previewVideoY = layout.size.height - insets.bottom - previewVideoSize.height
        }
        
        return CGRect(origin: CGPoint(x: previewVideoX, y: previewVideoY), size: previewVideoSize)
    }
    
    private func calculatePictureInPictureContainerRect(layout: ContainerViewLayout, navigationHeight: CGFloat) -> CGRect {
        let pictureInPictureTopInset: CGFloat = layout.insets(options: .statusBar).top + 44.0 + 8.0
        let pictureInPictureSideInset: CGFloat = 8.0
        let pictureInPictureSize = layout.size.fitted(CGSize(width: 240.0, height: 240.0))
        let pictureInPictureBottomInset: CGFloat = layout.insets(options: .input).bottom + 44.0 + 8.0
        
        let containerPictureInPictureFrame: CGRect
        switch self.pictureInPictureCorner {
        case .topLeft:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: pictureInPictureSideInset, y: pictureInPictureTopInset), size: pictureInPictureSize)
        case .topRight:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: layout.size.width -  pictureInPictureSideInset - pictureInPictureSize.width, y: pictureInPictureTopInset), size: pictureInPictureSize)
        case .bottomLeft:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: pictureInPictureSideInset, y: layout.size.height - pictureInPictureBottomInset - pictureInPictureSize.height), size: pictureInPictureSize)
        case .bottomRight:
            containerPictureInPictureFrame = CGRect(origin: CGPoint(x: layout.size.width -  pictureInPictureSideInset - pictureInPictureSize.width, y: layout.size.height - pictureInPictureBottomInset - pictureInPictureSize.height), size: pictureInPictureSize)
        }
        return containerPictureInPictureFrame
    }
    
    var animateBackButtonNodeAppearOnce = true
    var animateKeyButtonNodeAppearOnce = true
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationBarHeight)
        
        var mappedDeviceOrientation = self.deviceOrientation
        var isCompactLayout = true
        if case .regular = layout.metrics.widthClass, case .regular = layout.metrics.heightClass {
            mappedDeviceOrientation = .portrait
            isCompactLayout = false
        }
        
        if !self.hasVideoNodes {
            self.isUIHidden = false
        }
        
        var isUIHidden = self.isUIHidden
        switch self.callState?.state {
        case .terminated, .terminating:
            isUIHidden = false
        default:
            break
        }
        
        var uiDisplayTransition: CGFloat = isUIHidden ? 0.0 : 1.0
        let pipTransitionAlpha: CGFloat = 1.0 - self.pictureInPictureTransitionFraction
        uiDisplayTransition *= pipTransitionAlpha
        
        let pinchTransitionAlpha: CGFloat = self.isVideoPinched ? 0.0 : 1.0
        
//        let previousVideoButtonFrame = self.buttonsNode.videoButtonFrame().flatMap { frame -> CGRect in
//            return self.buttonsNode.view.convert(frame, to: self.view)
//        }
        
        let buttonsHeight: CGFloat
        if let buttonsMode = self.buttonsMode {
            buttonsHeight = self.buttonsNode.updateLayout(strings: self.presentationData.strings, mode: buttonsMode, constrainedWidth: layout.size.width, bottomInset: layout.intrinsicInsets.bottom, transition: transition)
        } else {
            buttonsHeight = 0.0
        }
        let defaultButtonsOriginY = layout.size.height - buttonsHeight
        let buttonsCollapsedOriginY = self.pictureInPictureTransitionFraction > 0.0 ? layout.size.height + 30.0 : layout.size.height + 10.0
        let buttonsOriginY = interpolate(from: buttonsCollapsedOriginY, to: defaultButtonsOriginY, value: uiDisplayTransition)
        
        let toastHeight = self.toastNode.updateLayout(strings: self.presentationData.strings, content: self.toastContent, constrainedWidth: layout.size.width, bottomInset: layout.intrinsicInsets.bottom + buttonsHeight, transition: transition)
        
        let toastSpacing: CGFloat = 22.0
        let toastCollapsedOriginY = self.pictureInPictureTransitionFraction > 0.0 ? layout.size.height : layout.size.height - max(layout.intrinsicInsets.bottom, 20.0) - toastHeight
        let toastOriginY = interpolate(from: toastCollapsedOriginY, to: defaultButtonsOriginY - toastSpacing - toastHeight, value: uiDisplayTransition)
        
        let overlayAlpha: CGFloat = min(pinchTransitionAlpha, uiDisplayTransition)
        let toastAlpha: CGFloat = min(pinchTransitionAlpha, pipTransitionAlpha)
        
//        switch self.callState?.state {
//        case .terminated, .terminating:
//            overlayAlpha *= 0.5
//            toastAlpha *= 0.5
//        default:
//            break
//        }
        
        let containerFullScreenFrame = CGRect(origin: CGPoint(), size: layout.size)
        let containerPictureInPictureFrame = self.calculatePictureInPictureContainerRect(layout: layout, navigationHeight: navigationBarHeight)
        
        let containerFrame = interpolateFrame(from: containerFullScreenFrame, to: containerPictureInPictureFrame, t: self.pictureInPictureTransitionFraction)
        
        transition.updateFrame(node: self.containerTransformationNode, frame: containerFrame)
        transition.updateSublayerTransformScale(node: self.containerTransformationNode, scale: min(1.0, containerFrame.width / layout.size.width * 1.01))
        transition.updateCornerRadius(layer: self.containerTransformationNode.layer, cornerRadius: self.pictureInPictureTransitionFraction * 10.0)
        
        transition.updateFrame(node: self.containerNode, frame: CGRect(origin: CGPoint(x: (containerFrame.width - layout.size.width) / 2.0, y: floor(containerFrame.height - layout.size.height) / 2.0), size: layout.size))
        transition.updateFrame(node: self.videoContainerNode, frame: containerFullScreenFrame)
        self.videoContainerNode.update(size: containerFullScreenFrame.size, transition: transition)
        
        transition.updateAlpha(node: self.dimNode, alpha: pinchTransitionAlpha)
        transition.updateFrame(node: self.dimNode, frame: containerFullScreenFrame)
        
        let imageNodeSize = CGSize(width: 136.0, height: 136.0)
        let imageNodeOffset = containerFullScreenFrame.height / 2.0 - imageNodeSize.height / 2.0 - 136.0
        let imageNodeFrame = CGRect(x: containerFullScreenFrame.width / 2 - imageNodeSize.width / 2, y: imageNodeOffset, width: imageNodeSize.width, height: imageNodeSize.height)
        transition.updateFrame(node: self.imageNode, frame: imageNodeFrame)
        let arguments = TransformImageArguments(corners: ImageCorners(radius: 68.0), imageSize: CGSize(width: 136, height: 136).aspectFilled(imageNodeSize), boundingSize: imageNodeSize, intrinsicInsets: UIEdgeInsets())
        let apply = self.imageNode.asyncLayout()(arguments)
        apply()
        
        let voiceBlobNodeSize = CGSize(width: 222.0, height: 222.0)
        let voiceBlobNodeOffset = containerFullScreenFrame.height / 2.0 - voiceBlobNodeSize.height / 2.0 - 136.0
        let voiceBlobNodeFrame = CGRect(x: containerFullScreenFrame.width / 2 - voiceBlobNodeSize.width / 2, y: voiceBlobNodeOffset, width: voiceBlobNodeSize.width, height: voiceBlobNodeSize.height)
        transition.updateFrame(node: self.voiceBlobNode, frame: voiceBlobNodeFrame)
        
        if self.keyPreviewNode == nil {
            transition.updateTransformScale(node: self.imageNode, scale: 1.0)
            transition.updateAlpha(node: self.imageNode, alpha: 1.0)
            transition.updateTransformScale(node: self.voiceBlobNode, scale: 1.0)
            transition.updateAlpha(node: self.voiceBlobNode, alpha: 1.0)
        } else {
            transition.updateTransformScale(node: self.imageNode, scale: 0.1)
            transition.updateAlpha(node: self.imageNode, alpha: 0.0)
            transition.updateTransformScale(node: self.voiceBlobNode, scale: 0.1)
            transition.updateAlpha(node: self.voiceBlobNode, alpha: 0.0)
        }
        
        transition.updateFrame(node: self.gradientBackgroundNode, frame: containerFullScreenFrame)
        self.gradientBackgroundNode.updateLayout(size: containerFullScreenFrame.size, transition: transition, extendAnimation: false, backwards: false, completion: { })
        defer {
            if self.shouldActivateGradientBackroundNodeAnimationLoop {
                self.shouldActivateGradientBackroundNodeAnimationLoop = false
                self.activateGradientBackgroundNodeAnimationLoop()
            }
        }
        
        let navigationOffset: CGFloat = max(20.0, layout.safeInsets.top)
        let topOriginY = interpolate(from: -20.0, to: navigationOffset, value: uiDisplayTransition)
        
        if self.keyTextData != nil {
            var backButtonTransition = transition
            if self.animateBackButtonNodeAppearOnce {
                backButtonTransition = .immediate
            }
            
            let backSize = self.backButtonNode.measure(CGSize(width: 320.0, height: 100.0))
            if let image = self.backButtonArrowNode.image {
                backButtonTransition.updateFrame(node: self.backButtonArrowNode, frame: CGRect(origin: CGPoint(x: 10.0, y: topOriginY + 11.0), size: image.size))
                backButtonTransition.updateAlpha(node: self.backButtonArrowNode, alpha: overlayAlpha)
            }
            backButtonTransition.updateFrame(node: self.backButtonNode, frame: CGRect(origin: CGPoint(x: 29.0, y: topOriginY + 11.0), size: backSize))
            backButtonTransition.updateAlpha(node: self.backButtonNode, alpha: overlayAlpha)
            
            if self.animateBackButtonNodeAppearOnce {
                self.animateBackButtonNodeAppearOnce = false
                self.backButtonNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
                self.backButtonNode.layer.animatePosition(from: self.backButtonNode.layer.position.offsetBy(dx: 20.0, dy: 0.0), to: self.backButtonNode.layer.position, duration: 0.4, force: true)
                self.backButtonArrowNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
                self.backButtonArrowNode.layer.animatePosition(from: self.backButtonArrowNode.layer.position.offsetBy(dx: 15.0, dy: 0.0), to: self.backButtonArrowNode.layer.position, duration: 0.4, force: true)
            }
        }
        
        transition.updateAlpha(node: self.toastNode, alpha: toastAlpha)
        
        if let keyPreviewNode = self.keyPreviewNode {
//            let keyPreviewNodeHeight = keyPreviewNode.updateLayout(size: layout.size, transition: .immediate)
//            let keyPreviewNodeSize = CGSize(width: 304.0, height: keyPreviewNodeHeight)
            let keyPreviewNodeSize = CGSize(width: 304.0, height: 225.0)
            let keyPreviewNodeFrame = CGRect(x: (layout.size.width - keyPreviewNodeSize.width) / 2.0, y: 132.0, width: keyPreviewNodeSize.width, height: keyPreviewNodeSize.height)
            _ = keyPreviewNode.updateLayout(size: keyPreviewNodeSize, transition: .immediate)
            transition.updateFrame(node: keyPreviewNode, frame: keyPreviewNodeFrame)
        }
        
//        var statusOffset: CGFloat
//        if layout.metrics.widthClass == .regular && layout.metrics.heightClass == .regular {
//            if layout.size.height.isEqual(to: 1366.0) {
//                statusOffset = 160.0
//            } else {
//                statusOffset = 120.0
//            }
//        } else {
//            if layout.size.height.isEqual(to: 736.0) {
//                statusOffset = 80.0
//            } else if layout.size.width.isEqual(to: 320.0) {
//                statusOffset = 60.0
//            } else {
//                statusOffset = 64.0
//            }
//        }
//
//        statusOffset += layout.safeInsets.top
        
        let statusWidth = self.expandedVideoNode == nil ? layout.size.width : layout.size.width - (self.keyButtonNode.measure(.zero).width + 10.0) * 2.0 //max(self.backButtonNode.frame.maxX, layout.size.width - self.keyButtonNode.frame.minX) * 2.0
        let statusHeight = self.statusNode.updateLayout(constrainedWidth: statusWidth, transition: transition)
        let statusOffset: CGFloat
        if self.expandedVideoNode == nil {
            statusOffset = containerFullScreenFrame.midY - statusHeight / 2.0
        } else {
            statusOffset = layout.safeInsets.top - 11.0 //navigationBarHeight / 2.0
        }
        transition.updateFrameAdditiveToCenter(node: self.statusNode, frame: CGRect(origin: CGPoint(x: (layout.size.width - statusWidth) / 2.0, y: statusOffset), size: CGSize(width: statusWidth, height: statusHeight)))
        transition.updateAlpha(node: self.statusNode, alpha: overlayAlpha)
        
        transition.updateFrame(node: self.toastNode, frame: CGRect(origin: CGPoint(x: 0.0, y: toastOriginY), size: CGSize(width: layout.size.width, height: toastHeight)))
        transition.updateFrame(node: self.buttonsNode, frame: CGRect(origin: CGPoint(x: 0.0, y: buttonsOriginY), size: CGSize(width: layout.size.width, height: buttonsHeight)))
        transition.updateAlpha(node: self.buttonsNode, alpha: overlayAlpha)
        
        let fullscreenVideoFrame = containerFullScreenFrame
        let previewVideoFrame = self.calculatePreviewVideoRect(layout: layout, navigationHeight: navigationBarHeight)
        
        if let removedMinimizedVideoNodeValue = self.removedMinimizedVideoNodeValue {
            self.removedMinimizedVideoNodeValue = nil
            
            if transition.isAnimated {
                removedMinimizedVideoNodeValue.layer.animateScale(from: 1.0, to: 0.1, duration: 0.3, removeOnCompletion: false)
                removedMinimizedVideoNodeValue.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak removedMinimizedVideoNodeValue] _ in
                    removedMinimizedVideoNodeValue?.removeFromSupernode()
                })
            } else {
                removedMinimizedVideoNodeValue.removeFromSupernode()
            }
        }
        
        if let expandedVideoNode = self.expandedVideoNode {
            transition.updateAlpha(node: expandedVideoNode, alpha: 1.0)
            var expandedVideoTransition = transition
            if expandedVideoNode.frame.isEmpty || self.disableAnimationForExpandedVideoOnce {
                expandedVideoTransition = .immediate
                self.disableAnimationForExpandedVideoOnce = false
            }
            
            if expandedVideoNode.frame.isEmpty && expandedVideoNode == self.incomingVideoNodeValue && self.minimizedVideoNode == nil {
                let fromPath = UIBezierPath(roundedRect: self.imageNode.frame, cornerRadius: self.imageNode.frame.height / 2.0)
                let toPath = UIBezierPath(roundedRect: fullscreenVideoFrame, cornerRadius: 20.0)
                
                if let transitionView = self.imageNode.view.snapshotView(afterScreenUpdates: false), let supernode = expandedVideoNode.supernode {
                    let maskLayer = CAShapeLayer()
                    maskLayer.frame = fullscreenVideoFrame
                    maskLayer.path = toPath.cgPath
                    
                    let transitionNode = ASDisplayNode()
                    transitionNode.frame = fullscreenVideoFrame
                    transitionNode.view.addSubview(transitionView)
                    transitionNode.layer.mask = maskLayer
                    
                    supernode.insertSubnode(transitionNode, belowSubnode: expandedVideoNode)
                    
                    transitionView.frame = self.imageNode.frame
                    transitionView.layer.animateScale(from: 1.0, to: 1.5, duration: 0.3, removeOnCompletion: false)
                    maskLayer.animate(from: fromPath.cgPath, to: toPath.cgPath, keyPath: "path", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.3, removeOnCompletion: false, completion: { _ in
                        transitionNode.removeFromSupernode()
                    })
                }
                
                let maskLayer = CAShapeLayer()
                maskLayer.frame = fullscreenVideoFrame
                maskLayer.path = toPath.cgPath
                
                expandedVideoNode.frame = fullscreenVideoFrame
                expandedVideoNode.layer.mask = maskLayer
                expandedVideoNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)
//                maskLayer.animateSpring(from: fromPath.cgPath, to: toPath.cgPath, keyPath: "path", duration: 0.5, removeOnCompletion: false) { [weak expandedVideoNode] _ in
//                    expandedVideoNode?.layer.mask = nil
//                }
                maskLayer.animate(from: fromPath.cgPath, to: toPath.cgPath, keyPath: "path", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.3, removeOnCompletion: false, completion: { [weak expandedVideoNode] _ in
                    expandedVideoNode?.layer.mask = nil
                })
            }
            
            if let removedExpandedVideoNodeValue = self.removedExpandedVideoNodeValue {
                self.removedExpandedVideoNodeValue = nil
                
                expandedVideoTransition.updateFrame(node: expandedVideoNode, frame: fullscreenVideoFrame, completion: { [weak removedExpandedVideoNodeValue] _ in
                    removedExpandedVideoNodeValue?.removeFromSupernode()
                })
            } else {
                expandedVideoTransition.updateFrame(node: expandedVideoNode, frame: fullscreenVideoFrame)
            }
            
            expandedVideoTransition.updateAlpha(node: expandedVideoNode, alpha: 1.0)
            expandedVideoNode.updateLayout(size: expandedVideoNode.frame.size, cornerRadius: 0.0, isOutgoing: expandedVideoNode === self.outgoingVideoNodeValue, deviceOrientation: mappedDeviceOrientation, isCompactLayout: isCompactLayout, transition: expandedVideoTransition)
            
            if self.animateRequestedVideoOnce {
                self.animateRequestedVideoOnce = false
                if expandedVideoNode === self.outgoingVideoNodeValue {
//                    let videoButtonFrame = self.buttonsNode.videoButtonFrame().flatMap { frame -> CGRect in
//                        return self.buttonsNode.view.convert(frame, to: self.view)
//                    }
//
//                    if let previousVideoButtonFrame = previousVideoButtonFrame, let videoButtonFrame = videoButtonFrame {
//                        expandedVideoNode.animateRadialMask(from: previousVideoButtonFrame, to: videoButtonFrame)
//                    }
                }
            }
        } else {
            if let removedExpandedVideoNodeValue = self.removedExpandedVideoNodeValue {
                self.removedExpandedVideoNodeValue = nil
                
                if transition.isAnimated {
                    let fromPath = UIBezierPath(roundedRect: fullscreenVideoFrame, cornerRadius: 20.0)
                    let toPath = UIBezierPath(roundedRect: self.imageNode.frame, cornerRadius: self.imageNode.frame.height / 2.0)
                    
                    if let transitionView = self.imageNode.view.snapshotView(afterScreenUpdates: false), let supernode = removedExpandedVideoNodeValue.supernode {
                        let maskLayer = CAShapeLayer()
                        maskLayer.frame = fullscreenVideoFrame
                        maskLayer.path = toPath.cgPath
                        
                        let transitionNode = ASDisplayNode()
                        transitionNode.frame = fullscreenVideoFrame
                        transitionNode.view.addSubview(transitionView)
                        transitionNode.layer.mask = maskLayer
                        
                        supernode.insertSubnode(transitionNode, belowSubnode: removedExpandedVideoNodeValue)
                        
                        transitionView.frame = self.imageNode.frame
                        transitionView.layer.animateScale(from: 1.5, to: 1.0, duration: 0.3, removeOnCompletion: false)
                        maskLayer.animate(from: fromPath.cgPath, to: toPath.cgPath, keyPath: "path", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.3, removeOnCompletion: false, completion: { _ in
                            transitionNode.removeFromSupernode()
                        })
                    }
                    
                    let maskLayer = CAShapeLayer()
                    maskLayer.frame = fullscreenVideoFrame
                    maskLayer.path = toPath.cgPath
                    
                    removedExpandedVideoNodeValue.frame = fullscreenVideoFrame
                    removedExpandedVideoNodeValue.layer.mask = maskLayer
                    removedExpandedVideoNodeValue.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
//                    maskLayer.animateSpring(from: fromPath.cgPath, to: toPath.cgPath, keyPath: "path", duration: 0.6, removeOnCompletion: false) {  [weak removedExpandedVideoNodeValue] _ in
//                        removedExpandedVideoNodeValue?.removeFromSupernode()
//                    }
                    maskLayer.animate(from: fromPath.cgPath, to: toPath.cgPath, keyPath: "path", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.3, removeOnCompletion: false, completion: { [weak removedExpandedVideoNodeValue] _ in
                        removedExpandedVideoNodeValue?.removeFromSupernode()
                    })
                } else {
                    removedExpandedVideoNodeValue.removeFromSupernode()
                }
            }
        }
        
        
        if let minimizedVideoNode = self.minimizedVideoNode {
            transition.updateAlpha(node: minimizedVideoNode, alpha: min(pipTransitionAlpha, pinchTransitionAlpha))
            var minimizedVideoTransition = transition
            var didAppear = false
            if minimizedVideoNode.frame.isEmpty {
                minimizedVideoTransition = .immediate
                didAppear = true
            }
            if self.minimizedVideoDraggingPosition == nil {
                if self.animationForExpandedVideoSnapshotView != nil || self.animationForMinimazedVideoSnapshotView != nil {
                    minimizedVideoTransition = .immediate
                }
                
                if let animationForExpandedVideoSnapshotView = self.animationForExpandedVideoSnapshotView {
                    self.animationForExpandedVideoSnapshotView = nil
                    self.containerNode.view.insertSubview(animationForExpandedVideoSnapshotView, belowSubview: self.buttonsNode.view)
                    animationForExpandedVideoSnapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak animationForExpandedVideoSnapshotView] _ in
                        animationForExpandedVideoSnapshotView?.removeFromSuperview()
                    })
                }
                
                if let animationForMinimazedVideoSnapshotView = self.animationForMinimazedVideoSnapshotView {
                    self.animationForMinimazedVideoSnapshotView = nil
                    self.containerNode.view.insertSubview(animationForMinimazedVideoSnapshotView, belowSubview: self.buttonsNode.view)
                    minimizedVideoNode.layer.animateKeyframes(values: [NSNumber(1.0), NSNumber(0.9), NSNumber(1.0)], duration: 0.6, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
                    animationForMinimazedVideoSnapshotView.layer.animateKeyframes(values: [NSNumber(1.0), NSNumber(0.9), NSNumber(1.0)], duration: 0.6, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
                    animationForMinimazedVideoSnapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak animationForMinimazedVideoSnapshotView] _ in
                        animationForMinimazedVideoSnapshotView?.removeFromSuperview()
                    })
                }
                
                minimizedVideoTransition.updateFrame(node: minimizedVideoNode, frame: previewVideoFrame)
                minimizedVideoNode.updateLayout(size: previewVideoFrame.size, cornerRadius: interpolate(from: 14.0, to: 24.0, value: self.pictureInPictureTransitionFraction), isOutgoing: minimizedVideoNode === self.outgoingVideoNodeValue, deviceOrientation: mappedDeviceOrientation, isCompactLayout: layout.metrics.widthClass == .compact, transition: minimizedVideoTransition)
                if transition.isAnimated && didAppear {
                    minimizedVideoNode.layer.animateSpring(from: 0.1 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5)
                }
            }
            
            self.animationForExpandedVideoSnapshotView = nil
        }
        
//        if let keyPreviewNode = self.keyPreviewNode {
//            transition.updateFrame(node: self.keyButtonNode, frame: CGRect(origin: keyPreviewNode.convert(keyPreviewNode.keyTextNode.frame.origin, to: self), size: keyPreviewNode.keyTextNode.bounds.size))
//        } else {
        if self.keyPreviewNode == nil {
            let keyTextSize = self.keyButtonNode.frame.size
            transition.updateFrame(node: self.keyButtonNode, frame: CGRect(origin: CGPoint(x: layout.size.width - keyTextSize.width - 10.0, y: topOriginY + 5.0), size: keyTextSize))
        }
        transition.updateAlpha(node: self.keyButtonNode, alpha: overlayAlpha)

        if let keyTooltipNode = self.keyTooltipNode {
            if keyTooltipNode.frame == .zero {
                let keyTooltipSize = CGSize(width: 223.0, height: 38.0 + 8.0)
                keyTooltipNode.frame = CGRect(x: layout.size.width - keyTooltipSize.width - 15.0, y: self.keyButtonNode.frame.maxY + 6.0, width: keyTooltipSize.width, height: keyTooltipSize.height)
                keyTooltipNode.layer.animatePosition(from: self.keyButtonNode.layer.position.offsetBy(dx: -20.0, dy: 20.0), to: keyTooltipNode.layer.position, duration: 0.3)
                keyTooltipNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
                keyTooltipNode.layer.animateScale(from: 0.3, to: 1.0, duration: 0.3)
            }
        }
        
        if let debugNode = self.debugNode {
            transition.updateFrame(node: debugNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        }
        
        let requestedAspect: CGFloat
        if case .compact = layout.metrics.widthClass, case .compact = layout.metrics.heightClass {
            var isIncomingVideoRotated = false
            var rotationCount = 0
            
            switch mappedDeviceOrientation {
            case .portrait:
                break
            case .landscapeLeft:
                rotationCount += 1
            case .landscapeRight:
                rotationCount += 1
            case .portraitUpsideDown:
                 break
            default:
                break
            }
            
            if rotationCount % 2 != 0 {
                isIncomingVideoRotated = true
            }
            
            if !isIncomingVideoRotated {
                requestedAspect = layout.size.width / layout.size.height
            } else {
                requestedAspect = 0.0
            }
        } else {
            requestedAspect = 0.0
        }
        if self.currentRequestedAspect != requestedAspect {
            self.currentRequestedAspect = requestedAspect
            if !self.sharedContext.immediateExperimentalUISettings.disableVideoAspectScaling {
                self.call.setRequestedVideoAspect(Float(requestedAspect))
            }
        }
    }
    
    var keyPreviewFromToRect: CGRect = .zero
    
    @objc func keyPressed() {
        if self.keyPreviewNode == nil, let keyText = self.keyTextData?.1, let peer = self.peer {
            self.dismissKeyTooltipNode()
            let keyPreviewNode = CallControllerKeyPreviewNode(keyText: keyText, infoText: self.presentationData.strings.Call_EmojiDescription(EnginePeer(peer).compactDisplayTitle).string.replacingOccurrences(of: "%%", with: "%"), hasVideo: self.expandedVideoNode != nil, dismiss: { [weak self] in
                if let _ = self?.keyPreviewNode {
                    self?.backPressed()
                }
            })
            
            self.containerNode.insertSubnode(keyPreviewNode, belowSubnode: self.statusNode)
            self.keyPreviewNode = keyPreviewNode
            self.updateDimVisibility()
            if let (validLayout, navigationHeight) = self.validLayout {
                let keyPreviewNodeSize = CGSize(width: 304.0, height: 225.0)
                self.containerLayoutUpdated(validLayout, navigationBarHeight: navigationHeight, transition: .immediate)
                _ = keyPreviewNode.updateLayout(size: keyPreviewNodeSize, transition: .immediate)
                
                self.keyPreviewFromToRect = self.keyButtonNode.frame
                self.keyButtonNode.animateExpand(to: CGRect(origin: keyPreviewNode.convert(keyPreviewNode.keyTextNode.frame.origin, to: self), size: keyPreviewNode.keyTextNode.bounds.size))
                keyPreviewNode.animateIn(from: self.keyPreviewFromToRect, fromNode: self.keyButtonNode)
            }
        } else if self.keyPreviewNode != nil {
            self.backPressed()
        }
    }
    
    @objc func backPressed() {
        if let keyPreviewNode = self.keyPreviewNode {
            self.keyPreviewNode = nil
            self.updateDimVisibility()
            self.keyButtonNode.animateCollapse(to: self.keyPreviewFromToRect)
            keyPreviewNode.animateOut(to: self.keyPreviewFromToRect, toNode: self.keyButtonNode, completion: { [weak keyPreviewNode] in
//                self?.keyButtonNode.isHidden = false
                keyPreviewNode?.removeFromSupernode()
            })
//            if let (validLayout, navigationHeight) = self.validLayout {
//                self.containerLayoutUpdated(validLayout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
//            }
        } else if self.hasVideoNodes {
            if let (layout, navigationHeight) = self.validLayout {
                self.pictureInPictureTransitionFraction = 1.0
                self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
            }
        } else {
            self.back?()
        }
    }
    
    private var hasVideoNodes: Bool {
        return self.expandedVideoNode != nil || self.minimizedVideoNode != nil
    }
    
    private var debugTapCounter: (Double, Int) = (0.0, 0)
    
    private func areUserActionsDisabledNow() -> Bool {
        return CACurrentMediaTime() < self.disableActionsUntilTimestamp
    }
    
    @objc func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            if !self.pictureInPictureTransitionFraction.isZero {
                self.view.window?.endEditing(true)
                
                if let (layout, navigationHeight) = self.validLayout {
                    self.pictureInPictureTransitionFraction = 0.0
                    
                    self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
                }
            } else if let _ = self.keyPreviewNode {
                self.backPressed()
            } else {
                if self.hasVideoNodes {
                    let point = recognizer.location(in: recognizer.view)
                    if let expandedVideoNode = self.expandedVideoNode, let minimizedVideoNode = self.minimizedVideoNode, minimizedVideoNode.frame.contains(point) {
                        if !self.areUserActionsDisabledNow() {
                            let animationForExpandedVideoSnapshotView = expandedVideoNode.view.snapshotView(afterScreenUpdates: false)
                            animationForExpandedVideoSnapshotView?.frame = expandedVideoNode.frame
                            
                            let animationForMinimazedVideoSnapshotView = minimizedVideoNode.view.snapshotView(afterScreenUpdates: false)
                            animationForMinimazedVideoSnapshotView?.frame = minimizedVideoNode.frame
                            
                            self.expandedVideoNode = minimizedVideoNode
                            self.minimizedVideoNode = expandedVideoNode
                            if let supernode = expandedVideoNode.supernode {
                                supernode.insertSubnode(expandedVideoNode, aboveSubnode: minimizedVideoNode)
                            }
                            self.disableActionsUntilTimestamp = CACurrentMediaTime() + 0.3
                            if let (layout, navigationBarHeight) = self.validLayout {
                                self.disableAnimationForExpandedVideoOnce = true
                                self.animationForExpandedVideoSnapshotView = animationForExpandedVideoSnapshotView
                                self.animationForMinimazedVideoSnapshotView = animationForMinimazedVideoSnapshotView
                                self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                            }
                        }
                    } else {
                        var updated = false
                        if let callState = self.callState {
                            switch callState.state {
                            case .active, .connecting, .reconnecting:
                                self.isUIHidden = !self.isUIHidden
                                updated = true
                            default:
                                break
                            }
                        }
                        if updated, let (layout, navigationBarHeight) = self.validLayout {
                            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .animated(duration: 0.3, curve: .easeInOut))
                        }
                    }
                } else {
                    let point = recognizer.location(in: recognizer.view)
                    if self.statusNode.frame.contains(point) {
                        if self.easyDebugAccess {
                            self.presentDebugNode()
                        } else {
                            let timestamp = CACurrentMediaTime()
                            if self.debugTapCounter.0 < timestamp - 0.75 {
                                self.debugTapCounter.0 = timestamp
                                self.debugTapCounter.1 = 0
                            }
                            
                            if self.debugTapCounter.0 >= timestamp - 0.75 {
                                self.debugTapCounter.0 = timestamp
                                self.debugTapCounter.1 += 1
                            }
                            
                            if self.debugTapCounter.1 >= 10 {
                                self.debugTapCounter.1 = 0
                                
                                self.presentDebugNode()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func presentDebugNode() {
        guard self.debugNode == nil else {
            return
        }
        
        self.forceReportRating = true
        
        let debugNode = CallDebugNode(signal: self.debugInfo)
        debugNode.dismiss = { [weak self] in
            if let strongSelf = self {
                strongSelf.debugNode?.removeFromSupernode()
                strongSelf.debugNode = nil
            }
        }
        self.addSubnode(debugNode)
        self.debugNode = debugNode
        
        if let (layout, navigationBarHeight) = self.validLayout {
            self.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: .immediate)
        }
    }
    
    private var minimizedVideoInitialPosition: CGPoint?
    private var minimizedVideoDraggingPosition: CGPoint?
    
    private func nodeLocationForPosition(layout: ContainerViewLayout, position: CGPoint, velocity: CGPoint) -> VideoNodeCorner {
        let layoutInsets = UIEdgeInsets()
        var result = CGPoint()
        if position.x < layout.size.width / 2.0 {
            result.x = 0.0
        } else {
            result.x = 1.0
        }
        if position.y < layoutInsets.top + (layout.size.height - layoutInsets.bottom - layoutInsets.top) / 2.0 {
            result.y = 0.0
        } else {
            result.y = 1.0
        }
        
        let currentPosition = result
        
        let angleEpsilon: CGFloat = 30.0
        var shouldHide = false
        
        if (velocity.x * velocity.x + velocity.y * velocity.y) >= 500.0 * 500.0 {
            let x = velocity.x
            let y = velocity.y
            
            var angle = atan2(y, x) * 180.0 / CGFloat.pi * -1.0
            if angle < 0.0 {
                angle += 360.0
            }
            
            if currentPosition.x.isZero && currentPosition.y.isZero {
                if ((angle > 0 && angle < 90 - angleEpsilon) || angle > 360 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 0.0
                } else if (angle > 180 + angleEpsilon && angle < 270 + angleEpsilon) {
                    result.x = 0.0
                    result.y = 1.0
                } else if (angle > 270 + angleEpsilon && angle < 360 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 1.0
                } else {
                    shouldHide = true
                }
            } else if !currentPosition.x.isZero && currentPosition.y.isZero {
                if (angle > 90 + angleEpsilon && angle < 180 + angleEpsilon) {
                    result.x = 0.0
                    result.y = 0.0
                }
                else if (angle > 270 - angleEpsilon && angle < 360 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 1.0
                }
                else if (angle > 180 + angleEpsilon && angle < 270 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 1.0
                }
                else {
                    shouldHide = true
                }
            } else if currentPosition.x.isZero && !currentPosition.y.isZero {
                if (angle > 90 - angleEpsilon && angle < 180 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 0.0
                }
                else if (angle < angleEpsilon || angle > 270 + angleEpsilon) {
                    result.x = 1.0
                    result.y = 1.0
                }
                else if (angle > angleEpsilon && angle < 90 - angleEpsilon) {
                    result.x = 1.0
                    result.y = 0.0
                }
                else if (!shouldHide) {
                    shouldHide = true
                }
            } else if !currentPosition.x.isZero && !currentPosition.y.isZero {
                if (angle > angleEpsilon && angle < 90 + angleEpsilon) {
                    result.x = 1.0
                    result.y = 0.0
                }
                else if (angle > 180 - angleEpsilon && angle < 270 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 1.0
                }
                else if (angle > 90 + angleEpsilon && angle < 180 - angleEpsilon) {
                    result.x = 0.0
                    result.y = 0.0
                }
                else if (!shouldHide) {
                    shouldHide = true
                }
            }
        }
        
        if result.x.isZero {
            if result.y.isZero {
                return .topLeft
            } else {
                return .bottomLeft
            }
        } else {
            if result.y.isZero {
                return .topRight
            } else {
                return .bottomRight
            }
        }
    }
    
    @objc private func panGesture(_ recognizer: CallPanGestureRecognizer) {
        switch recognizer.state {
            case .began:
                guard let location = recognizer.firstLocation else {
                    return
                }
                if self.pictureInPictureTransitionFraction.isZero, let expandedVideoNode = self.expandedVideoNode, let minimizedVideoNode = self.minimizedVideoNode, minimizedVideoNode.frame.contains(location), expandedVideoNode.frame != minimizedVideoNode.frame {
                    self.minimizedVideoInitialPosition = minimizedVideoNode.position
                } else if self.hasVideoNodes {
                    self.minimizedVideoInitialPosition = nil
                    if !self.pictureInPictureTransitionFraction.isZero {
                        self.pictureInPictureGestureState = .dragging(initialPosition: self.containerTransformationNode.position, draggingPosition: self.containerTransformationNode.position)
                    } else {
                        self.pictureInPictureGestureState = .collapsing(didSelectCorner: false)
                    }
                } else {
                    self.pictureInPictureGestureState = .none
                }
                self.dismissAllTooltips?()
            case .changed:
                if let minimizedVideoNode = self.minimizedVideoNode, let minimizedVideoInitialPosition = self.minimizedVideoInitialPosition {
                    let translation = recognizer.translation(in: self.view)
                    let minimizedVideoDraggingPosition = CGPoint(x: minimizedVideoInitialPosition.x + translation.x, y: minimizedVideoInitialPosition.y + translation.y)
                    self.minimizedVideoDraggingPosition = minimizedVideoDraggingPosition
                    minimizedVideoNode.position = minimizedVideoDraggingPosition
                } else {
                    switch self.pictureInPictureGestureState {
                    case .none:
                        let offset = recognizer.translation(in: self.view).y
                        var bounds = self.bounds
                        bounds.origin.y = -offset
                        self.bounds = bounds
                    case let .collapsing(didSelectCorner):
                        if let (layout, navigationHeight) = self.validLayout {
                            let offset = recognizer.translation(in: self.view)
                            if !didSelectCorner {
                                self.pictureInPictureGestureState = .collapsing(didSelectCorner: true)
                                if offset.x < 0.0 {
                                    self.pictureInPictureCorner = .topLeft
                                } else {
                                    self.pictureInPictureCorner = .topRight
                                }
                            }
                            let maxOffset: CGFloat = min(300.0, layout.size.height / 2.0)
                            
                            let offsetTransition = max(0.0, min(1.0, abs(offset.y) / maxOffset))
                            self.pictureInPictureTransitionFraction = offsetTransition
                            switch self.pictureInPictureCorner {
                            case .topRight, .bottomRight:
                                self.pictureInPictureCorner = offset.y < 0.0 ? .topRight : .bottomRight
                            case .topLeft, .bottomLeft:
                                self.pictureInPictureCorner = offset.y < 0.0 ? .topLeft : .bottomLeft
                            }
                            
                            self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .immediate)
                        }
                    case .dragging(let initialPosition, var draggingPosition):
                        let translation = recognizer.translation(in: self.view)
                        draggingPosition.x = initialPosition.x + translation.x
                        draggingPosition.y = initialPosition.y + translation.y
                        self.pictureInPictureGestureState = .dragging(initialPosition: initialPosition, draggingPosition: draggingPosition)
                        self.containerTransformationNode.position = draggingPosition
                    }
                }
            case .cancelled, .ended:
                if let minimizedVideoNode = self.minimizedVideoNode, let _ = self.minimizedVideoInitialPosition, let minimizedVideoDraggingPosition = self.minimizedVideoDraggingPosition {
                    self.minimizedVideoInitialPosition = nil
                    self.minimizedVideoDraggingPosition = nil
                    
                    if let (layout, navigationHeight) = self.validLayout {
                        self.outgoingVideoNodeCorner = self.nodeLocationForPosition(layout: layout, position: minimizedVideoDraggingPosition, velocity: recognizer.velocity(in: self.view))
                        
                        let videoFrame = self.calculatePreviewVideoRect(layout: layout, navigationHeight: navigationHeight)
                        minimizedVideoNode.frame = videoFrame
                        minimizedVideoNode.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: minimizedVideoDraggingPosition.x - videoFrame.midX, y: minimizedVideoDraggingPosition.y - videoFrame.midY)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, delay: 0.0, initialVelocity: 0.0, damping: 110.0, removeOnCompletion: true, additive: true, completion: nil)
                    }
                } else {
                    switch self.pictureInPictureGestureState {
                    case .none:
                        let velocity = recognizer.velocity(in: self.view).y
                        if abs(velocity) < 100.0 {
                            var bounds = self.bounds
                            let previous = bounds
                            bounds.origin = CGPoint()
                            self.bounds = bounds
                            self.layer.animateBounds(from: previous, to: bounds, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
                        } else {
                            var bounds = self.bounds
                            let previous = bounds
                            bounds.origin = CGPoint(x: 0.0, y: velocity > 0.0 ? -bounds.height: bounds.height)
                            self.bounds = bounds
                            self.layer.animateBounds(from: previous, to: bounds, duration: 0.15, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, completion: { [weak self] _ in
                                self?.dismissedInteractively?()
                            })
                        }
                    case .collapsing:
                        self.pictureInPictureGestureState = .none
                        let velocity = recognizer.velocity(in: self.view).y
                        if abs(velocity) < 100.0 && self.pictureInPictureTransitionFraction < 0.5 {
                            if let (layout, navigationHeight) = self.validLayout {
                                self.pictureInPictureTransitionFraction = 0.0
                                
                                self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
                            }
                        } else {
                            if let (layout, navigationHeight) = self.validLayout {
                                self.pictureInPictureTransitionFraction = 1.0
                                
                                self.containerLayoutUpdated(layout, navigationBarHeight: navigationHeight, transition: .animated(duration: 0.4, curve: .spring))
                            }
                        }
                    case let .dragging(initialPosition, _):
                        self.pictureInPictureGestureState = .none
                        if let (layout, navigationHeight) = self.validLayout {
                            let translation = recognizer.translation(in: self.view)
                            let draggingPosition = CGPoint(x: initialPosition.x + translation.x, y: initialPosition.y + translation.y)
                            self.pictureInPictureCorner = self.nodeLocationForPosition(layout: layout, position: draggingPosition, velocity: recognizer.velocity(in: self.view))
                            
                            let containerFrame = self.calculatePictureInPictureContainerRect(layout: layout, navigationHeight: navigationHeight)
                            self.containerTransformationNode.frame = containerFrame
                            containerTransformationNode.layer.animateSpring(from: NSValue(cgPoint: CGPoint(x: draggingPosition.x - containerFrame.midX, y: draggingPosition.y - containerFrame.midY)), to: NSValue(cgPoint: CGPoint()), keyPath: "position", duration: 0.5, delay: 0.0, initialVelocity: 0.0, damping: 110.0, removeOnCompletion: true, additive: true, completion: nil)
                        }
                    }
                }
            default:
                break
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.debugNode != nil {
            return super.hitTest(point, with: event)
        }
        if self.containerTransformationNode.frame.contains(point) {
            return self.containerTransformationNode.view.hitTest(self.view.convert(point, to: self.containerTransformationNode.view), with: event)
        }
        return nil
    }
}

final class CallPanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var firstLocation: CGPoint?
    
    public var shouldBegin: ((CGPoint) -> Bool)?
    
    override public init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        
        self.maximumNumberOfTouches = 1
    }
    
    override public func reset() {
        super.reset()
        
        self.firstLocation = nil
    }
    
    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        
        let touch = touches.first!
        let point = touch.location(in: self.view)
        if let shouldBegin = self.shouldBegin, !shouldBegin(point) {
            self.state = .failed
            return
        }
        
        self.firstLocation = point
    }
    
    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
    }
}
