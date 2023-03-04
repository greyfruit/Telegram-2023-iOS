import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import LegacyComponents

private let emojiFont = Font.regular(48.0)
private let titleFont = Font.semibold(16)
private let textFont = Font.regular(16.0)
private let confirmFont = Font.regular(20.0)

final class CallControllerKeyPreviewNode: ASDisplayNode {
    let keyTextNode: ASTextNode
    private let titleTextNode: ASTextNode
    private let infoTextNode: ASTextNode
    private let confirmTextNode: ASTextNode
    private let containerNode: ASDisplayNode
    private let effectView: UIVisualEffectView
    
    private let dismiss: () -> Void
    
    init(keyText: String, infoText: String, hasVideo: Bool, dismiss: @escaping () -> Void) {
        self.keyTextNode = ASTextNode()
        self.keyTextNode.displaysAsynchronously = false
        self.titleTextNode = ASTextNode()
        self.titleTextNode.displaysAsynchronously = false
        self.infoTextNode = ASTextNode()
        self.infoTextNode.displaysAsynchronously = false
        self.confirmTextNode = ASTextNode()
        self.confirmTextNode.displaysAsynchronously = false
        self.dismiss = dismiss
        
        self.containerNode = ASDisplayNode()
        
        self.effectView = UIVisualEffectView()
        self.effectView.clipsToBounds = true
        self.effectView.layer.cornerRadius = 20.0
        if #available(iOS 9.0, *) {
            self.effectView.effect = UIBlurEffect(style: hasVideo ? .dark : .light)
        } else {
            self.effectView.alpha = 1.0
        }
        
        super.init()
        
        self.keyTextNode.attributedText = NSAttributedString(string: keyText, attributes: [NSAttributedString.Key.font: emojiFont, NSAttributedString.Key.kern: 6.0 as NSNumber])
        self.titleTextNode.attributedText = NSAttributedString(string: "This call is end-to end encrypted", font: titleFont, textColor: UIColor.white, paragraphAlignment: .center)
        self.infoTextNode.attributedText = NSAttributedString(string: infoText, font: textFont, textColor: UIColor.white, paragraphAlignment: .center)
        self.confirmTextNode.attributedText = NSAttributedString(string: "OK", font: confirmFont, textColor: UIColor.white, paragraphAlignment: .center)
        
