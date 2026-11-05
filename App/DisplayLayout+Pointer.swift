import AppKit
import OMSCore

extension DisplayLayout {
    /// The display under the pointer; nil while it is on none.
    var displayUnderPointer: DisplayInfo? { display(at: NSEvent.mouseLocation) }

    /// The display under the pointer, else the primary one: where something shows that has no display of its own.
    var pointerDisplay: DisplayInfo? { displayUnderPointer ?? primary }
}
