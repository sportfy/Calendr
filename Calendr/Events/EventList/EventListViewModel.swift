//
//  EventListViewModel.swift
//  Calendr
//
//  Created by Paker on 26/02/2021.
//

import Cocoa
import RxSwift

enum EventListItem {
    case section(String)
    case interval(String, Observable<Bool>)
    case event(EventViewModel)
}

class EventListViewModel {

    private let disposeBag = DisposeBag()

    private let viewModels = BehaviorSubject<[EventListItem]>(value: [])
    private let isShowingDetails: BehaviorSubject<Bool>
    private let dateProvider: DateProviding
    private let calendarService: CalendarServiceProviding
    private let geocoder: GeocodeServiceProviding
    private let weatherService: WeatherServiceProviding
    private let workspace: WorkspaceServiceProviding
    private let userDefaults: UserDefaults
    private let settings: EventListSettings
    private let scheduler: SchedulerType

    private let dateFormatter: DateFormatter
    private let relativeFormatter: RelativeDateTimeFormatter
    private let dateComponentsFormatter: DateComponentsFormatter

    private struct EventListProps: Equatable {
        var events: [EventModel]
        let date: Date
        let showPastEvents: Bool
        let showOverdue: Bool
        let isTodaySelected: Bool
    }

    init(
        eventsObservable: Observable<(Date, [EventModel])>,
        isShowingDetails: BehaviorSubject<Bool>,
        dateProvider: DateProviding,
        calendarService: CalendarServiceProviding,
        geocoder: GeocodeServiceProviding,
        weatherService: WeatherServiceProviding,
        workspace: WorkspaceServiceProviding,
        userDefaults: UserDefaults,
        settings: EventListSettings,
        scheduler: SchedulerType
    ) {
        self.isShowingDetails = isShowingDetails
        self.dateProvider = dateProvider
        self.calendarService = calendarService
        self.geocoder = geocoder
        self.weatherService = weatherService
        self.workspace = workspace
        self.userDefaults = userDefaults
        self.settings = settings
        self.scheduler = scheduler

        dateFormatter = DateFormatter(calendar: dateProvider.calendar)
        dateFormatter.dateStyle = .short

        relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.dateTimeStyle = .named

        dateComponentsFormatter = DateComponentsFormatter()
        dateComponentsFormatter.calendar = dateProvider.calendar
        dateComponentsFormatter.unitsStyle = .abbreviated
        dateComponentsFormatter.allowedUnits = [.hour, .minute]

        Observable.combineLatest(
            eventsObservable,
            settings.showPastEvents,
            settings.showOverdueReminders,
            isShowingDetails
        )
        .compactMap { dateEvents, showPast, showOverdue, isShowingDetails -> EventListProps? in
            guard !isShowingDetails else { return nil }
            let (date, events) = dateEvents
            let isTodaySelected = dateProvider.calendar.isDate(date, inSameDayAs: dateProvider.now)

            return .init(
                events: events,
                date: date,
                showPastEvents: showPast,
                showOverdue: showOverdue,
                isTodaySelected: isTodaySelected
            )
        }
        .distinctUntilChanged()
        .flatMapLatest { props -> Observable<EventListProps> in

            guard props.isTodaySelected && !props.showPastEvents else {
                return .just(props)
            }

            // schedule refresh for every event end to hide past events
            return Observable.merge(
                props.events
                    .filter {
                        !$0.isAllDay && !$0.type.isReminder && $0.range(using: dateProvider).endsToday
                    }
                    .map {
                        Int(dateProvider.now.distance(to: $0.end).rounded(.up)) + 1
                    }
                    .filter { $0 >= 0 }
                    .map {
                        Observable<Int>.timer(.seconds($0), scheduler: scheduler)
                    }
            )
            .void()
            .startWith(())
            .map {
                var props = props
                props.events = props.events.filter {
                    if case .reminder(let completed) = $0.type {
                        return !completed
                    }
                    return $0.isAllDay || !$0.range(using: dateProvider).isPast
                }
                return props
            }
        }
        // build event list
        .compactMap { [weak self] props in
            self?.buildEventList(props)
        }
        .bind(to: viewModels)
        .disposed(by: disposeBag)
    }

    func asObservable() -> Observable<[EventListItem]> { viewModels }

    // MARK: - Private

    private func buildEventList(_ props: EventListProps) -> [EventListItem] {
        overdueViewModels(props)
        + allDayViewModels(props)
        + todayViewModels(props)
    }

    private func makeEventViewModel(_ event: EventModel, _ isTodaySelected: Bool) -> EventViewModel {
        EventViewModel(
            event: event,
            dateProvider: dateProvider,
            calendarService: calendarService,
            geocoder: geocoder,
            weatherService: weatherService,
            workspace: workspace,
            userDefaults: userDefaults,
            settings: settings,
            isShowingDetails: isShowingDetails.asObserver(),
            isTodaySelected: isTodaySelected,
            scheduler: scheduler
        )
    }

    private func isOverdue(_ event: EventModel) -> Bool {
        event.type.isReminder
        && dateProvider.calendar.isDate(event.start, lessThan: dateProvider.now, granularity: .day)
    }

    private func overdueViewModels(_ props: EventListProps) -> [EventListItem] {

        guard props.showOverdue else { return [] }

        return props.events
            .filter { isOverdue($0) && props.isTodaySelected }
            .sorted(by: \.start)
            .prevMap { prev, curr -> [EventListItem] in

                let viewModel = makeEventViewModel(curr, props.isTodaySelected)
                let eventItem: EventListItem = .event(viewModel)

                guard let prev, dateProvider.calendar.isDate(curr.start, inSameDayAs: prev.start) else {
                    let label = props.isTodaySelected
                        ? relativeFormatter.localizedString(for: curr.start, relativeTo: dateProvider.now).ucfirst
                        : dateFormatter.string(from: curr.start)
                    return [.section(label), eventItem]
                }

                return [eventItem]
            }
            .flatten()
    }

    private func allDayViewModels(_ props: EventListProps) -> [EventListItem] {
        var viewModels: [EventListItem] = props.events
            .filter { $0.isAllDay && (!isOverdue($0) || !props.isTodaySelected) }
            .sorted(by: \.calendar.color.hashValue)
            .map { .event(makeEventViewModel($0, props.isTodaySelected)) }

        if !viewModels.isEmpty {
            viewModels.insert(.section(Strings.Formatter.Date.allDay), at: 0)
        }
        return viewModels
    }

    private func todayViewModels(_ props: EventListProps) -> [EventListItem] {
        props.events
            .filter { !$0.isAllDay && (!isOverdue($0) || !props.isTodaySelected) }
            .sorted {
                ($0.start, $0.end) < ($1.start, $1.end)
            }
            .prevMap { prev, curr -> [EventListItem] in

                let viewModel = makeEventViewModel(curr, props.isTodaySelected)
                let eventItem: EventListItem = .event(viewModel)

                guard let prev else {
                    // if first event, show today section
                    let title = props.isTodaySelected
                        ? Strings.Formatter.Date.today
                        : dateFormatter.string(from: props.date)

                    return [.section(title), eventItem]
                }

                // show interval between events
                guard
                    prev.end.distance(to: curr.start) >= 60,
                    let interval = dateComponentsFormatter.string(from: prev.end, to: curr.start)
                else {
                    return [eventItem]
                }

                let fade = Observable
                    .merge(viewModel.isFaded, viewModel.isInProgress)
                    .take(until: \.isTrue, behavior: .inclusive)

                return [.interval(interval, fade), eventItem]
            }
            .flatten()
    }
}
