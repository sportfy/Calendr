//
//  MockEventDetailsSettings.swift
//  CalendrTests
//
//  Created by Paker on 25/02/2021.
//

import RxSwift
@testable import Calendr

class MockEventDetailsSettings: EventDetailsSettings {

    let showMap: Observable<Bool> = .just(false)
    let popoverMaterial: Observable<PopoverMaterial> = .just(.popover)
    let textScaling: Observable<Double> = .just(1)
    let calendarTextScaling: Observable<Double> = .just(1)
}
