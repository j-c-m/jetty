import AppKit

/// OSC 22 CSS cursor names. Unknown names leave the current cursor.
public enum MouseShape {
    public static func cursor(named raw: String) -> NSCursor? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "default", "auto", "none":
            return .arrow
        case "pointer", "hand":
            return .pointingHand
        case "text", "vertical-text", "cell":
            return .iBeam
        case "crosshair":
            return .crosshair
        case "not-allowed", "no-drop":
            return .operationNotAllowed
        case "col-resize", "ew-resize":
            return .resizeLeftRight
        case "row-resize", "ns-resize":
            return .resizeUpDown
        case "n-resize":
            return .resizeUp
        case "s-resize":
            return .resizeDown
        case "e-resize":
            return .resizeRight
        case "w-resize":
            return .resizeLeft
        case "grab":
            return .openHand
        case "grabbing":
            return .closedHand
        case "copy":
            return .dragCopy
        case "alias":
            return .dragLink
        case "context-menu":
            return .contextualMenu
        default:
            return nil
        }
    }
}
