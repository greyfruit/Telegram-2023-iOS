import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData

private let labelFont = Font.regular(17.0)
private let smallLabelFont = Font.regular(15.0)

private enum ToastDescription: Equatable {
    enum Key: Hashable {
        case camera
        case microphone
        case mute
        case battery
    }
    
    case camera
    case microphone
    case mute
    case battery
    
    var key: Key {
        switch self {
        case .camera:
            return .camera
        case .microphone:
            return .microphone
        case .mute:
            return .mute
        case .battery:
            return .battery
        }
    }
}

struct CallControllerToastContent: OptionSet {
    public var rawValue: Int32
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public static let camera = CallControllerToastContent(rawValue: 1 << 0)
    public static let microphone = CallControllerToastContent(rawValue: 1 << 1)
    public static let mute = CallControllerToastContent(rawValue: 1 << 2)
    public static let battery = CallControllerToastContent(rawValue: 1 << 3)
}

final class CallControllerToastContainerNode: ASDisplayNode {
    private var toastNodes: [ToastDescription.Key: CallControllerToastItemNode] = [:]
    private var visibleToastNodes: [CallControllerToastItemNode] = []
    
    private let strings: PresentationStrings
    
    private var validLayout: (CGFloat, CGFloat)?
    
    private var content: CallControllerToastContent?
    private var appliedContent: CallControllerToastContent?
    var title: String = ""
    
    init(strings: PresentationStrings) {
        self.strings = strings
        
        super.init()
//        self.backgroundColor = .red
    }
    
    private func updateToastsLayout(strings: PresentationStrings, content: CallControllerToastContent, width: CGFloat, bottomInset: CGFloat, animated: Bool, containerTransition: ContainedViewLayoutTransition) -> CGFloat {
        let transition: ContainedViewLayoutTransition
        if animated {
            transition = .animated(duration: 0.3, curve: .spring)
        } else {
            transition = .immediate
        }
        
        self.appliedContent = content
        
        let spacing: CGFloat = 18.0
    
        var height: CGFloat = 0.0
        var toasts: [ToastDescription] = []
        
        if content.contains(.camera) {
            toasts.append(.camera)
        }
        if content.contains(.microphone) {
            toasts.append(.microphone)
        }
        if content.contains(.mute) {
            toasts.append(.mute)
        }
        if content.contains(.battery) {
            toasts.append(.battery)
        }
        
        var transitions: [ToastDescription.Key: (ContainedViewLayoutTransition, CGFloat, Bool)] = [:]
        var validKeys: [ToastDescription.Key] = []
        for toast in toasts {
            validKeys.append(toast.key)
            var toastTransition = transition
            var animateIn = false
            let toastNode: CallControllerToastItemNode
            if let current = self.toastNodes[toast.key] {
                toastNode = current
            } else {
                toastNode = CallControllerToastItemNode()
                self.toastNodes[toast.key] = toastNode
                self.addSubnode(toastNode)
                self.visibleToastNodes.append(toastNode)
                toastTransition = .immediate
                animateIn = transition.isAnimated
            }
            let toastContent: CallControllerToastItemNode.Content
            switch toast {
                case .camera:
                    toastContent = CallControllerToastItemNode.Content(
                        key: .camera,
                        image: .camera,
                        text: strings.Call_CameraOff(self.title).string
                    )
                case .microphone:
                    toastContent = CallControllerToastItemNode.Content(
                        key: .microphone,
                        image: .microphone,
                        text: strings.Call_MicrophoneOff(self.title).string
                    )
                case .mute:
                    toastContent = CallControllerToastItemNode.Content(
                        key: .mute,
                        image: .microphone,
                        text: strings.Call_YourMicrophoneOff
                    )
                case .battery:
                    toastContent = CallControllerToastItemNode.Content(
                        key: .battery,
                        image: .battery,
                        text: strings.Call_BatteryLow(self.title).string
                    )
            }
            let toastHeight = toastNode.update(width: width, content: toastContent, transition: toastTransition)
            transitions[toast.key] = (toastTransition, toastHeight, animateIn)
        }
        
        var removedHeights: [Int: CGFloat] = [:]
        var removedKeys: [ToastDescription.Key] = []
        for (_, (key, toastNode)) in self.toastNodes.enumerated() {
            if !validKeys.contains(key) {
                removedKeys.append(key)
                if let index = self.visibleToastNodes.firstIndex(of: toastNode) {
                    removedHeights[index] = toastNode.bounds.height + spacing
                }
                self.visibleToastNodes.removeAll { $0 === toastNode }
                if animated {
                    toastNode.animateOut(transition: transition) { [weak toastNode] in
                        toastNode?.removeFromSupernode()
                    }
                } else {
                    toastNode.removeFromSupernode()
                }
            }
        }
        for key in removedKeys {
            self.toastNodes.removeValue(forKey: key)
        }
        
        var totalRemovedHeight = CGFloat(0.0)
        for (index, toastNode) in self.visibleToastNodes.enumerated() {
            if let removedHeight = removedHeights[index] {
                totalRemovedHeight += removedHeight
            }
            
            if let content = toastNode.currentContent, let (_, toastHeight, animateIn) = transitions[content.key] {
                if animateIn {
                    let frame = CGRect(x: 0.0, y: height, width: width, height: toastHeight)
                    toastNode.frame = frame
                    toastNode.animateIn(transition: containerTransition, offset: (index == 0) ? toastHeight : toastHeight + spacing)
                } else {
                    if toastNode.isAnimating {
                    } else {
                        let frame = CGRect(x: 0.0, y: height, width: width, height: toastHeight)
                        toastNode.updateFrame(transition: containerTransition, frame: frame, offset: totalRemovedHeight)
                    }
                }
                height += toastHeight + spacing
            }
        }
        if height > 0.0 {
            height -= spacing
        }
        
        return height
    }
    
