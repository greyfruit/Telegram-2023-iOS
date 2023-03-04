import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit

func setBlurEffect(view: UIVisualEffectView, hasVideo: Bool) {
    UIView.animate(withDuration: 0.25, delay: 0.0) {
        view.effect = UIBlurEffect(style: hasVideo ? .dark : .light)
        view.alpha = 0.5
    }
}

//private let compactNameFont = Font.regular(28.0)
//private let regularNameFont = Font.regular(36.0)
private let compactNameFont = Font.semibold(17.0)
private let regularNameFont = Font.regular(28.0)

private let compactStatusFont = Font.regular(16.0)
private let regularStatusFont = Font.regular(16.0)

enum CallControllerStatusValue: Equatable {
    case text(string: String, displayLogo: Bool, displayLoadingIndicator: Bool, displayEndIndicator: Bool)
    case timer((String, Bool) -> String, Double)
    
    static func ==(lhs: CallControllerStatusValue, rhs: CallControllerStatusValue) -> Bool {
        switch lhs {
            case let .text(text, displayLogo, displayLoadingIndicator, displayEndIndicator):
                if case .text(text, displayLogo, displayLoadingIndicator, displayEndIndicator) = rhs {
                    return true
                } else {
                    return false
                }
            case let .timer(_, referenceTime):
                if case .timer(_, referenceTime) = rhs {
                    return true
                } else {
                    return false
                }
        }
    }
}

final class CallControllerLoadingIndicatorNode: ASDisplayNode {
    
    let circles: [CAShapeLayer] = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    var isAnimating = false
    
    override init() {
        super.init()
        
        self.circles.forEach { layer in
            layer.backgroundColor = UIColor.white.cgColor
            layer.cornerRadius = 2.0
            self.layer.addSublayer(layer)
        }
    }
    
    override func layout() {
        super.layout()
        
        let layerSize = CGSize(width: 4.0, height: 4.0)
        self.circles.enumerated().forEach { index, layer in
            layer.frame = CGRect(x: CGFloat(index) * layerSize.width + CGFloat(index) * 3.0, y: (self.bounds.height - layerSize.height) / 2.0, width: layerSize.width, height: layerSize.height)
        }
    }
    
    func startAnimation() {
        if self.isAnimating {
            return
        }
        
        self.isAnimating = true
        self.circles.enumerated().forEach { index, layer in
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.duration = 1.0 * UIView.animationDurationFactor()
            animation.toValue = NSNumber(0.5)
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.fillMode = .both
//            animation.timeOffset = index == 0 ? 0.0 : index == 1 ? 0.5 : 1.0
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + CGFloat(index) * 0.25 * UIView.animationDurationFactor()
            animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.linear)
            
//            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
//            animation.duration = 1.5
////            animation.speed = 1.0
//            animation.repeatCount = .infinity
//            animation.values = [NSNumber(1.0), NSNumber(0.5), NSNumber(1.0)]
//            animation.keyTimes = [NSNumber(0.0), NSNumber(0.5), NSNumber(1.0)]
//            animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
//            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.1
            layer.add(animation, forKey: "transform.scale")
        }
    }
    
    func stopAnimation() {
        guard self.isAnimating else {
            return
        }
        
        self.isAnimating = false
        self.circles.forEach { layer in
            layer.removeAllAnimations()
        }
    }
}

final class CallControllerStatusNode: ASDisplayNode {
    private let titleNode: TextNode
    private let statusContainerNode: ASDisplayNode
    private let statusNode: TextNode
    private let statusMeasureNode: TextNode
    private let receptionNode: CallControllerReceptionNode
    private let logoNode: ASImageNode
    
    private let loadingIndicatorNode: CallControllerLoadingIndicatorNode
    private let endIndicatorNode: ASImageNode
    let weakSignalNode: WeakSignalNode
    
    private let titleActivateAreaNode: AccessibilityAreaNode
    private let statusActivateAreaNode: AccessibilityAreaNode
    
