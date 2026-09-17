import Foundation
import CoreBluetooth

public enum LinkServiceIDs {
    public static var service: CBUUID { CBUUID(string: "13EC0001-6C9A-4E1D-ABF5-4071BD729E3A") }
    public static var request: CBUUID { CBUUID(string: "13EC0002-6C9A-4E1D-ABF5-4071BD729E3A") }
    public static var response: CBUUID { CBUUID(string: "13EC0003-6C9A-4E1D-ABF5-4071BD729E3A") }
}