    func updateLayout(strings: PresentationStrings, content: CallControllerToastContent?, constrainedWidth: CGFloat, bottomInset: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.validLayout = (constrainedWidth, bottomInset)
        
        self.content = content
        
        if let content = self.content {
            return self.updateToastsLayout(strings: strings, content: content, width: constrainedWidth, bottomInset: bottomInset, animated: transition.isAnimated, containerTransition: transition)
        } else {
            return 0.0
        }
    }
}

private class CallControllerToastItemNode: ASDisplayNode {
    struct Content: Equatable {
        enum Image {
            case camera
            case microphone
            case battery
        }
        
        var key: ToastDescription.Key
        var image: Image
        var text: String
        
        init(key: ToastDescription.Key, image: Image, text: String) {
            self.key = key
            self.image = image
            self.text = text
        }
    }
    
    let clipNode: ASDisplayNode
    let effectView: UIVisualEffectView
    let iconNode: ASImageNode
    let textNode: ImmediateTextNode
    
    private(set) var currentContent: Content?
    private(set) var currentWidth: CGFloat?
    private(set) var currentHeight: CGFloat?
    
    override init() {
        self.clipNode = ASDisplayNode()
        self.clipNode.clipsToBounds = true
        self.clipNode.layer.cornerRadius = 14.0
        
        self.effectView = UIVisualEffectView()
        self.effectView.effect = UIBlurEffect(style: .light)
        setBlurEffect(view: self.effectView, hasVideo: latestHasVideoState)
        self.effectView.isUserInteractionEnabled = false
        
        self.iconNode = ASImageNode()
        self.iconNode.displaysAsynchronously = false
        self.iconNode.displayWithoutProcessing = true
        self.iconNode.contentMode = .center
        
        self.textNode = ImmediateTextNode()
        self.textNode.maximumNumberOfLines = 2
        self.textNode.displaysAsynchronously = false
        self.textNode.isUserInteractionEnabled = false
        
        super.init()
        
        self.addSubnode(self.clipNode)
        self.clipNode.view.addSubview(self.effectView)
//        self.clipNode.addSubnode(self.iconNode)
        self.clipNode.addSubnode(self.textNode)
    }
    
