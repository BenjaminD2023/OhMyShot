/// What each purpose of the overlay does differently, said once: the controller and each display's view ask these,
/// never which purposes they are, so a purpose added later is asked about each of them where it is declared.
extension OverlayController.Purpose {
    /// What is chosen is taken as a picture of the screen: Capture Area and Annotate Area. Only these keep the pointer in
    /// a frozen frame, show the actual-size lens when Settings choose it, and recall the last area with L.
    var takesPicture: Bool {
        switch self {
        case .screenshot, .annotate: true
        case .text, .color, .measure, .record, .scroll: false
        }
    }

    /// Whether the session shows the screen as it was when it began (`freezesScreen` is the setting): picking a color,
    /// measuring, and in-place annotation always do, since they read the frozen frame's pixels; a recording and a
    /// scrolling capture never do, since what they take is the screen as it goes on.
    func holdsStill(freezesScreen: Bool) -> Bool {
        switch self {
        case .annotate, .color, .measure: true
        case .record, .scroll: false
        case .screenshot, .text: freezesScreen
        }
    }

    /// The crosshair is for a pixel, not an area: picking a color and measuring. The arrows move it, Space is no
    /// window, and Return takes what is under it.
    var picksPixels: Bool {
        switch self {
        case .color, .measure: true
        case .screenshot, .text, .annotate, .record, .scroll: false
        }
    }

    /// The screen is dimmed around what is chosen. Copying text, picking a color, and measuring show it as it is.
    var dimsScreen: Bool {
        switch self {
        case .screenshot, .annotate, .record, .scroll: true
        case .text, .color, .measure: false
        }
    }

    /// The bar of modes (Area, Window) shows on the pointer's display.
    var showsModeBar: Bool {
        switch self {
        case .screenshot, .annotate, .record: true
        case .text, .color, .measure, .scroll: false
        }
    }

    /// What is chosen is framed with a bar under it, to adjust it and start, rather than taken as the mouse goes up.
    var framesWithBar: Bool {
        switch self {
        case .record, .scroll: true
        case .screenshot, .text, .annotate, .color, .measure: false
        }
    }

    /// A selection stays on the display its drag began on: in-place annotation's interface lives there, and a
    /// recording or a scrolling capture takes one display.
    var selectsOnOneDisplay: Bool {
        switch self {
        case .annotate, .record, .scroll: true
        case .screenshot, .text, .color, .measure: false
        }
    }

    /// A selection's edges may snap to the blocks of text on a frozen screen.
    var snapsToText: Bool {
        switch self {
        case .screenshot, .text, .annotate: true
        case .color, .measure, .record, .scroll: false
        }
    }

    /// Shift-clicks choose several windows at once.
    var choosesSeveralWindows: Bool {
        switch self {
        case .screenshot, .text, .annotate: true
        case .color, .measure, .record, .scroll: false
        }
    }

    /// C takes the color under the crosshair, as in Snipaste, ending the session with it. Text has no crosshair, and a
    /// recording's or a scrolling capture's area is chosen on the live screen for what it does next.
    var picksColorWithC: Bool {
        switch self {
        case .screenshot, .annotate, .color, .measure: true
        case .text, .record, .scroll: false
        }
    }

    /// All-In-One's bar and keys may take the area: a screenshot's only, as its modes are screenshot modes.
    var mayBeAllInOne: Bool {
        switch self {
        case .screenshot: true
        case .text, .annotate, .color, .measure, .record, .scroll: false
        }
    }

    /// Tab frames the area for a size typed and a shape kept: in Capture Area and Annotate Area, but not in All-In-One,
    /// whose area is framed after its drag already.
    func opensSizeControl(allInOne: Bool) -> Bool {
        takesPicture && !allInOne
    }
}
