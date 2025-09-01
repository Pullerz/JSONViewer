import Foundation

final class OpenWindowBridge {
    static let shared = OpenWindowBridge()
    var openWindowHandler: ((String) -> Void)?
}