    override func didLoad() {
        super.didLoad()
        
        if #available(iOS 13.0, *) {
            self.clipNode.layer.cornerCurve = .continuous
        }
    }
    
    func update(width: CGFloat, content: Content, transition: ContainedViewLayoutTransition) -> CGFloat {
        let inset: CGFloat = 30.0
        let isNarrowScreen = width <= 320.0
        let font = isNarrowScreen ? smallLabelFont : labelFont
        let topInset: CGFloat = isNarrowScreen ? 5.0 : 4.0
                
        if self.currentContent != content || self.currentWidth != width {
            self.currentContent = content
            self.currentWidth = width
            
//            var image: UIImage?
//            switch content.image {
//                case .camera:
//                    image = generateTintedImage(image: UIImage(bundleImageName: "Call/CallToastCamera"), color: .white)
//                case .microphone:
//                    image = generateTintedImage(image: UIImage(bundleImageName: "Call/CallToastMicrophone"), color: .white)
//                case .battery:
//                    image = generateTintedImage(image: UIImage(bundleImageName: "Call/CallToastBattery"), color: .white)
//            }
            
//            if transition.isAnimated, let image = image, let previousContent = self.iconNode.image {
//                self.iconNode.image = image
//                self.iconNode.layer.animate(from: previousContent.cgImage!, to: image.cgImage!, keyPath: "contents", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, duration: 0.2)
//            } else {
//                self.iconNode.image = image
//            }
                  
            self.textNode.attributedText = NSAttributedString(string: content.text, font: font, textColor: .white)
            
//            let iconSize = CGSize(width: 44.0, height: 28.0)
//            let iconSpacing: CGFloat = isNarrowScreen ? 0.0 : 1.0
//            let textSize = self.textNode.updateLayout(CGSize(width: width - inset * 2.0 - iconSize.width - iconSpacing, height: 100.0))
            let textSize = self.textNode.updateLayout(CGSize(width: width - inset * 2.0, height: 100.0))
            
            let backgroundSize = CGSize(width: textSize.width + 12.0 * 2.0, height: max(28.0, textSize.height + 4.0 * 2.0))
            let backgroundFrame = CGRect(origin: CGPoint(x: floor((width - backgroundSize.width) / 2.0), y: 0.0), size: backgroundSize)
            
            transition.updateFrame(node: self.clipNode, frame: backgroundFrame)
            transition.updateFrame(view: self.effectView, frame: CGRect(origin: CGPoint(), size: backgroundFrame.size))
//            self.iconNode.frame = CGRect(origin: CGPoint(), size: iconSize)
            self.textNode.frame = CGRect(origin: CGPoint(x: 12.0, y: topInset), size: textSize)
            
            self.currentHeight = backgroundSize.height
        }
        return self.currentHeight ?? 28.0
    }
    
    var isAnimating = false
    func animateIn(transition: ContainedViewLayoutTransition, offset: CGFloat) {
        let duration: Double
        switch transition {
        case let .animated(transitionDuration, _):
            duration = transitionDuration
        case .immediate:
            duration = 0.0
        }
        
        self.isAnimating = true
        let originalFrame = self.frame
        let originalSupernode = self.supernode
        if let supernode = self.supernode(of: CallControllerNode.self, includingSelf: false) as? CallControllerNode {
//            self.frame = self.convert(self.bounds, to: supernode)
            self.frame = self.convert(self.bounds, to: supernode.containerNode)
            self.frame.origin.y -= offset
            supernode.containerNode.insertSubnode(self, belowSubnode: supernode.buttonsNode)
//            supernode.insertSubnode(self, belowSubnode: supernode.buttonsNode)
//            supernode.addSubnode(self)
            
            self.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration * 0.5)
            self.layer.animateSpring(from: 0.3 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: duration, damping: 105.0, completion: { _ in
                self.removeFromSupernode()
                self.frame = originalFrame
                self.isAnimating = false
                originalSupernode?.addSubnode(self)
            })
        }
        
        
