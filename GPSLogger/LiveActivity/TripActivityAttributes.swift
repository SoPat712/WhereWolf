//
//  TripActivityAttributes.swift
//  WhereWolf
//
//  Shared by the app and the WhereWolfTrackingActivity widget extension.
//

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct TripActivityAttributes: ActivityAttributes {
    typealias ContentState = TripActivityState

    var tripStart: Date
}
