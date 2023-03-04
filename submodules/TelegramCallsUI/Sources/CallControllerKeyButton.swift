import Foundation
import UIKit
import Display
import AsyncDisplayKit
import CallsEmoji
import AnimatedStickerNode
import TelegramCore
import TelegramAnimatedStickerNode
import StickerResources
import SwiftSignalKit
import AccountContext

private let labelFont = Font.regular(52.0)
private let animationNodesCount = 3

final class EmojiSlotNode: ASDisplayNode {
    var emoji: String = "" {
        didSet {
            self.node.attributedText = NSAttributedString(string: emoji, font: labelFont, textColor: .black)
            let _ = self.node.updateLayout(CGSize(width: 100.0, height: 100.0))
        }
    }
    
    private let maskNode: ASDisplayNode
    private let containerNode: ASDisplayNode
    private let node: ImmediateTextNode
    private let animationNodes: [ImmediateTextNode]
    
    override init() {
        self.maskNode = ASDisplayNode()
        self.containerNode = ASDisplayNode()
        self.node = ImmediateTextNode()
        self.animationNodes = (0 ..< animationNodesCount).map { _ in ImmediateTextNode() }
                    
        super.init()
        
        let maskLayer = CAGradientLayer()
        maskLayer.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        maskLayer.locations = [0.0, 0.2, 0.8, 1.0]
        maskLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        maskLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        self.maskNode.layer.mask = maskLayer
        
        self.addSubnode(self.maskNode)
        self.maskNode.addSubnode(self.containerNode)
        self.containerNode.addSubnode(self.node)
        self.animationNodes.forEach({ self.containerNode.addSubnode($0) })
    }
    
    func animateIn(duration: Double) {
        for node in self.animationNodes {
            node.attributedText = NSAttributedString(string: randomCallsEmoji(), font: labelFont, textColor: .black)
            let _ = node.updateLayout(CGSize(width: 100.0, height: 100.0))
        }
        self.containerNode.layer.animatePosition(from: CGPoint(x: 0.0, y: -self.containerNode.frame.height + self.bounds.height), to: CGPoint(), duration: duration, delay: 0.1, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
    }
    
    override func layout() {
        super.layout()
        
        let maskInset: CGFloat = 4.0
        let maskFrame = self.bounds.insetBy(dx: 0.0, dy: -maskInset)
        self.maskNode.frame = maskFrame
        self.maskNode.layer.mask?.frame = CGRect(origin: CGPoint(), size: maskFrame.size)
        
        let spacing: CGFloat = 2.0
        let containerSize = CGSize(width: self.bounds.width, height: self.bounds.height * CGFloat(animationNodesCount + 1) + spacing * CGFloat(animationNodesCount))
        self.containerNode.frame = CGRect(origin: CGPoint(x: 0.0, y: maskInset), size: containerSize)
        
        self.node.frame = CGRect(origin: CGPoint(), size: self.bounds.size)
        var offset: CGFloat = self.bounds.height + spacing
        for node in self.animationNodes {
            node.frame = CGRect(origin: CGPoint(x: 0.0, y: offset), size: self.bounds.size)
            offset += self.bounds.height + spacing
        }
    }
}

final class CallControllerKeyEmojiNode: ASDisplayNode {
    
    private let animatedNode: DefaultAnimatedStickerNodeImpl
    private let imageNode: TransformImageNode
    private let textNode: ImmediateTextNode
    
    private var disposables = DisposableSet()
    
    override init() {
        self.animatedNode = DefaultAnimatedStickerNodeImpl()
        self.imageNode = TransformImageNode()
        self.textNode = ImmediateTextNode()
        super.init()
    }
    
    override func layout() {
        super.layout()
        
        self.animatedNode.frame = self.bounds
        self.imageNode.frame = self.bounds
        self.textNode.position = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
    }
    
    func animateExpand() {
        self.animatedNode.playLoop()
    }
    
    func animateCollapse() {
        self.animatedNode.playOnce()
    }
    