//        if var transitionView = self.view.snapshotView(afterScreenUpdates: true), let supernode = self.supernode(of: CallControllerNode.self, includingSelf: false) {
//            transitionView = self.view
//            transitionView.frame = self.convert(self.bounds, to: supernode)
//            transitionView.frame.origin.y -= offset
////            supernode.view.addSubview(transitionView)
//
////            self.isHidden = true
//            transitionView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
//            transitionView.layer.animateSpring(from: 0.3 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.3, damping: 105.0, completion: { _ in
//                transitionView.removeFromSuperview()
////                self.isHidden = false
//            })
//        }
        
//        let targetFrame = self.clipNode.frame
//        let initialFrame = CGRect(x: floor((self.frame.width - 44.0) / 2.0), y: 0.0, width: 44.0, height: 28.0)
//        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
//        self.layer.animateSpring(from: 0.01 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.3, damping: 105.0, completion: { _ in
//            self.clipNode.frame = targetFrame
            
//            self.clipNode.layer.animateFrame(from: initialFrame, to: targetFrame, duration: 0.35, timingFunction: kCAMediaTimingFunctionSpring)
//        })
    }
    
    func updateFrame(transition: ContainedViewLayoutTransition, frame: CGRect, offset: CGFloat) {
//        let originalFrame = self.frame
                
        if let supernode = self.supernode(of: CallControllerNode.self, includingSelf: false) as? CallControllerNode {
            var currentFrameInContainer = self.convert(self.bounds, to: supernode.containerNode)
            var newFrameInContainer = self.supernode!.convert(frame, to: supernode.containerNode)
            
            currentFrameInContainer.origin.y += offset
            newFrameInContainer.origin.y += offset
            
            if currentFrameInContainer == newFrameInContainer {
//                self.frame = frame
//                transition.updateFrame(node: self, frame: frame, force: true, completion: { _ in
//                    self.isAnimating = false
//                })
            } else {
                self.isAnimating = true
                self.frame = newFrameInContainer
                let originalSupernode = self.supernode
                supernode.containerNode.insertSubnode(self, belowSubnode: supernode.buttonsNode)
                transition.updateFrame(node: self, frame: newFrameInContainer, force: true, completion: { _ in
                    self.isAnimating = false
                    self.frame = frame
                    self.removeFromSupernode()
                    originalSupernode?.addSubnode(self)
                })
            }
        }
    }
    
    func animateOut(transition: ContainedViewLayoutTransition, completion: @escaping () -> Void) {
        let duration: Double
        switch transition {
        case let .animated(transitionDuration, _):
            duration = transitionDuration
        case .immediate:
            duration = 0.0
        }
        
        if let supernode = self.supernode(of: CallControllerNode.self, includingSelf: false) as? CallControllerNode {
            self.frame = self.convert(self.bounds, to: supernode.containerNode)
            supernode.containerNode.insertSubnode(self, belowSubnode: supernode.buttonsNode)
            //            supernode.addSubnode(self)
            
            self.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration * 0.5, removeOnCompletion: false)
            self.layer.animateSpring(from: 1.0 as NSNumber, to: 0.3 as NSNumber, keyPath: "transform.scale", duration: duration, damping: 105.0, removeOnCompletion: false, completion: { _ in
                self.removeFromSupernode()
                completion()
            })
        }
        
//        if let transitionView = self.view.snapshotView(afterScreenUpdates: false), let supernode = self.supernode(of: CallControllerNode.self, includingSelf: false) {
//            transitionView.frame = self.convert(self.bounds, to: supernode)
//            supernode.layer.addSublayer(transitionView.layer)
//
//            self.isHidden = true
//            transitionView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
//            transitionView.layer.animateSpring(from: 1.0 as NSNumber, to: 0.3 as NSNumber, keyPath: "transform.scale", duration: 0.3, damping: 105.0, removeOnCompletion: false, completion: { _ in
//                transitionView.removeFromSuperview()
//                completion()
//            })
//
//        }
//        transition.updateTransformScale(node: self, scale: 0.1)
//        transition.updateAlpha(node: self, alpha: 0.0, completion: { _ in
//            completion()
//        })
    }
}