    var title: String = ""
    var subtitle: String = ""
    var status: CallControllerStatusValue = .text(string: "", displayLogo: false, displayLoadingIndicator: false, displayEndIndicator: false) {
        didSet {
            if self.status != oldValue {
                self.statusTimer?.invalidate()
                
                switch self.status {
                case let .text(text, _, _, displayEndIndicator) where displayEndIndicator && text.first.map(String.init).flatMap(Int.init) != nil:
                    if let validLayoutWidth = self.validLayoutWidth {
                        let _ = self.updateLayout(constrainedWidth: validLayoutWidth, transition: .immediate)
                    }
                    self.receptionNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
                    self.endIndicatorNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3, removeOnCompletion: false)
                    self.endIndicatorNode.layer.animatePosition(from: self.endIndicatorNode.layer.position.offsetBy(dx: 0.0, dy: -10.0), to: self.endIndicatorNode.layer.position, duration: 0.3, removeOnCompletion: false)
                default:
                    if let snapshotView = self.statusContainerNode.view.snapshotView(afterScreenUpdates: false) {
                        snapshotView.frame = self.statusContainerNode.frame
                        self.view.insertSubview(snapshotView, belowSubview: self.statusContainerNode.view)
                        
                        snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                            snapshotView?.removeFromSuperview()
                        })
                        snapshotView.layer.animateScale(from: 1.0, to: 0.3, duration: 0.3, removeOnCompletion: false)
                        snapshotView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: snapshotView.frame.height / 2.0), duration: 0.3, delay: 0.0, removeOnCompletion: false, additive: true)
                        
