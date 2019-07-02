//
//  Dispatcher.swift
//  
//
//  Created by Jorge Revuelta on 01/07/2019.
//

import Foundation
import Combine


public typealias SubscriptionMap = [String: OrderedSet<DispatcherSubscription>?]

final public class Dispatcher {
    
    public struct DispatchMode {
        public enum UI {
            case sync, async
        }
    }
    
    public var subscriptionCount: Int {
        subscriptionMap.mapValues { set -> Int in
            guard let setValue = set else { return 0 }
            return setValue.count
        }
        .reduce(0, { $0 + $1.value })
    }
    
    public static let defaultPriority = 100

    private let internalQueue = DispatchQueue(label: "MiniSwift", qos: .userInitiated)
    private var subscriptionMap = [String: OrderedSet<DispatcherSubscription>?]()
    private var middleware = [MiddlewareWrapper]()
    private let root: RootChain
    private var chain: Chain
    private var dispatching: Bool = false
    @Atomic private var subscriptionCounter: Int = 0

    public init() {
        root = RootChain(map: subscriptionMap)
        chain = root
    }
    
    private func build() -> Chain {
        return middleware.reduce(root, { (chain: Chain, middleware: MiddlewareWrapper) -> Chain in
            return ForwardingChain { action in
                middleware.do(action, chain)
            }
        })
    }
    
    func add(middleware: MiddlewareWrapper) {
        internalQueue.sync {
            self.middleware.append(middleware)
            self.chain = build()
        }
    }
    
    func remove(middleware: MiddlewareWrapper) {
        internalQueue.sync {
            if let index = self.middleware.firstIndex(of: middleware) {
                self.middleware.remove(at: index)
            }
            chain = build()
        }
    }
    
    public func subscribe(priority: Int, tag: String, completion: @escaping (Action) -> Void) -> DispatcherSubscription {
        let subscription = DispatcherSubscription(
            dispatcher: self,
            id: getNewSubscriptionId(),
            priority: priority,
            tag: tag,
            completion: completion)
        return registerInternal(subscription: subscription)
    }
    
    public func registerInternal(subscription: DispatcherSubscription) -> DispatcherSubscription {
        internalQueue.sync {
            if let map = subscriptionMap[subscription.tag, orPut: OrderedSet<DispatcherSubscription>()] {
                map.insert(subscription)
            }
        }
        return subscription
    }
    
    public func unregisterInternal(subscription: DispatcherSubscription) {
        internalQueue.sync {
            var removed = false
            if let set = subscriptionMap[subscription.tag] as? OrderedSet<DispatcherSubscription> {
                removed = set.remove(subscription)
            } else {
                removed = true
            }
            assert(removed, "Failed to remove DispatcherSubscription, multiple dispose calls?")
        }
    }
    
    public func subscribe<T: Action>(completion: @escaping (T) -> Void) -> DispatcherSubscription {
        return subscribe(tag: T.tag, completion: { (action: T) -> Void in
            completion(action)
        })
    }
    
    public func subscribe<T: Action>(tag: String, completion: @escaping (T) -> Void) -> DispatcherSubscription {
        return subscribe(tag: tag, completion: { object in
            if let action = object as? T {
                completion(action)
            } else {
                fatalError("Casting to \(tag) failed")
            }
        })
    }
    
    public func subscribe(tag: String, completion: @escaping (Action) -> Void) -> DispatcherSubscription {
        return subscribe(priority: Dispatcher.defaultPriority, tag: tag, completion: completion)
    }
    
    public func dispatch(_ action: Action, mode: Dispatcher.DispatchMode.UI) {
        switch mode {
        case .sync:
            if DispatchQueue.isMain {
                self.dispatch(action)
            } else {
                DispatchQueue.main.sync {
                    self.dispatch(action)
                }
            }
        case .async:
            DispatchQueue.main.async {
                self.dispatch(action)
            }
        }
    }
    
    private func dispatch(_ action: Action) {
        assert(DispatchQueue.isMain)
        internalQueue.sync {
            defer { dispatching = false }
            if dispatching {
                preconditionFailure("Already dispatching")
            }
            dispatching = true
            _ = chain.proceed(action)
        }
    }
    
    private func getNewSubscriptionId() -> Int {
        $subscriptionCounter.mutate { $0 += 1 }
        return subscriptionCounter
    }
}

public final class DispatcherSubscription: Comparable {
    
    private let dispatcher: Dispatcher
    public let id: Int
    private let priority: Int
    private let completion: (Action) -> Void
    
    public let tag: String
    
    public init (dispatcher: Dispatcher,
                 id: Int,
                 priority: Int,
                 tag: String,
                 completion: @escaping (Action) -> Void) {
        self.dispatcher = dispatcher
        self.id = id
        self.priority = priority
        self.tag = tag
        self.completion = completion
    }
    
    public func on(_ action: Action) {
        completion(action)
    }
    
    public static func == (lhs: DispatcherSubscription, rhs: DispatcherSubscription) -> Bool {
        return lhs.id == rhs.id
    }
    
    public static func > (lhs: DispatcherSubscription, rhs: DispatcherSubscription) -> Bool {
        return lhs.priority > rhs.priority
    }
    
    public static func < (lhs: DispatcherSubscription, rhs: DispatcherSubscription) -> Bool {
        return lhs.priority < rhs.priority
    }
    
    public static func >= (lhs: DispatcherSubscription, rhs: DispatcherSubscription) -> Bool {
        return lhs.priority >= rhs.priority
    }
    
    public static func <= (lhs: DispatcherSubscription, rhs: DispatcherSubscription) -> Bool {
        return lhs.priority <= rhs.priority
    }
}