        self.containerNode.view.addSubview(self.effectView)
        self.containerNode.addSubnode(self.titleTextNode)
        self.containerNode.addSubnode(self.infoTextNode)
        self.containerNode.addSubnode(self.confirmTextNode)
        self.addSubnode(self.containerNode)
        self.addSubnode(self.keyTextNode)
        self.keyTextNode.alpha = 0.0
        
//        self.view.addSubview(self.effectView)
//        self.addSubnode(self.keyTextNode)
//        self.addSubnode(self.infoTextNode)
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
    }
    
    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.containerNode.frame = CGRect(origin: CGPoint(), size: size)
        self.effectView.frame = CGRect(origin: CGPoint(), size: size)
        
        let keyTextSize = self.keyTextNode.measure(CGSize(width: 300.0, height: 300.0))
        transition.updateFrame(node: self.keyTextNode, frame: CGRect(origin: CGPoint(x: floor((size.width - keyTextSize.width) / 2) + 6.0, y: 20.0), size: keyTextSize))
        
        let constraintedTextSize = CGSize(width: size.width - 32.0, height: CGFloat.greatestFiniteMagnitude)
        
        let titleTextSize = self.titleTextNode.measure(constraintedTextSize)
        transition.updateFrame(node: self.titleTextNode, frame: CGRect(origin: CGPoint(x: floor((size.width - titleTextSize.width) / 2.0), y: self.keyTextNode.frame.maxY + 10.0), size: titleTextSize))
        
        let infoTextSize = self.infoTextNode.measure(constraintedTextSize)
        transition.updateFrame(node: self.infoTextNode, frame: CGRect(origin: CGPoint(x: floor((size.width - infoTextSize.width) / 2.0), y: self.titleTextNode.frame.maxY + 10.0), size: infoTextSize))
        
        let confirmTextSize = self.confirmTextNode.measure(constraintedTextSize)
        transition.updateFrame(node: self.confirmTextNode, frame: CGRect(origin: CGPoint(x: floor((size.width - confirmTextSize.width) / 2.0), y: self.infoTextNode.frame.maxY + 35.0), size: confirmTextSize))
        
        let maskImage = UIGraphicsImageRenderer(size: size).image { _ in guard let context = UIGraphicsGetCurrentContext() else { return }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.setBlendMode(.clear)
            context.fill(CGRect(origin: CGPoint(x: 0.0, y: self.confirmTextNode.frame.minY - 15.0), size: CGSize(width: size.width, height: 1.0)))
            context.setBlendMode(.normal)
            context.setFillColor(UIColor.white.withAlphaComponent(0.25).cgColor)
            context.fill(CGRect(origin: CGPoint(x: 0.0, y: self.confirmTextNode.frame.minY - 15.0), size: CGSize(width: size.width, height: 1.0)))
        }
        
        let containerMask = CALayer()
        containerMask.frame = self.containerNode.bounds
        containerMask.contents = maskImage.cgImage
        self.containerNode.layer.mask = containerMask
        
        return self.infoTextNode.frame.maxY
    }
    
    func animateIn(from fromRect: CGRect, fromNode: ASDisplayNode) {
        let fromRect = CGRect(origin: self.convert(fromRect.origin, from: fromNode.supernode), size: fromRect.size)
//        if let transitionView = fromNode.view.snapshotView(afterScreenUpdates: false) {
//            self.view.addSubview(transitionView)
//            transitionView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
//            transitionView.layer.animatePosition(from: CGPoint(x: fromRect.midX, y: fromRect.midY), to: self.keyTextNode.layer.position, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { [weak transitionView] _ in
//                transitionView?.removeFromSuperview()
//            })
//            transitionView.layer.animateScale(from: 1.0, to: self.keyTextNode.frame.size.width / fromRect.size.width, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
//        }
        
//        self.keyTextNode.layer.animatePosition(from: CGPoint(x: fromRect.midX, y: fromRect.midY), to: self.keyTextNode.layer.position, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
//        self.keyTextNode.layer.animateScale(from: fromRect.size.width / self.keyTextNode.frame.size.width, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
//        self.keyTextNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.15)
        
//        self.infoTextNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
        
        self.containerNode.layer.animatePosition(from: CGPoint(x: fromRect.midX, y: fromRect.maxY), to: self.containerNode.layer.position, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
        self.containerNode.layer.animateScale(from: fromRect.size.width / self.containerNode.frame.size.width, to: 1.0, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
        self.containerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        
//        UIView.animate(withDuration: 0.3, animations: {
//            if #available(iOS 9.0, *) {
//                self.effectView.effect = UIBlurEffect(style: .dark)
//            } else {
//                self.effectView.alpha = 1.0
//            }
//        })
    }
    
    func animateOut(to rect: CGRect, toNode: ASDisplayNode, completion: @escaping () -> Void) {
        let rect = CGRect(origin: self.convert(rect.origin, from: toNode.supernode), size: rect.size)
//        self.keyTextNode.layer.animatePosition(from: self.keyTextNode.layer.position, to: CGPoint(x: rect.midX + 2.0, y: rect.midY), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { _ in
//            completion()
//        })
//        self.keyTextNode.layer.animateScale(from: 1.0, to: rect.size.width / (self.keyTextNode.frame.size.width - 2.0), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        
//        self.infoTextNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        
        self.containerNode.layer.animatePosition(from: self.containerNode.layer.position, to: CGPoint(x: rect.midX, y: rect.maxY), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.containerNode.layer.animateScale(from: 1.0, to: rect.size.width / self.containerNode.frame.size.width, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        self.containerNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        
//        UIView.animate(withDuration: 0.3, animations: {
//            if #available(iOS 9.0, *) {
//                self.effectView.effect = nil
//            } else {
//                self.effectView.alpha = 0.0
//            }
//        })
    }
    
    @objc func tapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.dismiss()
        }
    }
}