                        self.statusContainerNode.layer.animateScale(from: 0.3, to: 1.0, duration: 0.3)
                        self.statusContainerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
                        self.statusContainerNode.layer.animatePosition(from: CGPoint(x: 0.0, y: -snapshotView.frame.height / 2.0), to: CGPoint(), duration: 0.3, delay: 0.0, additive: true)
                    }
                }
                                
                if case .timer = self.status {
                    self.statusTimer = SwiftSignalKit.Timer(timeout: 0.5, repeat: true, completion: { [weak self] in
                        if let strongSelf = self, let validLayoutWidth = strongSelf.validLayoutWidth {
                            let _ = strongSelf.updateLayout(constrainedWidth: validLayoutWidth, transition: .immediate)
                        }
                    }, queue: Queue.mainQueue())
                    self.statusTimer?.start()
                } else {
                    if let validLayoutWidth = self.validLayoutWidth {
                        let _ = self.updateLayout(constrainedWidth: validLayoutWidth, transition: .immediate)
                    }
                }
            }
        }
    }
    
    var reception: Int32? {
        didSet {
            if self.reception != oldValue {
                if let reception = self.reception {
                    self.receptionNode.reception = reception
                    
                    if oldValue == nil {
                        let transition = ContainedViewLayoutTransition.animated(duration: 0.3, curve: .spring)
                        transition.updateAlpha(node: self.receptionNode, alpha: 1.0)
                    }
                } else if self.reception == nil, oldValue != nil {
                    let transition = ContainedViewLayoutTransition.animated(duration: 0.3, curve: .spring)
                    transition.updateAlpha(node: self.receptionNode, alpha: 0.0)
                }
                
                if (oldValue == nil) != (self.reception != nil) {
                    if let validLayoutWidth = self.validLayoutWidth {
                        let _ = self.updateLayout(constrainedWidth: validLayoutWidth, transition: .immediate)
                    }
                }
            }
        }
    }
    
    private var statusTimer: SwiftSignalKit.Timer?
    private var validLayoutWidth: CGFloat?
    
    class WeakSignalNode: ASDisplayNode {
        
        let textNode: ImmediateTextNode
        let effectView: UIVisualEffectView
        
        override init() {
            self.textNode = ImmediateTextNode()
            self.effectView = UIVisualEffectView()
            
            super.init()
                        
            self.effectView.effect = UIBlurEffect(style: .light)
            setBlurEffect(view: self.effectView, hasVideo: latestHasVideoState)
            
            self.textNode.displaysAsynchronously = false
            self.textNode.attributedText = NSAttributedString(string: "Weak network signal", font: Font.regular(16.0), textColor: UIColor.white)
            self.textNode.textAlignment = .center
            self.textNode.verticalAlignment = .middle
            
            self.view.addSubview(self.effectView)
            self.view.addSubnode(self.textNode)
        }
        
        override func layout() {
            super.layout()
            
            self.effectView.frame = self.bounds
        }
    }
    
    override init() {
        self.titleNode = TextNode()
        self.statusContainerNode = ASDisplayNode()
        self.statusNode = TextNode()
        self.statusNode.displaysAsynchronously = false
        self.statusMeasureNode = TextNode()
       
        self.receptionNode = CallControllerReceptionNode()
        self.receptionNode.alpha = 0.0
        
        self.logoNode = ASImageNode()
        self.logoNode.image = generateTintedImage(image: UIImage(bundleImageName: "Call/CallTitleLogo"), color: .white)
        self.logoNode.isHidden = true
        
        self.titleActivateAreaNode = AccessibilityAreaNode()
        self.titleActivateAreaNode.accessibilityTraits = .staticText
        
        self.statusActivateAreaNode = AccessibilityAreaNode()
        self.statusActivateAreaNode.accessibilityTraits = [.staticText, .updatesFrequently]
        
        self.endIndicatorNode = ASImageNode()
        self.endIndicatorNode.image = UIImage(bundleImageName: "CallStatusEndIcon")
        
        self.loadingIndicatorNode = CallControllerLoadingIndicatorNode()
        self.loadingIndicatorNode.startAnimation()
        
        self.weakSignalNode = WeakSignalNode()
        self.weakSignalNode.cornerRadius = 15.0
        self.weakSignalNode.clipsToBounds = true
        
        super.init()
        
        self.isUserInteractionEnabled = false
        
        self.addSubnode(self.titleNode)
        self.addSubnode(self.statusContainerNode)
        self.statusContainerNode.addSubnode(self.statusNode)
        self.statusContainerNode.addSubnode(self.receptionNode)
        self.statusContainerNode.addSubnode(self.logoNode)
        self.statusContainerNode.addSubnode(self.loadingIndicatorNode)
        self.statusContainerNode.addSubnode(self.endIndicatorNode)
        self.addSubnode(self.weakSignalNode)
        
        self.addSubnode(self.titleActivateAreaNode)
        self.addSubnode(self.statusActivateAreaNode)
    }
    
    deinit {
        self.statusTimer?.invalidate()
    }
    
    func setVisible(_ visible: Bool, transition: ContainedViewLayoutTransition) {
        let alpha: CGFloat = visible ? 1.0 : 0.0
        transition.updateAlpha(node: self.titleNode, alpha: alpha)
        transition.updateAlpha(node: self.statusContainerNode, alpha: alpha)
    }
    
    func updateLayout(constrainedWidth: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.validLayoutWidth = constrainedWidth
        
        let nameFont: UIFont
        let nameScale: CGFloat
        let statusFont: UIFont
        if constrainedWidth < 330.0 {
            nameScale = 0.6
            nameFont = regularNameFont
            statusFont = compactStatusFont
        } else {
            nameScale = 1.0
            nameFont = regularNameFont
            statusFont = regularStatusFont
        }
        
        var statusOffset: CGFloat = 0.0
        let statusText: String
        let statusMeasureText: String
        var statusDisplayLogo: Bool = false
        var statusDisplayLoadingIndicator: Bool = false
        var statusDisplayEndIndicator: Bool = false
        switch self.status {
        case let .text(text, displayLogo, displayLoadingIndicator, displayEndIndicator):
            statusText = text.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            statusMeasureText = text
            statusDisplayLogo = displayLogo
            statusDisplayLoadingIndicator = displayLoadingIndicator
            statusDisplayEndIndicator = displayEndIndicator
            if displayLogo {
                statusOffset += 10.0
            }
            if displayEndIndicator {
                statusOffset += 8.0
            }
        case let .timer(format, referenceTime):
            let duration = Int32(CFAbsoluteTimeGetCurrent() - referenceTime)
            let durationString: String
            let measureDurationString: String
            if duration > 60 * 60 {
                durationString = String(format: "%02d:%02d:%02d", arguments: [duration / 3600, (duration / 60) % 60, duration % 60])
                measureDurationString = "00:00:00"
            } else {
                durationString = String(format: "%02d:%02d", arguments: [(duration / 60) % 60, duration % 60])
                measureDurationString = "00:00"
            }
            statusText = format(durationString, false)
            statusMeasureText = format(measureDurationString, true)
            if self.reception != nil {
                statusOffset += 8.0
            }
        }
        
        let spacing: CGFloat
        if constrainedWidth < 330.0 {
            spacing = 4.0
        } else {
            spacing = -4.0
        }
        
        let (titleLayout, titleApply) = TextNode.asyncLayout(self.titleNode)(TextNodeLayoutArguments(attributedString: NSAttributedString(string: self.title, font: nameFont, textColor: .white), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: constrainedWidth - 20.0, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets(top: 2.0, left: 2.0, bottom: 2.0, right: 2.0)))
        let (statusMeasureLayout, statusMeasureApply) = TextNode.asyncLayout(self.statusMeasureNode)(TextNodeLayoutArguments(attributedString: NSAttributedString(string: statusMeasureText, font: statusFont, textColor: .white), backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: constrainedWidth - 20.0, height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets(top: 2.0, left: 2.0, bottom: 2.0, right: 2.0)))
        let (statusLayout, statusApply) = TextNode.asyncLayout(self.statusNode)(TextNodeLayoutArguments(attributedString: NSAttributedString(string: statusText, font: statusFont, textColor: .white), backgroundColor: nil, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: constrainedWidth - 20.0, height: CGFloat.greatestFiniteMagnitude), alignment: .center, verticalAlignment: .middle, cutout: nil, insets: UIEdgeInsets(top: 2.0, left: 2.0, bottom: 2.0, right: 2.0)))
        
        let _ = titleApply()
        let _ = statusApply()
        let _ = statusMeasureApply()
        
        self.titleActivateAreaNode.accessibilityLabel = self.title
        self.statusActivateAreaNode.accessibilityLabel = statusText
        
        transition.updateTransformScale(node: self.titleNode, scale: nameScale)
