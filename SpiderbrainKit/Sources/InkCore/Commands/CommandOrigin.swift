import Foundation

/// Where a command came from, which determines whether its result is broadcast.
///
/// This is the guard against sync echo loops. A command applied from a peer must
/// not be re-broadcast to that peer, so origin travels with the command rather
/// than living in a parallel set of `addReceived*` methods that each call site
/// has to remember to pick correctly.
public enum CommandOrigin: Equatable {
    /// Originated on this device from user action. Effects should be synced.
    case local

    /// Arrived from a peer. Effects must not be re-broadcast.
    case remote
}