    func setStickerPackItem(_ stickerPackItem: StickerPackItem, account: Account) {
        self.addSubnode(self.imageNode)
        self.addSubnode(self.animatedNode)
        self.layoutIfNeeded()
        
        let animatedStickerSource = AnimatedStickerResourceSource(account: account, resource: stickerPackItem.file.resource)
        self.disposables.add(freeMediaFileResourceInteractiveFetched(account: account, userLocation: .other, fileReference: stickerPackFileReference(stickerPackItem.file), resource: stickerPackItem.file.resource).start())
        
        let imageSize = CGSize(width: 52.0 * UIScreenScale, height: 52.0 * UIScreenScale)
        self.imageNode.setSignal(chatMessageAnimatedSticker(postbox: account.postbox, userLocation: .other, file: stickerPackItem.file, small: false, size: imageSize))
        self.imageNode.asyncLayout()(TransformImageArguments(corners: ImageCorners(), imageSize: CGSize(width: 30.0, height: 30.0), boundingSize: CGSize(width: 30.0, height: 30.0), intrinsicInsets: UIEdgeInsets()))()
        
        self.animatedNode.setup(source: animatedStickerSource, width: Int(imageSize.width), height: Int(imageSize.height), playbackMode: .still(.start), mode: .direct(cachePathPrefix: nil))
        self.animatedNode.updateLayout(size: self.animatedNode.bounds.size)
        
        self.animatedNode.visibility = true
        self.animatedNode.started = { [weak imageNode] in
            imageNode?.removeFromSupernode()
        }
    }
    
    func setString(_ string: String) {
        self.addSubnode(self.textNode)
        self.layoutIfNeeded()
        
        self.textNode.transform = CATransform3DMakeScale(0.5, 0.5, 1.0)
        self.textNode.attributedText = NSAttributedString(string: string, font: labelFont, textColor: .black)
        self.textNode.frame.size = self.textNode.updateLayout(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    }
}

final class CallControllerKeyButton: HighlightableButtonNode {
    
    private let containerNode: ASDisplayNode
    private let nodes: [CallControllerKeyEmojiNode]
    
    init() {
        self.containerNode = ASDisplayNode()
        self.nodes = (0..<4).map { _ in CallControllerKeyEmojiNode() }
        
        super.init(pointerStyle: nil)
        
        self.addSubnode(self.containerNode)
        self.nodes.forEach { self.containerNode.addSubnode($0) }
    }
    
    func setup(key: String, account: Account, animatedEmojiStickers: [String: [StickerPackItem]]) {
        self.layoutIfNeeded()
        
        let haveAllAnimatedEmoji = key.map(String.init).allSatisfy({ animatedEmojiStickers[$0]?.first != nil })
        for (index, emoji) in key.map(String.init).enumerated() {
            if haveAllAnimatedEmoji, let stickerPackItem = animatedEmojiStickers[emoji]?.first {
                print("Emoji: should animate \(emoji)")
                self.nodes[index].setStickerPackItem(stickerPackItem, account: account)
            } else {
                print("Emoji: no animation sticker for \(emoji)")
                self.nodes[index].setString(emoji)
            }
        }
    }
    
    func animateIn() {
        self.layoutIfNeeded()
        
        self.containerNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
        self.nodes.reversed().enumerated().forEach { index, node in
            node.layer.animatePosition(from: node.position.offsetBy(dx: -8.0 * CGFloat(index + 1), dy: 0.0), to: node.position, duration: 0.4)
        }
    }
    
    func animateExpand(to rect: CGRect) {
        self.nodes.forEach { $0.animateExpand() }
        self.layer.animateScale(from: 1.0, to: rect.width / self.bounds.width, duration: 0.4)
        self.layer.transform = CATransform3DMakeScale(rect.width / self.bounds.width, rect.width / self.bounds.width, 1.0)
        self.layer.animatePosition(from: self.layer.position, to: CGPoint(x: rect.midX, y: rect.midY), duration: 0.4)
        self.layer.position = CGPoint(x: rect.midX, y: rect.midY)
    }
    
    func animateCollapse(to rect: CGRect) {
        self.nodes.forEach { $0.animateCollapse() }
        self.layer.animateScale(from: sqrt((self.transform.m11 * self.transform.m11) + (self.transform.m12 * self.transform.m12) + (self.transform.m13 * self.transform.m13)), to: 1.0, duration: 0.4)
        self.layer.transform = CATransform3DMakeScale(1.0, 1.0, 1.0)
        self.layer.animatePosition(from: self.layer.position, to: CGPoint(x: rect.midX, y: rect.midY), duration: 0.4)
        self.layer.position = CGPoint(x: rect.midX, y: rect.midY)
    }
    
    override func measure(_ constrainedSize: CGSize) -> CGSize {
        return CGSize(width: 114.0 + 6.0, height: 29.0)
    }
    
    override func layout() {
        super.layout()
        
        self.containerNode.frame = self.bounds
        let nodeSize = CGSize(width: 29.0, height: self.bounds.size.height)
        self.nodes.enumerated().forEach { index, node in
            node.frame = CGRect(origin: CGPoint(x: CGFloat(index) * nodeSize.width + CGFloat(index) * 2.0, y: 0.0), size: nodeSize)
        }
    }
}