//        transition.updateFrame(node: self.titleNode, frame: CGRect(origin: CGPoint(x: floor((constrainedWidth - titleLayout.size.width) / 2.0), y: 0.0), size: titleLayout.size))
        self.titleNode.frame = CGRect(origin: CGPoint(x: floor((constrainedWidth - titleLayout.size.width) / 2.0), y: 0.0), size: titleLayout.size)
        
        transition.updateFrame(node: self.statusContainerNode, frame: CGRect(origin: CGPoint(x: 0.0, y: titleLayout.size.height * nameScale + spacing), size: CGSize(width: constrainedWidth, height: statusLayout.size.height)))
//        self.statusContainerNode.frame = CGRect(origin: CGPoint(x: 0.0, y: titleLayout.size.height * nameScale + spacing), size: CGSize(width: constrainedWidth, height: statusLayout.size.height))
        
//        self.statusContainerNode.backgroundColor = .red
//        self.statusNode.backgroundColor = .blue
//        self.receptionNode.backgroundColor = .green
        
        self.statusNode.frame = CGRect(origin: CGPoint(x: floor((constrainedWidth - statusMeasureLayout.size.width) / 2.0) + statusOffset, y: 0.0), size: statusLayout.size)
        self.receptionNode.frame = CGRect(origin: CGPoint(x: self.statusNode.frame.minX - receptionNodeSize.width, y: (self.statusContainerNode.bounds.height - receptionNodeSize.height) / 2.0 - 1.0), size: receptionNodeSize)
        self.logoNode.isHidden = !statusDisplayLogo
        if let image = self.logoNode.image, let firstLineRect = statusMeasureLayout.linesRects().first {
            let firstLineOffset = floor((statusMeasureLayout.size.width - firstLineRect.width) / 2.0)
            self.logoNode.frame = CGRect(origin: CGPoint(x: self.statusNode.frame.minX + firstLineOffset - image.size.width - 7.0, y: 5.0), size: image.size)
        }
        
        self.loadingIndicatorNode.frame = CGRect(x: self.statusNode.frame.maxX + 6.0, y: 0.0, width: 18.0, height: self.statusNode.bounds.height)
        self.loadingIndicatorNode.isHidden = !statusDisplayLoadingIndicator
        
//        self.endIndicatorNode.frame = self.receptionNode.frame //CGRect(x: self.statusNode.frame.minX - 26.0, y: (self.statusContainerNode.bounds.height - 20.0) / 2.0, width: 20.0, height: 20.0)
        self.endIndicatorNode.frame = CGRect(x: self.statusNode.frame.minX - 26.0, y: (self.statusContainerNode.bounds.height - 20.0) / 2.0, width: 20.0, height: 20.0)
        self.endIndicatorNode.isHidden = !statusDisplayEndIndicator
        
        self.titleActivateAreaNode.frame = self.titleNode.frame
        self.statusActivateAreaNode.frame = self.statusContainerNode.frame
        
        let oldAlpha = self.weakSignalNode.alpha
        let newAlpha = (self.reception == nil || self.reception ?? 0 > 1) ? 0.0 : 1.0
        let alphaChanged = abs(oldAlpha - newAlpha) > 0.01
        let weakSignalTextNodeSize = CGSize(width: self.weakSignalNode.textNode.updateLayout(CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude)).width + 24.0, height: 30.0)
        self.weakSignalNode.textNode.frame.size = weakSignalTextNodeSize
        self.weakSignalNode.frame = CGRect(x: (self.bounds.width - weakSignalTextNodeSize.width) / 2.0, y: self.statusContainerNode.frame.maxY + 12.0, width: weakSignalTextNodeSize.width, height: weakSignalTextNodeSize.height)
        self.weakSignalNode.alpha = newAlpha
        if alphaChanged {
            if newAlpha > 0.0 {
                self.weakSignalNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
                self.weakSignalNode.layer.animateScale(from: 0.3, to: 1.0, duration: 0.3)
            } else {
                self.weakSignalNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3)
                self.weakSignalNode.layer.animateScale(from: 1.0, to: 0.3, duration: 0.3)
            }
        }
        
        return titleLayout.size.height * nameScale + spacing + statusLayout.size.height
    }
}

private final class CallControllerReceptionNodeParameters: NSObject {
    let reception: Int32
    
    init(reception: Int32) {
        self.reception = reception
    }
}

private let receptionNodeSize = CGSize(width: 20.0, height: 12.0)

final class CallControllerReceptionNode : ASDisplayNode {
    var reception: Int32 = 4 {
        didSet {
            self.setNeedsDisplay()
        }
    }
    
    override init() {
        super.init()
        
        self.isOpaque = false
        self.isLayerBacked = true
    }
    
    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        return CallControllerReceptionNodeParameters(reception: self.reception)
    }
    
    @objc override class func draw(_ bounds: CGRect, withParameters parameters: Any?, isCancelled: () -> Bool, isRasterizing: Bool) {
        let context = UIGraphicsGetCurrentContext()!
        context.setFillColor(UIColor.white.cgColor)
        
        if let parameters = parameters as? CallControllerReceptionNodeParameters{
            let width: CGFloat = 3.0
            var spacing: CGFloat = 1.5
            if UIScreenScale > 2 {
                spacing = 4.0 / 3.0
            }
            
            for i in 0 ..< 4 {
                let height = 4.0 + 2.0 * CGFloat(i)
                let rect = CGRect(x: bounds.minX + CGFloat(i) * (width + spacing), y: receptionNodeSize.height - height, width: width, height: height)
                
                if i >= parameters.reception {
                    context.setAlpha(0.3)
                }
                
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 1.0)
                context.addPath(path.cgPath)
                context.fillPath()
            }
        }
    }
}
